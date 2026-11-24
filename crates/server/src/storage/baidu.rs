use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use futures_util::{StreamExt, TryStreamExt};
use md5::{Digest as Md5Digest, Md5};
use serde::Deserialize;
use serde_json::json;
use tokio::sync::Mutex;

use super::{ByteStream, DownloadResolution, PutResult, StorageProvider};

const BAIDU_SLICE_SIZE: usize = 4 * 1024 * 1024; // 4 MiB standard xpan slice

#[derive(Debug, Clone)]
pub struct BaiduNetdiskConfig {
    pub client_id: String,
    pub client_secret: String,
    pub refresh_token: String,
    pub access_token: String,
    pub root_path: String,
    pub api_base_url: Option<String>,
}

struct CachedBaiduToken {
    access_token: String,
    expires_at: Instant,
}

/// Native Baidu Netdisk OpenAPI xpan storage provider (OAuth2 + precreate/superfile2/create).
/// Zero external sidecars required.
pub struct BaiduNetdiskProvider {
    http: reqwest::Client,
    cfg: BaiduNetdiskConfig,
    token_cache: Arc<Mutex<Option<CachedBaiduToken>>>,
}

#[derive(Debug, Deserialize)]
struct BaiduOAuthResp {
    access_token: String,
    #[serde(default = "default_baidu_exp")]
    expires_in: u64,
}

fn default_baidu_exp() -> u64 {
    2592000
}

#[derive(Debug, Deserialize)]
struct BaiduPrecreateResp {
    errno: i32,
    #[serde(default)]
    uploadid: String,
}

#[derive(Debug, Deserialize)]
struct BaiduCreateResp {
    errno: i32,
    #[serde(default)]
    fs_id: u64,
    #[serde(default)]
    path: String,
}

#[derive(Debug, Deserialize)]
struct BaiduFileMetasResp {
    errno: i32,
    #[serde(default)]
    list: Vec<BaiduFileMeta>,
}

#[derive(Debug, Deserialize)]
struct BaiduFileMeta {
    #[serde(default)]
    dlink: String,
    #[serde(default)]
    size: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct BaiduQuotaResp {
    errno: i32,
    #[serde(default)]
    total: u64,
    #[serde(default)]
    used: u64,
}

impl BaiduNetdiskProvider {
    pub fn new(http: reqwest::Client, cfg: BaiduNetdiskConfig) -> Self {
        Self {
            http,
            cfg,
            token_cache: Arc::new(Mutex::new(None)),
        }
    }

    fn pan_base(&self) -> String {
        self.cfg
            .api_base_url
            .as_deref()
            .unwrap_or("https://pan.baidu.com")
            .trim_end_matches('/')
            .to_string()
    }

    fn pcs_base(&self) -> String {
        self.cfg
            .api_base_url
            .as_deref()
            .unwrap_or("https://d.pcs.baidu.com")
            .trim_end_matches('/')
            .to_string()
    }

    fn remote_path(&self, remote_key: &str) -> String {
        let name = remote_key
            .rsplit('/')
            .next()
            .filter(|s| !s.is_empty())
            .unwrap_or("file.bin");
        let root = self.cfg.root_path.trim().trim_end_matches('/');
        if root.is_empty() {
            format!("/apps/dropdrawer/{name}")
        } else if root.starts_with('/') {
            format!("{root}/{name}")
        } else {
            format!("/{root}/{name}")
        }
    }

    async fn access_token(&self) -> anyhow::Result<String> {
        if self.cfg.refresh_token.trim().is_empty() {
            if !self.cfg.access_token.trim().is_empty() {
                return Ok(self.cfg.access_token.trim().to_string());
            }
            anyhow::bail!("Baidu Netdisk requires access_token or refresh_token");
        }

        let mut guard = self.token_cache.lock().await;
        if let Some(cached) = guard.as_ref() {
            if cached.expires_at > Instant::now() + Duration::from_secs(300) {
                return Ok(cached.access_token.clone());
            }
        }

        let resp = self
            .http
            .post("https://openapi.baidu.com/oauth/2.0/token")
            .form(&[
                ("grant_type", "refresh_token"),
                ("refresh_token", self.cfg.refresh_token.trim()),
                ("client_id", self.cfg.client_id.trim()),
                ("client_secret", self.cfg.client_secret.trim()),
            ])
            .send()
            .await?;

        if !resp.status().is_success() {
            let st = resp.status();
            let txt = resp.text().await.unwrap_or_default();
            anyhow::bail!("Baidu OAuth2 token refresh failed ({st}): {txt}");
        }
        let parsed: BaiduOAuthResp = resp.json().await?;
        let ttl = parsed.expires_in.saturating_sub(300).max(300);
        *guard = Some(CachedBaiduToken {
            access_token: parsed.access_token.clone(),
            expires_at: Instant::now() + Duration::from_secs(ttl),
        });
        Ok(parsed.access_token)
    }

