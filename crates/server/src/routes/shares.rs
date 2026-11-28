//! Public share links: creating and listing them, the passcode gate, and the
//! public page, metadata and download endpoints.

use super::*;

pub(super) async fn create_share_link(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<CreateShareRequest>,
) -> Result<Json<ShareLinkInfo>, (StatusCode, String)> {
    create_share_for_items(
        &state,
        &auth.user_id,
        vec![id],
        None,
        req.passcode,
        req.expires_hours,
        req.max_downloads,
    )
    .await
    .map(Json)
}

pub(super) async fn create_batch_share_link(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateBatchShareRequest>,
) -> Result<Json<ShareLinkInfo>, (StatusCode, String)> {
    create_share_for_items(
        &state,
        &auth.user_id,
        req.item_ids,
        req.title,
        req.passcode,
        req.expires_hours,
        req.max_downloads,
    )
    .await
    .map(Json)
}

pub(super) fn format_share_display_name(custom_title: Option<&str>, items: &[DrawerItemRow]) -> String {
    if let Some(t) = custom_title.map(str::trim).filter(|s| !s.is_empty()) {
        return t.to_string();
    }
    if items.len() == 1 {
        return items[0].name.clone();
    }
    let first = &items[0].name;
    // "A 等 3 项" counts every item; English names the first and counts the rest.
    if crate::i18n::is_en() {
        let more = items.len() - 1;
        format!("{first} and {more} more {}", if more == 1 { "item" } else { "items" })
    } else {
        format!("{first} 等 {} 项", items.len())
    }
}

pub(super) async fn create_share_for_items(
    state: &Arc<AppState>,
    user_id: &str,
    raw_item_ids: Vec<String>,
    title: Option<String>,
    passcode: Option<String>,
    expires_hours: Option<u64>,
    max_downloads: Option<u64>,
) -> Result<ShareLinkInfo, (StatusCode, String)> {
    let mut unique_ids = Vec::new();
    for id in raw_item_ids {
        if !unique_ids.contains(&id) {
            unique_ids.push(id);
        }
    }
    if unique_ids.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("请至少选择一个文件或文本条目", "Select at least one file or text item").to_string(),
        ));
    }

    let mut items = Vec::with_capacity(unique_ids.len());
    for id in &unique_ids {
        let item = state
            .db
            .get_drawer_item(id, user_id)
            .map_err(internal_err)?
            .ok_or_else(|| (StatusCode::NOT_FOUND, t!("抽屉条目不存在", "Drawer item not found").to_string()))?;

        items.push(item);
    }

    let terms = policy::share_terms(
        state,
        user_id,
        passcode.as_deref(),
        expires_hours,
        max_downloads,
    )?;
    let (expires_hours, max_downloads) = (terms.expires_hours, terms.max_downloads);

    let code = generate_short_code();
    let passcode_hash = match passcode.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        Some(passcode) => Some(hash_password_blocking(passcode).await.map_err(internal_err)?),
        None => None,
    };

    let clean_title = title
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToString::to_string);

    let now = Utc::now();
    let expires_at = expires_hours
        .filter(|&h| h > 0)
        .map(|h| now + Duration::hours(h as i64));

    let primary_item_id = items[0].id.clone();
    let display_name = format_share_display_name(clean_title.as_deref(), &items);
    let total_size: u64 = items.iter().map(|it| it.size).sum();
    let item_count = items.len() as u64;
    let primary_kind = if items.iter().any(|it| it.kind == DrawerItemKind::File) {
        DrawerItemKind::File
    } else {
        DrawerItemKind::Text
    };

    let row = crate::db::ShareLinkRow {
        code: code.clone(),
        user_id: user_id.to_string(),
        item_id: primary_item_id.clone(),
        title: clean_title,
        passcode_hash: passcode_hash.clone(),
        max_downloads: max_downloads.filter(|&n| n > 0),
        download_count: 0,
        expires_at,
        created_at: now,
    };
    state
        .db
        .create_share_link(&row, &unique_ids)
        .map_err(internal_err)?;

    Ok(ShareLinkInfo {
        code: code.clone(),
        item_id: primary_item_id,
        item_name: display_name,
        item_kind: primary_kind,
        item_size: total_size,
        item_count,
        has_passcode: passcode_hash.is_some(),
        max_downloads: row.max_downloads,
        download_count: 0,
        expires_at,
        created_at: now,
        share_path: format!("/s/{code}"),
    })
}

