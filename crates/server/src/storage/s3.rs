use async_trait::async_trait;
use chrono::Utc;
use futures_util::TryStreamExt;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use url::Url;

use super::{ByteStream, DownloadResolution, PresignedUpload, PutResult, StorageProvider};

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone)]
pub struct S3Config {
    pub endpoint: String,
    pub region: String,
    pub bucket: String,
    pub access_key_id: String,
    pub secret_access_key: String,
    pub prefix: String,
    pub force_path_style: bool,
}

/// Lightweight S3-compatible provider implementing AWS Signature Version 4 Presigned URLs.
/// Compatible with AWS S3, Cloudflare R2, Aliyun OSS, Tencent COS, and MinIO.
pub struct S3Provider {
    http: reqwest::Client,
    cfg: S3Config,
    endpoint_url: Url,
}

impl S3Provider {
    pub fn new(http: reqwest::Client, cfg: S3Config) -> anyhow::Result<Self> {
        let endpoint_url = Url::parse(&cfg.endpoint)?;
        Ok(Self {
            http,
            cfg,
            endpoint_url,
        })
    }

    fn full_object_key(&self, remote_key: &str) -> String {
        let key = remote_key.trim_start_matches('/');
        let prefix = self.cfg.prefix.trim_matches('/');
        if prefix.is_empty() {
            key.to_string()
        } else {
            format!("{prefix}/{key}")
        }
    }

    /// Generates an AWS SigV4 query-string presigned URL for GET / PUT / DELETE / HEAD.
    pub fn presign_url(&self, method: &str, remote_key: &str, expires_secs: u64) -> String {
        let now = Utc::now();
        let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
        let date_stamp = now.format("%Y%m%d").to_string();

        let scheme = self.endpoint_url.scheme();
        let base_host = self.endpoint_url.host_str().unwrap_or("localhost");
        let port_suffix = self
            .endpoint_url
            .port()
            .map(|p| format!(":{p}"))
            .unwrap_or_default();

        let full_key = self.full_object_key(remote_key);
        let encoded_key = encode_s3_path(&full_key);

        let (host, canonical_uri) = if self.cfg.force_path_style {
            let host = format!("{base_host}{port_suffix}");
            let uri = if encoded_key.is_empty() {
                format!("/{}", self.cfg.bucket)
            } else {
                format!("/{}/{}", self.cfg.bucket, encoded_key)
            };
            (host, uri)
        } else {
            let host = format!("{}.{base_host}{port_suffix}", self.cfg.bucket);
            let uri = format!("/{encoded_key}");
            (host, uri)
        };

        let credential_scope = format!("{date_stamp}/{}/s3/aws4_request", self.cfg.region);
        let credential = format!("{}/{credential_scope}", self.cfg.access_key_id);

        let mut query_params = vec![
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256".to_string()),
            ("X-Amz-Credential", credential),
            ("X-Amz-Date", amz_date.clone()),
            ("X-Amz-Expires", expires_secs.to_string()),
            ("X-Amz-SignedHeaders", "host".to_string()),
        ];
        query_params.sort_by(|a, b| a.0.cmp(b.0));

        let canonical_query = query_params
            .iter()
            .map(|(k, v)| format!("{}={}", aws_uri_encode(k), aws_uri_encode(v)))
            .collect::<Vec<_>>()
            .join("&");

        let canonical_headers = format!("host:{host}\n");
        let canonical_request = format!(
            "{method}\n{canonical_uri}\n{canonical_query}\n{canonical_headers}\nhost\nUNSIGNED-PAYLOAD"
        );

        let hashed_request = hex::encode(Sha256::digest(canonical_request.as_bytes()));
        let string_to_sign =
            format!("AWS4-HMAC-SHA256\n{amz_date}\n{credential_scope}\n{hashed_request}");

        let signing_key = derive_signing_key(
            &self.cfg.secret_access_key,
            &date_stamp,
            &self.cfg.region,
            "s3",
        );
        let signature = hex::encode(hmac_sha256(&signing_key, string_to_sign.as_bytes()));

        format!("{scheme}://{host}{canonical_uri}?{canonical_query}&X-Amz-Signature={signature}")
    }
}

#[async_trait]
impl StorageProvider for S3Provider {
    fn presign_upload(&self, remote_key: &str, expires_secs: u64) -> Option<PresignedUpload> {
        let url = self.presign_url("PUT", remote_key, expires_secs);
        Some(PresignedUpload {
            url,
            headers: vec![(
                "Content-Type".to_string(),
                "application/octet-stream".to_string(),
            )],
        })
    }

    async fn put_stream(
        &self,
        remote_key: &str,
        content_length: Option<u64>,
        stream: ByteStream,
    ) -> anyhow::Result<PutResult> {
        let url = self.presign_url("PUT", remote_key, 900);
        let counter = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
        let counter_clone = counter.clone();
        let counting_stream = stream.map_ok(move |chunk| {
            counter_clone.fetch_add(chunk.len() as u64, std::sync::atomic::Ordering::Relaxed);
            chunk
        });

        let mut req = self
            .http
            .put(&url)
            .header("Content-Type", "application/octet-stream");
        if let Some(len) = content_length {
            req = req.header("Content-Length", len.to_string());
        }
        let resp = req
            .body(reqwest::Body::wrap_stream(counting_stream))
            .send()
            .await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            anyhow::bail!("S3 PUT failed ({status}): {text}");
        }
        Ok(PutResult {
            bytes_written: counter.load(std::sync::atomic::Ordering::Relaxed),
            stored_key: remote_key.to_string(),
        })
    }

    async fn resolve_download(&self, remote_key: &str) -> anyhow::Result<DownloadResolution> {
        let url = self.presign_url("GET", remote_key, 3600);
        Ok(DownloadResolution::DirectUrl(url))
    }

    async fn object_exists(&self, remote_key: &str) -> anyhow::Result<bool> {
        let url = self.presign_url("HEAD", remote_key, 120);
        let resp = self.http.head(&url).send().await?;
        Ok(resp.status().is_success())
    }

    async fn delete(&self, remote_key: &str) -> anyhow::Result<()> {
        let url = self.presign_url("DELETE", remote_key, 300);
        let resp = self.http.delete(&url).send().await?;
        if !resp.status().is_success() && resp.status().as_u16() != 404 {
            anyhow::bail!("S3 DELETE failed: {}", resp.status());
        }
        Ok(())
    }

    async fn health_check(&self) -> anyhow::Result<String> {
        let url = self.presign_url("HEAD", "", 120);
        let resp = self.http.head(&url).send().await?;
        if !resp.status().is_success() {
            anyhow::bail!("S3 bucket HEAD failed: {}", resp.status());
        }
        Ok(format!(
            "S3 bucket '{}' reachable at {}",
            self.cfg.bucket, self.cfg.endpoint
        ))
    }
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key size");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

fn derive_signing_key(secret: &str, date_stamp: &str, region: &str, service: &str) -> Vec<u8> {
    let k_date = hmac_sha256(format!("AWS4{secret}").as_bytes(), date_stamp.as_bytes());
    let k_region = hmac_sha256(&k_date, region.as_bytes());
    let k_service = hmac_sha256(&k_region, service.as_bytes());
    hmac_sha256(&k_service, b"aws4_request")
}

fn aws_uri_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char);
            }
            _ => out.push_str(&format!("%{:02X}", byte)),
        }
    }
    out
}

fn encode_s3_path(path: &str) -> String {
    path.trim_start_matches('/')
        .split('/')
        .filter(|s| !s.is_empty())
        .map(aws_uri_encode)
        .collect::<Vec<_>>()
        .join("/")
}
