//! Sign-up, sign-in, email codes, password reset and the self-service account
//! endpoints (`/api/auth/...`).

use super::*;

pub(super) fn hash_email_code(email: &str, purpose: &str, code: &str, secret: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(secret.as_bytes());
    hasher.update(b":");
    hasher.update(purpose.as_bytes());
    hasher.update(b":");
    hasher.update(email.trim().to_ascii_lowercase().as_bytes());
    hasher.update(b":");
    hasher.update(code.trim().as_bytes());
    hex::encode(hasher.finalize())
}

pub(super) fn generate_six_digit_code() -> String {
    use rand::{RngCore, rngs::OsRng};
    let n = OsRng.next_u32() % 1_000_000;
    format!("{n:06}")
}

pub(super) async fn auth_public_config(State(state): State<Arc<AppState>>) -> Json<AuthPublicConfig> {
    let settings = state.runtime_settings();
    Json(settings.to_public_auth_config(state.has_custom_email_sender()))
}

pub(super) async fn send_email_code(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SendEmailCodeRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let email = req.email.trim().to_ascii_lowercase();
    if !is_valid_email(&email) {
        return Err((StatusCode::BAD_REQUEST, t!("邮箱地址格式无效", "Invalid email address").to_string()));
    }
    let purpose = req.purpose.trim();
    if purpose != "register" && purpose != "reset_password" {
        return Err((StatusCode::BAD_REQUEST, t!("无效的验证码用途", "Invalid code purpose").to_string()));
    }

    let settings = state.runtime_settings();
    let email_ready = settings.smtp.is_usable() || state.has_custom_email_sender();
    if !email_ready {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            t!("当前服务器未启用邮件服务", "Email is not enabled on this server").to_string(),
        ));
    }

    let rate_key = format!("{purpose}:{email}");
    if state.email_send_limiter.is_blocked(&rate_key) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            t!("发送验证码过于频繁，请稍后再试", "Too many code requests. Try again later").to_string(),
        ));
    }
    if let Some(last) = state
        .db
        .last_email_verification_at(&email, purpose)
        .map_err(internal_err)?
    {
        let elapsed = (Utc::now() - last).num_seconds();
        if elapsed < 60 {
            return Err((
                StatusCode::TOO_MANY_REQUESTS,
                tf!("请等待 {} 秒后再重新发送验证码", "Wait {} seconds before requesting another code", (60 - elapsed).max(1)),
            ));
        }
    }

    if purpose == "register" {
        if settings.registration_mode == RegistrationMode::Closed {
            return Err((
                StatusCode::FORBIDDEN,
                t!("当前服务器已关闭新用户注册", "This server doesn't accept new sign-ups").to_string(),
            ));
        }
        if let Err(msg) = settings.check_email_domain(&email) {
            return Err((StatusCode::FORBIDDEN, msg));
        }
        if state
            .db
            .find_user_by_email(&email)
            .map_err(internal_err)?
            .is_some()
        {
            return Err((StatusCode::CONFLICT, t!("该邮箱已被注册", "This email is already registered").to_string()));
        }
    } else {
        if !settings.features.password_reset_enabled {
            return Err((
                StatusCode::FORBIDDEN,
                t!("管理员已关闭邮箱找回密码", "The administrator has turned off password reset by email").to_string(),
            ));
        }
        // Avoid user-enumeration: if email is unknown or disabled, still return ok without sending.
        let existing = state.db.find_user_by_email(&email).map_err(internal_err)?;
        if existing.is_none_or(|u| !u.email_verified || u.disabled) {
            state.email_send_limiter.record_failure(&rate_key);
            return Ok(Json(serde_json::json!({ "ok": true })));
        }
    }

    state.email_send_limiter.record_failure(&rate_key);
    let code = generate_six_digit_code();
    let code_hash = hash_email_code(&email, purpose, &code, &state.jwt_secret);
    let expires_at = Utc::now() + Duration::minutes(10);
    state
        .db
        .create_email_verification(&email, purpose, &code_hash, expires_at)
        .map_err(internal_err)?;

    let message = build_verification_email(&email, &code, purpose);
    state
        .send_email(&message)
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, tf!("邮件发送失败: {e}", "Couldn't send the email: {e}")))?;

    Ok(Json(serde_json::json!({ "ok": true })))
}