pub(super) async fn list_share_links(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<ShareLinkInfo>>, (StatusCode, String)> {
    let rows = state
        .db
        .list_share_links(&auth.user_id)
        .map_err(internal_err)?;
    let mut out = Vec::new();
    for r in rows {
        let items = state
            .db
            .get_share_link_items(&r.code, &r.item_id)
            .map_err(internal_err)?;
        if items.is_empty() {
            continue;
        }
        let display_name = format_share_display_name(r.title.as_deref(), &items);
        let total_size: u64 = items.iter().map(|it| it.size).sum();
        let primary_kind = if items.iter().any(|it| it.kind == DrawerItemKind::File) {
            DrawerItemKind::File
        } else {
            DrawerItemKind::Text
        };
        out.push(ShareLinkInfo {
            share_path: format!("/s/{}", r.code),
            code: r.code,
            item_id: items[0].id.clone(),
            item_name: display_name,
            item_kind: primary_kind,
            item_size: total_size,
            item_count: items.len() as u64,
            has_passcode: r.passcode_hash.is_some(),
            max_downloads: r.max_downloads,
            download_count: r.download_count,
            expires_at: r.expires_at,
            created_at: r.created_at,
        });
    }
    Ok(Json(out))
}

pub(super) async fn delete_share_link(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(code): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    let ok = state
        .db
        .delete_share_link(&code, &auth.user_id)
        .map_err(internal_err)?;
    if !ok {
        return Err((StatusCode::NOT_FOUND, t!("分享链接不存在", "Share link not found").to_string()));
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Debug, Deserialize)]
pub(super) struct PublicShareQuery {
    #[serde(default)]
    passcode: Option<String>,
    #[serde(default)]
    item_id: Option<String>,
    #[serde(default)]
    peer_session: Option<String>,
}

/// Whether `passcode` unlocks `share`. Failed attempts are rate limited per share code.
pub(super) async fn share_unlocked(
    state: &AppState,
    share: &crate::db::ShareLinkRow,
    passcode: Option<&str>,
) -> Result<bool, (StatusCode, String)> {
    let Some(ref hash) = share.passcode_hash else {
        return Ok(true);
    };
    let provided = passcode.unwrap_or("").trim();
    if provided.is_empty() {
        return Ok(false);
    }
    if state.failed_passcodes.is_blocked(&share.code) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            t!("提取码尝试次数过多，请稍后再试", "Too many passcode attempts. Try again later").to_string(),
        ));
    }
    if verify_password_blocking(provided, hash).await {
        Ok(true)
    } else {
        state.failed_passcodes.record_failure(&share.code);
        Ok(false)
    }
}

pub(super) async fn validate_share_access(
    state: &AppState,
    share: &crate::db::ShareLinkRow,
    passcode: Option<&str>,
    check_limit: bool,
) -> Result<(), (StatusCode, String)> {
    if let Some(exp) = share.expires_at
        && exp <= Utc::now()
    {
        return Err((StatusCode::GONE, t!("该分享链接已过期", "This share link has expired").to_string()));
    }
    if check_limit
        && let Some(max) = share.max_downloads
        && share.download_count >= max
    {
        return Err((StatusCode::GONE, t!("该分享链接已达到下载次数上限", "This share link has reached its download limit").to_string()));
    }
    if !share_unlocked(state, share, passcode).await? {
        return Err((StatusCode::FORBIDDEN, t!("需要正确的提取码", "A correct passcode is required").to_string()));
    }
    Ok(())
}

