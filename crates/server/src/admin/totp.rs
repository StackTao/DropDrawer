//! RFC 6238 TOTP (HMAC-SHA1, 6 digits, 30 s) for administrator two-step verification.

use hmac::{Hmac, Mac};
use rand::RngCore;
use sha1::Sha1;

const STEP_SECS: i64 = 30;
const DIGITS: u32 = 6;
/// Accept the previous and next step to tolerate clock drift.
const SKEW_STEPS: i64 = 1;
const BASE32: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

pub fn generate_secret() -> String {
    let mut bytes = [0u8; 20];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    base32_encode(&bytes)
}

pub fn base32_encode(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(5) * 8);
    let (mut buffer, mut bits) = (0u32, 0u32);
    for &byte in data {
        buffer = (buffer << 8) | byte as u32;
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out.push(BASE32[((buffer >> bits) & 31) as usize] as char);
        }
    }
    if bits > 0 {
        out.push(BASE32[((buffer << (5 - bits)) & 31) as usize] as char);
    }
    out
}

pub fn base32_decode(input: &str) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let (mut buffer, mut bits) = (0u32, 0u32);
    for c in input.chars().filter(|c| !c.is_whitespace() && *c != '=') {
        let v = BASE32.iter().position(|&b| b as char == c.to_ascii_uppercase())? as u32;
        buffer = (buffer << 5) | v;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
        }
    }
    Some(out)
}

fn hotp(key: &[u8], counter: u64) -> u32 {
    let mut mac = Hmac::<Sha1>::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(&counter.to_be_bytes());
    let digest = mac.finalize().into_bytes();
    let offset = (digest[19] & 0x0f) as usize;
    let code = u32::from_be_bytes([
        digest[offset] & 0x7f,
        digest[offset + 1],
        digest[offset + 2],
        digest[offset + 3],
    ]);
    code % 10u32.pow(DIGITS)
}

pub fn current_step(unix_secs: i64) -> i64 {
    unix_secs.div_euclid(STEP_SECS)
}

pub fn code_at(secret: &str, step: i64) -> Option<String> {
    let key = base32_decode(secret)?;
    Some(format!("{:0width$}", hotp(&key, step as u64), width = DIGITS as usize))
}

/// Matching time step for `code`, if it is valid around `unix_secs`.
pub fn verify(secret: &str, code: &str, unix_secs: i64) -> Option<i64> {
    let code: String = code.chars().filter(|c| !c.is_whitespace()).collect();
    if code.len() != DIGITS as usize || !code.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let key = base32_decode(secret)?;
    let now = current_step(unix_secs);
    (-SKEW_STEPS..=SKEW_STEPS)
        .map(|d| now + d)
        .find(|&step| {
            let expected = format!("{:0width$}", hotp(&key, step as u64), width = DIGITS as usize);
            // Constant-time comparison of equal-length digit strings.
            expected
                .bytes()
                .zip(code.bytes())
                .fold(0u8, |acc, (a, b)| acc | (a ^ b))
                == 0
        })
}

/// `otpauth://` URI understood by authenticator apps.
pub fn otpauth_uri(issuer: &str, account: &str, secret: &str) -> String {
    format!(
        "otpauth://totp/{}:{}?secret={secret}&issuer={}&algorithm=SHA1&digits={DIGITS}&period={STEP_SECS}",
        urlencoding::encode(issuer),
        urlencoding::encode(account),
        urlencoding::encode(issuer),
    )
}

/// QR code for `data` as a data-URI SVG (rendered via `<img>`, allowed by the CSP).
pub fn qr_svg_data_uri(data: &str) -> Option<String> {
    use base64::Engine;
    let code = qrcode::QrCode::new(data.as_bytes()).ok()?;
    let svg = code
        .render::<qrcode::render::svg::Color>()
        .min_dimensions(200, 200)
        .quiet_zone(true)
        .dark_color(qrcode::render::svg::Color("#000000"))
        .light_color(qrcode::render::svg::Color("#ffffff"))
        .build();
    Some(format!(
        "data:image/svg+xml;base64,{}",
        base64::engine::general_purpose::STANDARD.encode(svg)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_rfc6238_sha1_vectors() {
        // RFC 6238 appendix B, secret "12345678901234567890" (8-digit codes truncated to 6).
        let secret = base32_encode(b"12345678901234567890");
        assert_eq!(code_at(&secret, current_step(59)).unwrap(), "287082");
        assert_eq!(code_at(&secret, current_step(1111111109)).unwrap(), "081804");
        assert_eq!(code_at(&secret, current_step(1234567890)).unwrap(), "005924");
    }

    #[test]
    fn verify_accepts_adjacent_steps_only() {
        let secret = generate_secret();
        let now = 1_700_000_000;
        let code = code_at(&secret, current_step(now) - 1).unwrap();
        assert_eq!(verify(&secret, &code, now), Some(current_step(now) - 1));
        assert_eq!(verify(&secret, &code, now + 120), None);
        assert_eq!(verify(&secret, "12a456", now), None);
    }

    #[test]
    fn base32_round_trips() {
        for len in 0..24 {
            let data: Vec<u8> = (0..len as u8).map(|b| b.wrapping_mul(37)).collect();
            assert_eq!(base32_decode(&base32_encode(&data)).unwrap(), data);
        }
        assert!(qr_svg_data_uri("otpauth://totp/x").unwrap().starts_with("data:image/svg+xml"));
    }
}