pub(super) async fn reset_password(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    Json(req): Json<ResetPasswordRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let email = req.email.trim().to_ascii_lowercase();
    if !is_valid_email(&email) {
        return Err((StatusCode::BAD_REQUEST, t!("邮箱地址格式无效", "Invalid email address").to_string()));
    }
    if req.new_password.len() < 6 {
        return Err((StatusCode::BAD_REQUEST, t!("新密码长度至少 6 位", "The new password must be at least 6 characters").to_string()));
    }
    let settings = state.runtime_settings();
    if !settings.features.password_reset_enabled {
        return Err((
            StatusCode::FORBIDDEN,
            t!("管理员已关闭邮箱找回密码", "The administrator has turned off password reset by email").to_string(),
        ));
    }
    if !settings.smtp.is_usable() && !state.has_custom_email_sender() {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            t!("当前服务器未启用邮件服务", "Email is not enabled on this server").to_string(),
        ));
    }

    let code_hash = hash_email_code(&email, "reset_password", &req.code, &state.jwt_secret);
    let valid = state
        .db
        .verify_and_consume_email_code(&email, "reset_password", &code_hash)
        .map_err(internal_err)?;
    if !valid {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("验证码无效或已过期，请重新获取", "The code is invalid or expired. Request a new one").to_string(),
        ));
    }

    let Some(user) = state.db.find_user_by_email(&email).map_err(internal_err)? else {
        return Err((StatusCode::BAD_REQUEST, t!("验证码无效或已过期", "The code is invalid or expired").to_string()));
    };
    if !user.email_verified || user.disabled {
        return Err((StatusCode::FORBIDDEN, t!("该账号当前不可重置密码", "This account's password can't be reset right now").to_string()));
    }

    let hash = hash_password(&req.new_password).map_err(internal_err)?;
    state
        .db
        .update_user_password(&user.id, &hash)
        .map_err(internal_err)?;
    // A reset password must also end sessions that may have been opened with the old one.
    state.revoke_user_sessions(&user.id, None).await.map_err(internal_err)?;
    state.failed_logins.reset(&login_limit_key(&ip, &user.username));
    state.failed_logins.reset(&login_limit_key(&ip, &email));

    Ok(Json(serde_json::json!({ "ok": true })))
}

pub(super) async fn register(
    State(state): State<Arc<AppState>>,
    Json(req): Json<RegisterRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    let settings = state.runtime_settings();
    match settings.registration_mode {
        RegistrationMode::Closed => {
            return Err((
                StatusCode::FORBIDDEN,
                "registration is disabled on this server".to_string(),
            ));
        }
        RegistrationMode::InviteOnly => {
            let code = req.invite_code.as_deref().map(str::trim).unwrap_or("");
            if code.is_empty() {
                return Err((StatusCode::FORBIDDEN, t!("当前服务器仅支持邀请码注册", "This server only accepts sign-ups with an invitation code").to_string()));
            }
            if !state.db.is_invite_code_valid(code).map_err(internal_err)? {
                return Err((StatusCode::FORBIDDEN, t!("邀请码无效、已用完或已过期", "The invitation code is invalid, used up or expired").to_string()));
            }
        }
        RegistrationMode::Open => {}
    }

    let username = req.username.trim();
    if username.len() < 2 || req.password.len() < 6 {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("用户名至少 2 个字符，密码至少 6 位", "Usernames need at least 2 characters and passwords at least 6").to_string(),
        ));
    }
    policy::validate_username(username)?;

    if state
        .db
        .find_user_by_username(username)
        .map_err(internal_err)?
        .is_some()
    {
        return Err((StatusCode::CONFLICT, t!("该用户名已被注册", "This username is already taken").to_string()));
    }

    let email_ready = settings.smtp.is_usable() || state.has_custom_email_sender();
    let require_email = settings.email_verification_required && email_ready;
    let supplied_email = req
        .email
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_ascii_lowercase());

    let (verified_email, email_verified) = if require_email || supplied_email.is_some() {
        let Some(email) = supplied_email else {
            return Err((StatusCode::BAD_REQUEST, t!("请填写注册邮箱并完成验证码校验", "Enter your email and verify it with the code").to_string()));
        };
        if !is_valid_email(&email) {
            return Err((StatusCode::BAD_REQUEST, t!("邮箱地址格式无效", "Invalid email address").to_string()));
        }
        if let Err(msg) = settings.check_email_domain(&email) {
            return Err((StatusCode::FORBIDDEN, msg));
        }
        if state
            .db
            .find_user_by_email(&email)
            .map_err(internal_err)?
            .is_some()
        {
            return Err((StatusCode::CONFLICT, t!("该邮箱已被注册", "This email is already registered").to_string()));
        }
        if require_email || req.email_code.as_deref().is_some_and(|c| !c.trim().is_empty()) {
            let code = req.email_code.as_deref().unwrap_or("").trim();
            if code.is_empty() {
                return Err((StatusCode::BAD_REQUEST, t!("请输入邮箱验证码", "Enter the email verification code").to_string()));
            }
            let code_hash = hash_email_code(&email, "register", code, &state.jwt_secret);
            let ok = state
                .db
                .verify_and_consume_email_code(&email, "register", &code_hash)
                .map_err(internal_err)?;
            if !ok {
                return Err((
                    StatusCode::BAD_REQUEST,
                    t!("邮箱验证码无效或已过期，请重新获取", "The email code is invalid or expired. Request a new one").to_string(),
                ));
            }
            (Some(email), true)
        } else {
            (Some(email), false)
        }
    } else {
        (None, false)
    };

    if settings.registration_mode == RegistrationMode::InviteOnly {
        let code = req.invite_code.as_deref().unwrap_or("");
        let consumed = state.db.consume_invite_code(code).map_err(internal_err)?;
        if !consumed {
            return Err((StatusCode::FORBIDDEN, t!("邀请码无效、已用完或已过期", "The invitation code is invalid, used up or expired").to_string()));
        }
    }

    let hash = hash_password(&req.password).map_err(internal_err)?;
    let user_id = Uuid::new_v4().to_string();
    let user = state
        .db
        .create_user_with_email(
            &user_id,
            username,
            &hash,
            verified_email.as_deref(),
            email_verified,
        )
        .map_err(internal_err)?;
    let token = issue_user_token(&state, &user.id, &user.username).map_err(internal_err)?;
    let _ = state.db.touch_last_login(&user.id);

    Ok(Json(AuthResponse { token, user }))
}