pub(super) async fn public_share_meta(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    Path(code): Path<String>,
    Query(query): Query<PublicShareQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let share = lookup_public_share(&state, &ip, &code)?;
    policy::ensure_share_access(&state, &share.user_id)?;

    if let Some(exp) = share.expires_at
        && exp <= Utc::now()
    {
        return Err((StatusCode::GONE, t!("该分享链接已过期", "This share link has expired").to_string()));
    }
    if let Some(max) = share.max_downloads
        && share.download_count >= max
    {
        return Err((StatusCode::GONE, t!("该分享链接已达到下载次数上限", "This share link has reached its download limit").to_string()));
    }

    let items = state
        .db
        .get_share_link_items(&share.code, &share.item_id)
        .map_err(internal_err)?;
    if items.is_empty() {
        return Err((StatusCode::NOT_FOUND, t!("关联文件已被删除", "The linked file has been deleted").to_string()));
    }

    let locked = !share_unlocked(&state, &share, query.passcode.as_deref()).await?;

    // Without a title chosen by the sharer, the name comes from the files, which
    // the passcode protects. Before unlocking, show a neutral title instead.
    let has_custom_title = share.title.as_deref().is_some_and(|t| !t.trim().is_empty());
    let display_name = if locked && !has_custom_title {
        t!("此分享需要提取码", "This share needs a passcode").to_string()
    } else {
        format_share_display_name(share.title.as_deref(), &items)
    };
    // Text is delivered inside this response, so on a share with a download
    // limit, revealing it counts as one download (as the download route does).
    // (Mixed shares count when a file is downloaded.)
    let reveals_text = !locked && items.iter().all(|it| it.kind == DrawerItemKind::Text);
    let mut download_count = share.download_count;
    if reveals_text && share.max_downloads.is_some() {
        if !state
            .db
            .increment_share_download(&share.code)
            .map_err(internal_err)?
        {
            return Err((StatusCode::GONE, t!("该分享链接已达到下载次数上限", "This share link has reached its download limit").to_string()));
        }
        download_count += 1;
    }
    let total_size: u64 = items.iter().map(|it| it.size).sum();
    let primary_kind = if items.iter().any(|it| it.kind == DrawerItemKind::File) {
        DrawerItemKind::File
    } else {
        DrawerItemKind::Text
    };
    let single_text = if !locked && items.len() == 1 && items[0].kind == DrawerItemKind::Text {
        items[0].text_content.clone()
    } else {
        None
    };

    // A passcode protects the file list too: before unlocking, visitors see only
    // the share's title, item count and total size.
    let visible_items: &[DrawerItemRow] = if locked { &[] } else { &items };
    let serialized_items: Vec<serde_json::Value> = visible_items
        .iter()
        .map(|it| {
            serde_json::json!({
                "id": it.id,
                "name": it.name,
                "kind": it.kind,
                "size": it.size,
                "cloud_ready": it.cloud_ready,
                "text_content": if !locked && it.kind == DrawerItemKind::Text {
                    it.text_content.clone()
                } else {
                    None
                },
            })
        })
        .collect();

    Ok(Json(serde_json::json!({
        "code": share.code,
        "name": display_name,
        "kind": primary_kind,
        "size": total_size,
        "item_count": items.len(),
        "items": serialized_items,
        "locked": locked,
        "has_passcode": share.passcode_hash.is_some(),
        "download_count": download_count,
        "max_downloads": share.max_downloads,
        "expires_at": share.expires_at,
        "text_content": single_text,
    })))
}

pub(super) async fn public_share_download(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    Path(code): Path<String>,
    Query(query): Query<PublicShareQuery>,
) -> Result<Response, (StatusCode, String)> {
    let share = lookup_public_share(&state, &ip, &code)?;
    policy::ensure_share_access(&state, &share.user_id)?;

    let retry_session = match (&query.peer_session, &query.item_id) {
        (Some(session), Some(item)) if state.browser_shares.can_fallback(session, &code, item).await => {
            Some(session.as_str())
        }
        _ => None,
    };
    validate_share_access(&state, &share, query.passcode.as_deref(), retry_session.is_none()).await?;

    let items = state
        .db
        .get_share_link_items(&share.code, &share.item_id)
        .map_err(internal_err)?;
    if items.is_empty() {
        return Err((StatusCode::NOT_FOUND, t!("关联文件已被删除", "The linked file has been deleted").to_string()));
    }

    let item = if let Some(ref target_id) = query.item_id {
        items
            .into_iter()
            .find(|it| &it.id == target_id)
            .ok_or_else(|| (StatusCode::NOT_FOUND, t!("所请求的文件不在该分享中", "The requested file isn't part of this share").to_string()))?
    } else {
        items.into_iter().next().unwrap()
    };

    if item.kind == DrawerItemKind::Text {
        if !state
            .db
            .increment_share_download(&code)
            .map_err(internal_err)?
        {
            return Err((StatusCode::GONE, t!("该分享链接已达到下载次数上限", "This share link has reached its download limit").to_string()));
        }
        let text = item.text_content.unwrap_or_default();
        return Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
            .body(Body::from(text))
            .map_err(internal_err);
    }

    let (Some(backend_id), Some(storage_path)) =
        (item.storage_backend_id.as_deref(), item.storage_path.as_deref())
    else {
        return Err((StatusCode::SERVICE_UNAVAILABLE, t!("文件没有云端副本，请从分享页尝试局域网下载", "This file has no cloud copy. Try a LAN download from the share page").to_string()));
    };

    let backend = state
        .db
        .get_storage_backend(backend_id, &item.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("存储策略不存在", "Storage not found").to_string()))?;

    let provider = provider_for(&state, &backend).await?;
    let resolved = provider.resolve_download(storage_path).await.map_err(internal_err)?;
    let reserved = match retry_session {
        Some(session) => state.browser_shares.take_fallback(session, &code, &item.id).await,
        None => false,
    };
    if reserved {
        let share_now = lookup_public_share(&state, &ip, &code)?;
        policy::ensure_share_access(&state, &share_now.user_id)?;
        if share_now.expires_at.is_some_and(|expires| expires <= Utc::now()) {
            return Err((StatusCode::GONE, t!("该分享链接已过期", "This share link has expired").to_string()));
        }
    } else if !state.db.increment_share_download(&code).map_err(internal_err)? {
        return Err((StatusCode::GONE, t!("该分享链接已达到下载次数上限", "This share link has reached its download limit").to_string()));
    }

    match resolved {
        DownloadResolution::DirectUrl(url) => Ok(Redirect::temporary(&url).into_response()),
        DownloadResolution::Stream {
            stream,
            content_length,
            content_type,
        } => {
            let mut builder = Response::builder().status(StatusCode::OK);
            let ct = content_type.unwrap_or_else(|| "application/octet-stream".to_string());
            builder = builder.header(header::CONTENT_TYPE, ct);
            if let Some(len) = content_length {
                builder = builder.header(header::CONTENT_LENGTH, len.to_string());
            }
            let encoded_name = urlencoding::encode(&item.name);
            builder = builder.header(
                header::CONTENT_DISPOSITION,
                format!("attachment; filename*=UTF-8''{encoded_name}"),
            );
            // Uploaded content never runs as a page of this origin.
            builder = builder
                .header(header::X_CONTENT_TYPE_OPTIONS, "nosniff")
                .header(header::CONTENT_SECURITY_POLICY, "sandbox");
            let body = Body::from_stream(stream);
            builder.body(body).map_err(internal_err)
        }
    }
}

