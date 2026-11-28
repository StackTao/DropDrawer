//! Connection-time enforcement of the "block private endpoints" storage policy.
//!
//! `policy::ensure_endpoints_allowed` rejects bad URLs up front, but a hostname
//! can resolve differently a moment later (DNS rebinding) and a public endpoint
//! can redirect to an internal one. The shared HTTP client therefore filters
//! every DNS answer and every redirect target while the policy is on.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use reqwest::dns::{Addrs, Name, Resolve, Resolving};

use crate::policy::is_restricted_ip;

/// Shared switch mirrored from `storage_policy.block_private_endpoints`.
#[derive(Clone, Default)]
pub struct PrivateNetworkGuard(Arc<AtomicBool>);

impl PrivateNetworkGuard {
    pub fn new(enabled: bool) -> Self {
        Self(Arc::new(AtomicBool::new(enabled)))
    }

    pub fn set(&self, enabled: bool) {
        self.0.store(enabled, Ordering::Relaxed);
    }

    pub fn enabled(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }

    /// Checks a URL the server is about to request. Host names are filtered when
    /// they resolve, but IP-literal hosts never reach the resolver, so every
    /// URL that came from a remote API (download links, upload sessions) or
    /// was assembled from configuration must pass through here first.
    pub fn check_url(&self, raw: &str) -> anyhow::Result<()> {
        if !self.enabled() {
            return Ok(());
        }
        let url = reqwest::Url::parse(raw)
            .map_err(|_| anyhow::anyhow!("the storage service returned an invalid URL"))?;
        if !matches!(url.scheme(), "http" | "https") {
            anyhow::bail!("the storage service returned a non-HTTP URL");
        }
        if url_targets_private_literal(&url) {
            anyhow::bail!("a private network address is blocked by the storage policy");
        }
        Ok(())
    }

    /// HTTP client that applies the guard to DNS answers and redirects.
    pub fn build_client(&self) -> reqwest::Client {
        let redirect_guard = self.clone();
        reqwest::Client::builder()
            .pool_idle_timeout(std::time::Duration::from_secs(60))
            // No overall timeout: downloads stream for as long as they move.
            // A stalled cloud API must not hold item / storage locks forever.
            .connect_timeout(std::time::Duration::from_secs(15))
            .read_timeout(std::time::Duration::from_secs(120))
            .dns_resolver(Arc::new(self.clone()))
            .redirect(reqwest::redirect::Policy::custom(move |attempt| {
                if attempt.previous().len() >= 10 {
                    return attempt.error("too many redirects");
                }
                if redirect_guard.enabled() && url_targets_private_literal(attempt.url()) {
                    return attempt.error("redirect to a private network address is blocked");
                }
                attempt.follow()
            }))
            .build()
            .expect("failed to build reqwest client")
    }
}

/// IP-literal and `localhost` hosts never reach the resolver, so redirects check them directly.
fn url_targets_private_literal(url: &reqwest::Url) -> bool {
    match url.host() {
        Some(url::Host::Ipv4(ip)) => is_restricted_ip(ip.into()),
        Some(url::Host::Ipv6(ip)) => is_restricted_ip(ip.into()),
        Some(url::Host::Domain(d)) => d.eq_ignore_ascii_case("localhost") || d.ends_with(".localhost"),
        None => false,
    }
}

impl Resolve for PrivateNetworkGuard {
    fn resolve(&self, name: Name) -> Resolving {
        let block = self.enabled();
        let host = name.as_str().to_owned();
        Box::pin(async move {
            let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), 0))
                .await?
                .filter(|addr| !(block && is_restricted_ip(addr.ip())))
                .collect();
            if addrs.is_empty() {
                let reason = if block {
                    format!("{host} resolves only to private network addresses, which the storage policy blocks")
                } else {
                    format!("{host} did not resolve to any address")
                };
                return Err(reason.into());
            }
            Ok(Box::new(addrs.into_iter()) as Addrs)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn guard_filters_private_answers_only_when_enabled() {
        let guard = PrivateNetworkGuard::new(false);
        let open = guard.resolve("localhost".parse().unwrap()).await;
        assert!(open.is_ok(), "loopback resolves while the guard is off");
        guard.set(true);
        let blocked = guard.resolve("localhost".parse().unwrap()).await;
        assert!(blocked.is_err(), "loopback answers are dropped while the guard is on");
    }

    #[test]
    fn redirects_to_private_literals_are_detected() {
        for url in ["http://127.0.0.1/x", "http://[::1]/", "http://10.0.0.8:9000/", "http://localhost/"] {
            assert!(url_targets_private_literal(&url.parse().unwrap()), "{url}");
        }
        assert!(!url_targets_private_literal(&"https://example.com/".parse().unwrap()));
    }

    #[test]
    fn check_url_blocks_private_literals_only_when_enabled() {
        let guard = PrivateNetworkGuard::new(false);
        assert!(guard.check_url("http://169.254.169.254/latest/meta-data/").is_ok());
        guard.set(true);
        for url in [
            "http://169.254.169.254/latest/meta-data/",
            "http://127.0.0.1:8080/x",
            "http://[::ffff:10.0.0.1]/",
            // Authority injected through a bucket name ends up as the host.
            "http://169.254.169.254/latest/meta-data/?.s3.example.com/key",
            "file:///etc/passwd",
        ] {
            assert!(guard.check_url(url).is_err(), "{url}");
        }
        assert!(guard.check_url("https://example.com/file").is_ok());
    }
}