pub(super) fn login_limit_key(ip: &str, username: &str) -> String {
    format!("{ip}|{}", username.trim().to_lowercase())
}

pub(super) async fn login(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    Json(req): Json<LoginRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    if !state.runtime_settings().password_login_enabled {
        return Err((
            StatusCode::FORBIDDEN,
            t!("当前服务器已关闭账号密码登录，请使用其他已启用的登录方式", "Password sign-in is turned off on this server. Use another enabled sign-in method").to_string(),
        ));
    }
    let limit_key = login_limit_key(&ip, &req.username);
    if state.failed_logins.is_blocked(&limit_key) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "too many failed login attempts, try again later".to_string(),
        ));
    }
    let invalid = || {
        state.failed_logins.record_failure(&limit_key);
        (StatusCode::UNAUTHORIZED, t!("用户名或密码错误", "Incorrect username or password").to_string())
    };
    let user_rec = state
        .db
        .find_user_by_identifier(req.username.trim())
        .map_err(internal_err)?
        .ok_or_else(invalid)?;

    if user_rec.disabled {
        return Err((
            StatusCode::FORBIDDEN,
            t!("该账号已被管理员禁用", "This account has been disabled by an administrator").to_string(),
        ));
    }

    if !verify_password_blocking(&req.password, &user_rec.password_hash).await {
        return Err(invalid());
    }
    state.failed_logins.reset(&limit_key);

    let token = create_versioned_jwt(
        &user_rec.id,
        &user_rec.username,
        user_rec.token_version,
        &state.jwt_secret,
    )
    .map_err(internal_err)?;
    let _ = state.db.touch_last_login(&user_rec.id);
    Ok(Json(AuthResponse {
        token,
        user: protocol::UserProfile {
            id: user_rec.id,
            username: user_rec.username,
            email: user_rec.email,
            created_at: user_rec.created_at,
        },
    }))
}

pub(super) fn build_account_info(state: &AppState, user: &crate::db::UserRecord) -> anyhow::Result<AccountInfo> {
    let settings = state.runtime_settings();
    let google_linked = state.db.user_has_google_link(&user.id)?;
    let email_binding_available = settings.smtp.is_usable() || state.has_custom_email_sender();
    Ok(AccountInfo {
        id: user.id.clone(),
        username: user.username.clone(),
        email: user.email.clone(),
        email_verified: user.email_verified,
        has_password: !user.password_hash.trim().is_empty(),
        google_linked,
        email_binding_available,
        created_at: user.created_at,
    })
}

pub(super) async fn get_own_account(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<AccountInfo>, (StatusCode, String)> {
    let user = state
        .db
        .find_user_by_id(&auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("账号不存在", "account not found").to_string()))?;
    let info = build_account_info(&state, &user).map_err(internal_err)?;
    Ok(Json(info))
}

