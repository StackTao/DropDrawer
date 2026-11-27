use async_trait::async_trait;
use base64::Engine;
use chrono::Utc;
use futures_util::{StreamExt, TryStreamExt};
use md5::{Digest as Md5Digest, Md5};
use serde::Deserialize;
use serde_json::json;
use sha1::Sha1;

use super::{ByteStream, DownloadResolution, PutResult, StorageProvider};

const QUARK_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/3.24.0 Chrome/120.0.0.0 Electron/28.0.0 Safari/537.36";

/// Native Quark Cloud Drive provider (drive-pc.quark.cn Cookie + Alibaba OSS direct multipart upload).
/// Zero external sidecars required.
pub struct QuarkProvider {
    http: reqwest::Client,
    cookie: String,
    root_folder_id: String,
    api_base_url: String,
}

#[derive(Debug, Deserialize)]
struct QuarkResp<T> {
    #[serde(default)]
    code: i32,
    #[serde(default)]
    message: String,
    data: Option<T>,
    metadata: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct QuarkPreData {
    #[serde(default)]
    finish: bool,
    #[serde(default)]
    fid: Option<String>,
    #[serde(default)]
    task_id: String,
    #[serde(default)]
    upload_id: String,
    #[serde(default)]
    obj_key: String,
    #[serde(default)]
    upload_url: String,
    #[serde(default)]
    bucket: String,
    #[serde(default)]
    auth_info: String,
    #[serde(default)]
    callback: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct QuarkHashData {
    #[serde(default)]
    finish: bool,
    #[serde(default)]
    fid: Option<String>,
}

#[derive(Debug, Deserialize)]
struct QuarkAuthData {
    auth_key: String,
}

#[derive(Debug, Deserialize)]
struct QuarkFinishData {
    #[serde(default)]
    fid: String,
}

#[derive(Debug, Deserialize)]
struct QuarkDownloadItem {
    download_url: String,
    #[serde(default)]
    size: Option<u64>,
}

impl QuarkProvider {
    pub fn new(
        http: reqwest::Client,
        cookie: String,
        root_folder_id: String,
        api_base_url: Option<String>,
    ) -> Self {
        Self {
            http,
            cookie: cookie.trim().to_string(),
            root_folder_id: if root_folder_id.trim().is_empty() {
                "0".to_string()
            } else {
                root_folder_id.trim().to_string()
            },
            api_base_url: api_base_url
                .unwrap_or_else(|| "https://drive-pc.quark.cn".to_string())
                .trim_end_matches('/')
                .to_string(),
        }
    }

    fn endpoint(&self, path: &str) -> String {
        let ts = Utc::now().timestamp_millis();
        format!(
            "{}{}?pr=ucpro&fr=pc&uc_param_str=&__t={}",
            self.api_base_url, path, ts
        )
    }

    fn apply_headers(&self, req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        req.header("Cookie", &self.cookie)
            .header("User-Agent", QUARK_UA)
            .header("Referer", "https://pan.quark.cn/")
            .header("Origin", "https://pan.quark.cn")
    }
}

#[async_trait]
impl StorageProvider for QuarkProvider {
    async fn put_stream(
        &self,
        remote_key: &str,
        _content_length: Option<u64>,
        mut stream: ByteStream,
    ) -> anyhow::Result<PutResult> {
        // Buffer stream into a temp file to compute MD5 + SHA1 required by Quark pre-upload & hash check
        // without blowing RAM on large files.
        let tmp_path = std::env::temp_dir().join(format!(
            "dropdrawer_quark_{}.tmp",
            uuid::Uuid::new_v4()
        ));
        let mut tmp_file = tokio::fs::File::create(&tmp_path).await?;
        let mut md5 = Md5::new();
        let mut sha1 = Sha1::new();
        let mut total_bytes = 0u64;

        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            md5.update(&chunk);
            sha1.update(&chunk);
            tokio::io::AsyncWriteExt::write_all(&mut tmp_file, &chunk).await?;
            total_bytes += chunk.len() as u64;
        }
        tokio::io::AsyncWriteExt::flush(&mut tmp_file).await?;
        drop(tmp_file);

        let md5_hex = hex::encode(md5.finalize());
        let sha1_hex = hex::encode(sha1.finalize());
        let file_name = remote_key
            .rsplit('/')
            .next()
            .filter(|s| !s.is_empty())
            .unwrap_or("file.bin");

        let upload_res = self
            .upload_local_temp(&tmp_path, file_name, total_bytes, &md5_hex, &sha1_hex)
            .await;
        let _ = tokio::fs::remove_file(&tmp_path).await;
        let fid = upload_res?;

        Ok(PutResult {
            bytes_written: total_bytes,
            stored_key: fid,
        })
    }

    async fn resolve_download(&self, stored_key: &str) -> anyhow::Result<DownloadResolution> {
        let resp = self
            .apply_headers(self.http.post(self.endpoint("/1/clouddrive/file/download")))
            .json(&json!({ "fids": [stored_key] }))
            .send()
            .await?;

        let env: QuarkResp<Vec<QuarkDownloadItem>> = resp.json().await?;
        if env.code != 0 {
            anyhow::bail!("Quark download link failed ({}): {}", env.code, env.message);
        }
        let item = env
            .data
            .and_then(|mut v| v.pop())
            .ok_or_else(|| anyhow::anyhow!("Quark returned empty download list"))?;

        // Proxy with Quark Cookie + PC UA so clients never hit UA/Cookie 403 rejections.
        let file_resp = self
            .apply_headers(self.http.get(&item.download_url))
            .send()
            .await?
            .error_for_status()?;
        let content_length = file_resp.content_length().or(item.size);
        let content_type = file_resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        let stream = file_resp.bytes_stream().map_err(anyhow::Error::from);

        Ok(DownloadResolution::Stream {
            stream: Box::pin(stream),
            content_length,
            content_type,
        })
    }

    async fn delete(&self, stored_key: &str) -> anyhow::Result<()> {
        let resp = self
            .apply_headers(self.http.post(self.endpoint("/1/clouddrive/file/delete")))
            .json(&json!({
                "action_type": 2,
                "filelist": [stored_key],
                "exclude_fids": []
            }))
            .send()
            .await?;

        let env: QuarkResp<serde_json::Value> = resp.json().await?;
        if env.code != 0 {
            anyhow::bail!("Quark delete failed ({}): {}", env.code, env.message);
        }
        Ok(())
    }

    async fn health_check(&self) -> anyhow::Result<String> {
        let url = format!(
            "{}&pdir_fid={}&_page=1&_size=1&_fetch_total=1",
            self.endpoint("/1/clouddrive/file/sort"),
            urlencoding::encode(&self.root_folder_id)
        );
        let resp = self.apply_headers(self.http.get(&url)).send().await?;
        let env: QuarkResp<serde_json::Value> = resp.json().await?;
        if env.code != 0 {
            anyhow::bail!("{}", tf!("夸克网盘 Cookie 无效或已过期 ({}): {}", "Quark Drive cookie is invalid or expired ({}): {}", env.code, env.message));
        }
        Ok(tf!("夸克网盘已连接 (目录 fid: {})", "Quark Drive connected (folder fid: {})",
            self.root_folder_id
        ))
    }
}

impl QuarkProvider {
    async fn upload_local_temp(
        &self,
        tmp_path: &std::path::Path,
        file_name: &str,
        size: u64,
        md5_hex: &str,
        sha1_hex: &str,
    ) -> anyhow::Result<String> {
        let now_ms = Utc::now().timestamp_millis();

        // Step 1: Pre-upload
        let pre_resp = self
            .apply_headers(
                self.http
                    .post(self.endpoint("/1/clouddrive/file/upload/pre")),
            )
            .json(&json!({
                "ccp_hash_update": true,
                "parallel_upload": true,
                "pdir_fid": self.root_folder_id,
                "dir_name": "",
                "size": size,
                "file_name": file_name,
                "format_type": "application/octet-stream",
                "l_updated_at": now_ms,
                "l_created_at": now_ms,
            }))
            .send()
            .await?;
        let pre_env: QuarkResp<QuarkPreData> = pre_resp.json().await?;
        if pre_env.code != 0 {
            anyhow::bail!(
                "Quark pre-upload failed ({}): {}",
                pre_env.code,
                pre_env.message
            );
        }
        let pre = pre_env
            .data
            .ok_or_else(|| anyhow::anyhow!("Quark pre-upload missing data"))?;

        if pre.finish
            && let Some(fid) = pre.fid
        {
            return Ok(fid);
        }

        // Step 2: Update hash (triggers rapid/instant upload if cloud already has this file)
        let hash_resp = self
            .apply_headers(
                self.http
                    .post(self.endpoint("/1/clouddrive/file/update/hash")),
            )
            .json(&json!({
                "md5": md5_hex,
                "sha1": sha1_hex,
                "task_id": pre.task_id,
            }))
            .send()
            .await?;
        let hash_env: QuarkResp<QuarkHashData> = hash_resp.json().await?;
        if hash_env.code == 0
            && let Some(hd) = hash_env.data
            && hd.finish
            && let Some(fid) = hd.fid.or(pre.fid.clone())
        {
            return Ok(fid);
        }

        // Step 3: Multipart upload chunks to Alibaba OSS using Quark-signed auth_key
        let part_size: usize = pre_env
            .metadata
            .as_ref()
            .and_then(|m| m.get("part_size"))
            .and_then(|v| v.as_u64())
            .unwrap_or(4 * 1024 * 1024) as usize;

        let upload_host = pre
            .upload_url
            .trim_start_matches("https://")
            .trim_start_matches("http://")
            .trim_end_matches('/');

        let mut file = tokio::fs::File::open(tmp_path).await?;
        let mut etags: Vec<(usize, String)> = Vec::new();
        let mut part_num = 1usize;

        loop {
            let mut buf = vec![0u8; part_size];
            let mut read_len = 0usize;
            while read_len < part_size {
                let n = tokio::io::AsyncReadExt::read(&mut file, &mut buf[read_len..]).await?;
                if n == 0 {
                    break;
                }
                read_len += n;
            }
            if read_len == 0 && part_num > 1 {
                break;
            }
            buf.truncate(read_len);

            let date_str = Utc::now().format("%a, %d %b %Y %H:%M:%S GMT").to_string();
            let canonical_resource = format!(
                "/{}/{}?partNumber={}&uploadId={}",
                pre.bucket, pre.obj_key, part_num, pre.upload_id
            );
            let auth_meta = format!(
                "PUT\n\napplication/octet-stream\n{date_str}\nx-oss-date:{date_str}\nx-oss-user-agent:aliyun-sdk-js/6.6.1 Chrome 120.0.0.0 on Windows 10 64-bit\n{canonical_resource}"
            );
            let auth_key = self
                .request_oss_auth(&pre.task_id, &pre.auth_info, &auth_meta)
                .await?;

            let oss_url = format!(
                "https://{}.{}/{}?partNumber={}&uploadId={}",
                pre.bucket, upload_host, pre.obj_key, part_num, pre.upload_id
            );
            let oss_resp = self
                .http
                .put(&oss_url)
                .header("Authorization", &auth_key)
                .header("Content-Type", "application/octet-stream")
                .header("x-oss-date", &date_str)
                .header(
                    "x-oss-user-agent",
                    "aliyun-sdk-js/6.6.1 Chrome 120.0.0.0 on Windows 10 64-bit",
                )
                .body(buf)
                .send()
                .await?;
            if !oss_resp.status().is_success() {
                let st = oss_resp.status();
                let txt = oss_resp.text().await.unwrap_or_default();
                anyhow::bail!("Quark OSS part {part_num} failed ({st}): {txt}");
            }
            let etag = oss_resp
                .headers()
                .get("ETag")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("\"\"")
                .to_string();
            etags.push((part_num, etag));
            part_num += 1;
            if read_len < part_size {
                break;
            }
        }

        // Step 4: Complete OSS Multipart Upload with callback
        let mut xml = String::from("<CompleteMultipartUpload>");
        for (idx, etag) in &etags {
            xml.push_str(&format!(
                "<Part><PartNumber>{idx}</PartNumber><ETag>{etag}</ETag></Part>"
            ));
        }
        xml.push_str("</CompleteMultipartUpload>");

        let xml_md5 = base64::engine::general_purpose::STANDARD.encode(Md5::digest(xml.as_bytes()));
        let cb_b64 = pre.callback.as_ref().map(|c| {
            base64::engine::general_purpose::STANDARD
                .encode(serde_json::to_vec(c).unwrap_or_default())
        });
        let date_str = Utc::now().format("%a, %d %b %Y %H:%M:%S GMT").to_string();
        let canonical_resource =
            format!("/{}/{}?uploadId={}", pre.bucket, pre.obj_key, pre.upload_id);
        let mut oss_headers = String::new();
        if let Some(ref cb) = cb_b64 {
            oss_headers.push_str(&format!("x-oss-callback:{cb}\n"));
        }
        oss_headers.push_str(&format!("x-oss-date:{date_str}\n"));
        oss_headers.push_str(
            "x-oss-user-agent:aliyun-sdk-js/6.6.1 Chrome 120.0.0.0 on Windows 10 64-bit\n",
        );

        let commit_meta = format!(
            "POST\n{xml_md5}\napplication/xml\n{date_str}\n{oss_headers}{canonical_resource}"
        );
        let commit_auth = self
            .request_oss_auth(&pre.task_id, &pre.auth_info, &commit_meta)
            .await?;

        let commit_url = format!(
            "https://{}.{}/{}?uploadId={}",
            pre.bucket, upload_host, pre.obj_key, pre.upload_id
        );
        let mut commit_req = self
            .http
            .post(&commit_url)
            .header("Authorization", &commit_auth)
            .header("Content-MD5", &xml_md5)
            .header("Content-Type", "application/xml")
            .header("x-oss-date", &date_str)
            .header(
                "x-oss-user-agent",
                "aliyun-sdk-js/6.6.1 Chrome 120.0.0.0 on Windows 10 64-bit",
            );
        if let Some(ref cb) = cb_b64 {
            commit_req = commit_req.header("x-oss-callback", cb);
        }
        let commit_resp = commit_req.body(xml).send().await?;
        if !commit_resp.status().is_success() {
            let st = commit_resp.status();
            let txt = commit_resp.text().await.unwrap_or_default();
            anyhow::bail!("Quark OSS commit failed ({st}): {txt}");
        }

        // Step 5: Notify Quark finish endpoint
        let finish_resp = self
            .apply_headers(
                self.http
                    .post(self.endpoint("/1/clouddrive/file/upload/finish")),
            )
            .json(&json!({
                "obj_key": pre.obj_key,
                "task_id": pre.task_id,
            }))
            .send()
            .await?;
        let finish_env: QuarkResp<QuarkFinishData> = finish_resp.json().await?;
        if finish_env.code != 0 {
            anyhow::bail!(
                "Quark upload finish failed ({}): {}",
                finish_env.code,
                finish_env.message
            );
        }
        let fid = finish_env
            .data
            .map(|d| d.fid)
            .filter(|f| !f.is_empty())
            .or(pre.fid)
            .ok_or_else(|| anyhow::anyhow!("Quark finish returned no fid"))?;
        Ok(fid)
    }

    async fn request_oss_auth(
        &self,
        task_id: &str,
        auth_info: &str,
        auth_meta: &str,
    ) -> anyhow::Result<String> {
        let resp = self
            .apply_headers(
                self.http
                    .post(self.endpoint("/1/clouddrive/file/upload/auth")),
            )
            .json(&json!({
                "task_id": task_id,
                "auth_info": auth_info,
                "auth_meta": auth_meta,
            }))
            .send()
            .await?;
        let env: QuarkResp<QuarkAuthData> = resp.json().await?;
        if env.code != 0 {
            anyhow::bail!("Quark OSS auth failed ({}): {}", env.code, env.message);
        }
        env.data
            .map(|d| d.auth_key)
            .ok_or_else(|| anyhow::anyhow!("Quark OSS auth missing auth_key"))
    }
}