    /// Parses stored key format `"<fs_id>|<path>"`.
    fn parse_stored_key(stored_key: &str) -> (u64, String) {
        if let Some((id_str, path)) = stored_key.split_once('|') {
            let fs_id = id_str.parse::<u64>().unwrap_or(0);
            (fs_id, path.to_string())
        } else {
            (stored_key.parse::<u64>().unwrap_or(0), stored_key.to_string())
        }
    }
}

#[async_trait]
impl StorageProvider for BaiduNetdiskProvider {
    async fn put_stream(
        &self,
        remote_key: &str,
        _content_length: Option<u64>,
        mut stream: ByteStream,
    ) -> anyhow::Result<PutResult> {
        let token = self.access_token().await?;
        let target_path = self.remote_path(remote_key);

        // Buffer to temp file to compute 4MB block MD5 list required by xpan precreate/create.
        let tmp_path = std::env::temp_dir().join(format!(
            "dropdrawer_baidu_{}.tmp",
            uuid::Uuid::new_v4()
        ));
        let mut tmp_file = tokio::fs::File::create(&tmp_path).await?;
        let mut total_bytes = 0u64;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            tokio::io::AsyncWriteExt::write_all(&mut tmp_file, &chunk).await?;
            total_bytes += chunk.len() as u64;
        }
        tokio::io::AsyncWriteExt::flush(&mut tmp_file).await?;
        drop(tmp_file);

        let upload_res = self
            .upload_slices(&token, &target_path, &tmp_path, total_bytes)
            .await;
        let _ = tokio::fs::remove_file(&tmp_path).await;
        let (fs_id, final_path) = upload_res?;

        Ok(PutResult {
            bytes_written: total_bytes,
            stored_key: format!("{fs_id}|{final_path}"),
        })
    }

    async fn resolve_download(&self, stored_key: &str) -> anyhow::Result<DownloadResolution> {
        let token = self.access_token().await?;
        let (fs_id, _) = Self::parse_stored_key(stored_key);
        let url = format!(
            "{}/rest/2.0/xpan/multimedia?method=filemetas&access_token={}&fsids=[{}]&dlink=1",
            self.pan_base(),
            urlencoding::encode(&token),
            fs_id
        );

        let resp = self.http.get(&url).send().await?;
        let metas: BaiduFileMetasResp = resp.json().await?;
        if metas.errno != 0 {
            anyhow::bail!("Baidu filemetas failed (errno {})", metas.errno);
        }
        let item = metas
            .list
            .into_iter()
            .next()
            .ok_or_else(|| anyhow::anyhow!("Baidu filemetas returned empty list"))?;

        let dlink_url = if item.dlink.contains('?') {
            format!("{}&access_token={}", item.dlink, urlencoding::encode(&token))
        } else {
            format!("{}?access_token={}", item.dlink, urlencoding::encode(&token))
        };

        let file_resp = self
            .http
            .get(&dlink_url)
            .header("User-Agent", "pan.baidu.com")
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
        let token = self.access_token().await?;
        let (_, path) = Self::parse_stored_key(stored_key);
        let url = format!(
            "{}/rest/2.0/xpan/file?method=filemanager&access_token={}&opera=delete",
            self.pan_base(),
            urlencoding::encode(&token)
        );
        let filelist = serde_json::to_string(&vec![path])?;
        let resp = self
            .http
            .post(&url)
            .form(&[("async", "0"), ("filelist", filelist.as_str())])
            .send()
            .await?;
        let body: serde_json::Value = resp.json().await?;
        let errno = body["errno"].as_i64().unwrap_or(-1);
        if errno != 0 {
            anyhow::bail!("Baidu delete failed (errno {errno})");
        }
        Ok(())
    }