pub(super) async fn change_own_password(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<ChangePasswordRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    if req.new_password.len() < 6 {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("新密码长度至少 6 位", "New password must be at least 6 characters").to_string(),
        ));
    }
    let user = state
        .db
        .find_user_by_id(&auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("账号不存在", "account not found").to_string()))?;

    // A Google-only account adding its first password must also prove it is the holder.
    confirm_account_holder(&auth, &user, req.current_password.as_deref()).await?;

    let hash = hash_password(&req.new_password).map_err(internal_err)?;
    state
        .db
        .update_user_password(&user.id, &hash)
        .map_err(internal_err)?;
    // The initiating device reconnects with the new token after this response.
    state
        .revoke_user_sessions(&user.id, req.device_id.as_deref())
        .await
        .map_err(internal_err)?;
    state.failed_logins.reset(&user.username.to_lowercase());
    if let Some(ref email) = user.email {
        state.failed_logins.reset(&email.to_lowercase());
    }
    let token = issue_user_token(&state, &user.id, &user.username).map_err(internal_err)?;
    Ok(Json(AuthResponse {
        token,
        user: protocol::UserProfile {
            id: user.id,
            username: user.username,
            email: user.email,
            created_at: user.created_at,
        },
    }))
}

pub(super) async fn send_bind_email_code(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<BindEmailSendCodeRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let user = state
        .db
        .find_user_by_id(&auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("账号不存在", "account not found").to_string()))?;
    // Passwordless accounts must have signed in recently; password accounts give
    // their password when confirming the code. Checking now saves a wasted email.
    if user.password_hash.trim().is_empty() {
        confirm_account_holder(&auth, &user, None).await?;
    }
    let email = req.email.trim().to_ascii_lowercase();
    if !is_valid_email(&email) {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("邮箱地址格式无效", "Invalid email address").to_string(),
        ));
    }
    let settings = state.runtime_settings();
    if !settings.smtp.is_usable() && !state.has_custom_email_sender() {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            t!("当前服务器未启用邮件服务", "Email service is not enabled on this server").to_string(),
        ));
    }
    if let Err(msg) = settings.check_email_domain(&email) {
        return Err((StatusCode::FORBIDDEN, msg));
    }
    if let Some(owner) = state.db.find_user_by_email(&email).map_err(internal_err)?
        && owner.id != auth.user_id
    {
        return Err((
            StatusCode::CONFLICT,
            t!("该邮箱已被其他账号使用", "That email address is already in use").to_string(),
        ));
    }

    let purpose = "bind_email";
    let rate_key = format!("{purpose}:{email}");
    if state.email_send_limiter.is_blocked(&rate_key) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            t!("发送验证码过于频繁，请稍后再试", "Too many verification codes sent; try again later").to_string(),
        ));
    }
    if let Some(last) = state
        .db
        .last_email_verification_at(&email, purpose)
        .map_err(internal_err)?
    {
        let elapsed = (Utc::now() - last).num_seconds();
        if elapsed < 60 {
            let wait = (60 - elapsed).max(1);
            return Err((
                StatusCode::TOO_MANY_REQUESTS,
                tf!(
                    "请等待 {wait} 秒后再重新发送验证码",
                    "Please wait {wait} seconds before requesting another code"
                ),
            ));
        }
    }

    state.email_send_limiter.record_failure(&rate_key);
    let code = generate_six_digit_code();
    let code_hash = hash_email_code(&email, purpose, &code, &state.jwt_secret);
    let expires_at = Utc::now() + Duration::minutes(10);
    state
        .db
        .create_email_verification(&email, purpose, &code_hash, expires_at)
        .map_err(internal_err)?;

    let message = build_verification_email(&email, &code, purpose);
    state
        .send_email(&message)
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, tf!("邮件发送失败: {e}", "Failed to send email: {e}")))?;

    Ok(Json(serde_json::json!({ "ok": true })))
}