pub(super) fn lookup_public_share(
    state: &AppState,
    ip: &str,
    code: &str,
) -> Result<crate::db::ShareLinkRow, (StatusCode, String)> {
    if state.failed_share_lookups.is_blocked(ip) {
        return Err((StatusCode::TOO_MANY_REQUESTS, t!("分享链接查询过多，请稍后重试", "Too many share link lookups. Try again later").to_string()));
    }
    // Both legacy eight-character codes and new twelve-character codes are valid.
    if matches!(code.len(), 8 | 12)
        && code.bytes().all(|byte| byte.is_ascii_alphanumeric())
        && let Some(share) = state.db.get_share_link(code).map_err(internal_err)?
    {
        return Ok(share);
    }
    state.failed_share_lookups.record_failure(ip);
    Err((StatusCode::NOT_FOUND, t!("分享链接不存在或已被撤销", "The share link doesn't exist or has been revoked").to_string()))
}

pub(super) async fn public_share_page(Path(code): Path<String>) -> impl IntoResponse {
    // The landing page is static. The metadata and download routes look up
    // the code and enforce the shared miss limit.
    let safe_code: String = code
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    let html = PUBLIC_SHARE_HTML
        .replace("__LANG__", crate::i18n::current().html_tag())
        .replace("__TITLE__", t!("DropDrawer 外链提取", "DropDrawer shared files"))
        .replace("__BRAND__", t!("DropDrawer 外链分享", "DropDrawer share"))
        .replace("__LOADING__", t!("正在加载分享信息...", "Loading the share…"))
        .replace("__SHARE_CODE__", &safe_code);
    (
        [
            (header::VARY, "Accept-Language"),
            (header::REFERRER_POLICY, "no-referrer"),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
            (header::X_FRAME_OPTIONS, "DENY"),
            (header::CONTENT_SECURITY_POLICY, SHARE_PAGE_CSP),
        ],
        Html(html),
    )
}

pub(super) fn generate_short_code() -> String {
    use rand::{distributions::Alphanumeric, rngs::OsRng, Rng};
    OsRng.sample_iter(Alphanumeric).take(12).map(char::from).collect()
}

pub(super) const PUBLIC_SHARE_HTML: &str = include_str!("public_share.html");

/// The page renders with inline script and styles; everything else is
/// same-origin, and the page can't be framed (clickjacking the download button).
const SHARE_PAGE_CSP: &str = "default-src 'none'; script-src 'self' 'unsafe-inline'; \
style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data: blob:; \
base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