    async fn health_check(&self) -> anyhow::Result<String> {
        let token = self.access_token().await?;
        let url = format!(
            "{}/api/quota?access_token={}&checkfree=1&checkexpire=1",
            self.pan_base(),
            urlencoding::encode(&token)
        );
        let resp = self.http.get(&url).send().await?;
        let quota: BaiduQuotaResp = resp.json().await?;
        if quota.errno != 0 {
            anyhow::bail!("百度网盘凭证无效 (errno {})", quota.errno);
        }
        let used_gb = quota.used as f64 / 1e9;
        let total_gb = quota.total as f64 / 1e9;
        Ok(format!(
            "百度网盘已连接 · 已用 {used_gb:.2} GB / {total_gb:.1} GB"
        ))
    }
}

impl BaiduNetdiskProvider {
    async fn upload_slices(
        &self,
        token: &str,
        target_path: &str,
        tmp_path: &std::path::Path,
        total_bytes: u64,
    ) -> anyhow::Result<(u64, String)> {
        // Compute 4MB slice MD5 list
        let mut block_list: Vec<String> = Vec::new();
        {
            let mut file = tokio::fs::File::open(tmp_path).await?;
            loop {
                let mut buf = vec![0u8; BAIDU_SLICE_SIZE];
                let mut read_len = 0usize;
                while read_len < BAIDU_SLICE_SIZE {
                    let n = tokio::io::AsyncReadExt::read(&mut file, &mut buf[read_len..]).await?;
                    if n == 0 {
                        break;
                    }
                    read_len += n;
                }
                if read_len == 0 && !block_list.is_empty() {
                    break;
                }
                buf.truncate(read_len);
                block_list.push(hex::encode(Md5::digest(&buf)));
                if read_len < BAIDU_SLICE_SIZE {
                    break;
                }
            }
        }
        let block_list_json = serde_json::to_string(&block_list)?;

        // Step 1: precreate
        let pre_url = format!(
            "{}/rest/2.0/xpan/file?method=precreate&access_token={}",
            self.pan_base(),
            urlencoding::encode(token)
        );
        let pre_resp = self
            .http
            .post(&pre_url)
            .form(&[
                ("path", target_path),
                ("size", &total_bytes.to_string()),
                ("isdir", "0"),
                ("autoinit", "1"),
                ("rtype", "3"),
                ("block_list", &block_list_json),
            ])
            .send()
            .await?;
        let pre: BaiduPrecreateResp = pre_resp.json().await?;
        if pre.errno != 0 {
            anyhow::bail!("Baidu precreate failed (errno {})", pre.errno);
        }

        // Step 2: upload slices via superfile2
        let mut file = tokio::fs::File::open(tmp_path).await?;
        for partseq in 0..block_list.len() {
            let mut buf = vec![0u8; BAIDU_SLICE_SIZE];
            let mut read_len = 0usize;
            while read_len < BAIDU_SLICE_SIZE {
                let n = tokio::io::AsyncReadExt::read(&mut file, &mut buf[read_len..]).await?;
                if n == 0 {
                    break;
                }
                read_len += n;
            }
            buf.truncate(read_len);

            let slice_url = format!(
                "{}/rest/2.0/pcs/superfile2?method=upload&access_token={}&type=tmpfile&path={}&uploadid={}&partseq={}",
                self.pcs_base(),
                urlencoding::encode(token),
                urlencoding::encode(target_path),
                urlencoding::encode(&pre.uploadid),
                partseq
            );
            let part = reqwest::multipart::Part::bytes(buf).file_name("slice.bin");
            let form = reqwest::multipart::Form::new().part("file", part);
            let up_resp = self.http.post(&slice_url).multipart(form).send().await?;
            if !up_resp.status().is_success() {
                let st = up_resp.status();
                let txt = up_resp.text().await.unwrap_or_default();
                anyhow::bail!("Baidu superfile2 part {partseq} failed ({st}): {txt}");
            }
        }

        // Step 3: create (merge)
        let create_url = format!(
            "{}/rest/2.0/xpan/file?method=create&access_token={}",
            self.pan_base(),
            urlencoding::encode(token)
        );
        let create_resp = self
            .http
            .post(&create_url)
            .form(&[
                ("path", target_path),
                ("size", &total_bytes.to_string()),
                ("isdir", "0"),
                ("rtype", "3"),
                ("uploadid", &pre.uploadid),
                ("block_list", &block_list_json),
            ])
            .send()
            .await?;
        let created: BaiduCreateResp = create_resp.json().await?;
        if created.errno != 0 {
            anyhow::bail!("Baidu create failed (errno {})", created.errno);
        }
        let final_path = if created.path.is_empty() {
            target_path.to_string()
        } else {
            created.path
        };
        let _ = json!({}); // keep serde_json import clean if needed
        Ok((created.fs_id, final_path))
    }
}