pub(super) async fn confirm_bind_email(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<BindEmailConfirmRequest>,
) -> Result<Json<AccountInfo>, (StatusCode, String)> {
    let user = state
        .db
        .find_user_by_id(&auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("账号不存在", "account not found").to_string()))?;
    // The email is where password resets go, so a session alone must not change it.
    confirm_account_holder(&auth, &user, req.current_password.as_deref()).await?;
    let email = req.email.trim().to_ascii_lowercase();
    if !is_valid_email(&email) {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("邮箱地址格式无效", "Invalid email address").to_string(),
        ));
    }
    let settings = state.runtime_settings();
    if !settings.smtp.is_usable() && !state.has_custom_email_sender() {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            t!("当前服务器未启用邮件服务", "Email service is not enabled on this server").to_string(),
        ));
    }
    if let Err(msg) = settings.check_email_domain(&email) {
        return Err((StatusCode::FORBIDDEN, msg));
    }
    if let Some(owner) = state.db.find_user_by_email(&email).map_err(internal_err)?
        && owner.id != auth.user_id
    {
        return Err((
            StatusCode::CONFLICT,
            t!("该邮箱已被其他账号使用", "That email address is already in use").to_string(),
        ));
    }

    let code_hash = hash_email_code(&email, "bind_email", &req.code, &state.jwt_secret);
    let valid = state
        .db
        .verify_and_consume_email_code(&email, "bind_email", &code_hash)
        .map_err(internal_err)?;
    if !valid {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("验证码无效或已过期，请重新获取", "Verification code is invalid or expired").to_string(),
        ));
    }

    state
        .db
        .set_user_verified_email(&auth.user_id, &email)
        .map_err(internal_err)?;
    let user = state
        .db
        .find_user_by_id(&auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("账号不存在", "account not found").to_string()))?;
    let info = build_account_info(&state, &user).map_err(internal_err)?;
    Ok(Json(info))
}

pub(super) async fn delete_own_account(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<DeleteOwnAccountRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let user = state
        .db
        .find_user_by_id(&auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("账号不存在", "account not found").to_string()))?;

    let has_password = !user.password_hash.trim().is_empty();
    if !has_password {
        let confirm = req.confirm_username.as_deref().map(str::trim).unwrap_or("");
        if confirm != user.username {
            return Err((
                StatusCode::BAD_REQUEST,
                t!("请输入完整用户名以确认注销账号", "Enter your exact username to confirm account deletion").to_string(),
            ));
        }
    }
    confirm_account_holder(&auth, &user, req.password.as_deref()).await?;

    state.disconnect_user(&user.id);
    let failed = state.delete_all_drawer_items(&user.id).await.map_err(internal_err)?;
    if failed > 0 {
        // Deleting the account would also drop the storage credentials and the
        // records that let cleanup retry, leaving the files in the user's cloud
        // for good. Keep the account so the user can try again.
        let message = if crate::i18n::is_en() {
            let files = if failed == 1 { "1 file" } else { "files" };
            let files = if failed == 1 { files.to_string() } else { format!("{failed} {files}") };
            format!("{files} couldn't be removed from cloud storage, so the account wasn't deleted. Check the storage connection and try again")
        } else {
            format!("有 {failed} 个文件暂时无法从云盘删除，账号尚未注销。请检查云盘连接后重试")
        };
        return Err((StatusCode::BAD_GATEWAY, message));
    }
    state.db.delete_user(&user.id).map_err(internal_err)?;
    Ok(StatusCode::NO_CONTENT)
}


/// How long after signing in a passwordless (Google-only) account may change
/// its security settings. A session alone, however old, is not enough.
pub(super) const RECENT_SIGN_IN_MINUTES: i64 = 10;

/// Confirms the request comes from the account holder, not just someone holding
/// a session: the current password when the account has one, otherwise a sign-in
/// within the last few minutes (signing in with Google again proves it).
pub(super) async fn confirm_account_holder(
    auth: &AuthUser,
    user: &crate::db::UserRecord,
    password: Option<&str>,
) -> Result<(), (StatusCode, String)> {
    if !user.password_hash.trim().is_empty() {
        let password = password.unwrap_or("");
        if password.is_empty() || !verify_password_blocking(password, &user.password_hash).await {
            return Err((
                StatusCode::UNAUTHORIZED,
                t!("当前密码不正确", "Current password is incorrect").to_string(),
            ));
        }
        return Ok(());
    }
    if Utc::now() - auth.issued_at <= Duration::minutes(RECENT_SIGN_IN_MINUTES) {
        return Ok(());
    }
    Err((
        StatusCode::FORBIDDEN,
        tf!(
            "为了保护账号安全，请退出后重新用 Google 登录，并在 {RECENT_SIGN_IN_MINUTES} 分钟内完成此操作",
            "For your security, sign out, sign in with Google again, and finish this within {RECENT_SIGN_IN_MINUTES} minutes"
        ),
    ))
}
