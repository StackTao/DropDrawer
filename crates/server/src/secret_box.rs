//! Encryption at rest for credentials kept in SQLite.
//!
//! Cloud drive configurations (cookies, OAuth refresh tokens, access keys), persisted
//! runtime settings (SMTP password, OAuth client secret, Turnstile secret) and
//! administrator TOTP secrets are sealed with XChaCha20-Poly1305 before they are
//! written. A copy of the database file — including the admin console's backup
//! download — therefore reveals nothing without the key, which lives outside the
//! database: `DROPDRAWER_SECRET_KEY`, or a `secret_key` file generated next to it.
//!
//! Every value is bound to where it is stored (the associated data names the table
//! and row), so a ciphertext copied into another user's row does not decrypt.

use std::path::Path;

use anyhow::{anyhow, bail, Context};
use base64::Engine as _;
use chacha20poly1305::{
    aead::{Aead, KeyInit, Payload},
    XChaCha20Poly1305, XNonce,
};
use rand::RngCore;

const PREFIX: &str = "enc:v1:";
const NONCE_LEN: usize = 24;
pub const KEY_FILE_NAME: &str = "secret_key";

pub struct SecretBox {
    cipher: XChaCha20Poly1305,
}

impl SecretBox {
    pub fn from_key(key: &[u8; 32]) -> Self {
        Self {
            cipher: XChaCha20Poly1305::new(key.into()),
        }
    }

    /// A throwaway key, for in-memory databases that never outlive the process.
    pub fn ephemeral() -> Self {
        Self::from_key(&random_key())
    }

    pub fn is_sealed(stored: &str) -> bool {
        stored.starts_with(PREFIX)
    }

    pub fn seal(&self, context: &str, plaintext: &str) -> String {
        let mut nonce = [0u8; NONCE_LEN];
        rand::rngs::OsRng.fill_bytes(&mut nonce);
        let ciphertext = self
            .cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: plaintext.as_bytes(),
                    aad: context.as_bytes(),
                },
            )
            .expect("XChaCha20-Poly1305 encryption cannot fail for in-memory buffers");
        let mut out = Vec::with_capacity(NONCE_LEN + ciphertext.len());
        out.extend_from_slice(&nonce);
        out.extend_from_slice(&ciphertext);
        format!(
            "{PREFIX}{}",
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(out)
        )
    }

    /// Decrypts a sealed value. Values written before encryption existed are
    /// returned unchanged so old databases keep working until they are resealed.
    pub fn open(&self, context: &str, stored: &str) -> anyhow::Result<String> {
        let Some(encoded) = stored.strip_prefix(PREFIX) else {
            return Ok(stored.to_string());
        };
        let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(encoded)
            .context("sealed value is not valid base64")?;
        if raw.len() <= NONCE_LEN {
            bail!("sealed value is truncated");
        }
        let (nonce, ciphertext) = raw.split_at(NONCE_LEN);
        let plaintext = self
            .cipher
            .decrypt(
                XNonce::from_slice(nonce),
                Payload {
                    msg: ciphertext,
                    aad: context.as_bytes(),
                },
            )
            .map_err(|_| {
                anyhow!("cannot decrypt a stored secret: the secret key does not match this database")
            })?;
        String::from_utf8(plaintext).context("decrypted secret is not UTF-8")
    }
}

fn random_key() -> [u8; 32] {
    let mut key = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut key);
    key
}

/// Accepts 64 hex characters or 32 bytes of standard / URL-safe base64.
pub fn parse_key(raw: &str) -> anyhow::Result<[u8; 32]> {
    let raw = raw.trim();
    let bytes = if raw.len() == 64 && raw.bytes().all(|b| b.is_ascii_hexdigit()) {
        hex::decode(raw)?
    } else {
        let engines = [
            base64::engine::general_purpose::STANDARD,
            base64::engine::general_purpose::URL_SAFE,
        ];
        let trimmed = raw.trim_end_matches('=');
        engines
            .iter()
            .find_map(|engine| engine.decode(raw).ok())
            .or_else(|| base64::engine::general_purpose::STANDARD_NO_PAD.decode(trimmed).ok())
            .or_else(|| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(trimmed).ok())
            .ok_or_else(|| anyhow!("the secret key must be 64 hex characters or base64"))?
    };
    bytes
        .try_into()
        .map_err(|_| anyhow!("the secret key must be exactly 32 bytes"))
}

/// Reads the key file, or creates it (mode 0600) when `create` is set.
/// Returns `None` when the file is missing and `create` is false.
pub fn load_key_file(path: &Path, create: bool) -> anyhow::Result<Option<[u8; 32]>> {
    match std::fs::read_to_string(path) {
        Ok(contents) => parse_key(&contents)
            .with_context(|| format!("{} does not contain a valid secret key", path.display()))
            .map(Some),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            if !create {
                return Ok(None);
            }
            if let Some(dir) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
                std::fs::create_dir_all(dir)?;
            }
            let key = random_key();
            write_private_file(path, hex::encode(key).as_bytes())
                .with_context(|| format!("cannot write {}", path.display()))?;
            tracing::info!("generated a new secret key at {}", path.display());
            Ok(Some(key))
        }
        Err(err) => Err(err).with_context(|| format!("cannot read {}", path.display())),
    }
}

fn write_private_file(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    options.open(path)?.write_all(contents)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sealed_values_round_trip_and_stay_bound_to_their_row() {
        let secrets = SecretBox::from_key(&[7u8; 32]);
        let sealed = secrets.seal("storage_backends/a", r#"{"cookie":"x"}"#);
        assert!(SecretBox::is_sealed(&sealed));
        assert!(!sealed.contains("cookie"));
        assert_eq!(secrets.open("storage_backends/a", &sealed).unwrap(), r#"{"cookie":"x"}"#);
        assert!(secrets.open("storage_backends/b", &sealed).is_err());
        assert!(SecretBox::from_key(&[8u8; 32]).open("storage_backends/a", &sealed).is_err());
        // Two seals of the same value differ (random nonce).
        assert_ne!(sealed, secrets.seal("storage_backends/a", r#"{"cookie":"x"}"#));
    }

    #[test]
    fn legacy_plaintext_passes_through() {
        let secrets = SecretBox::ephemeral();
        assert_eq!(secrets.open("x", r#"{"kind":"local"}"#).unwrap(), r#"{"kind":"local"}"#);
    }

    #[test]
    fn keys_parse_from_hex_and_base64() {
        let key = [0xabu8; 32];
        assert_eq!(parse_key(&hex::encode(key)).unwrap(), key);
        let b64 = base64::engine::general_purpose::STANDARD.encode(key);
        assert_eq!(parse_key(&b64).unwrap(), key);
        assert_eq!(parse_key(b64.trim_end_matches('=')).unwrap(), key);
        assert!(parse_key("too-short").is_err());
    }
}
