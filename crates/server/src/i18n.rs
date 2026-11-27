//! Per-request response language.
//!
//! Clients send `Accept-Language`; [`scope_language`] keeps the chosen
//! [`Lang`] in a task-local for the rest of the request, so handlers and the
//! policy helpers they call pick their message with [`t!`] / [`tf!`] without
//! passing the language around. Requests without the header (older clients)
//! get Chinese, which is what those clients always showed.

use axum::{
    extract::Request,
    http::header::ACCEPT_LANGUAGE,
    middleware::Next,
    response::Response,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lang {
    Zh,
    En,
}

impl Lang {
    /// Language for an `Accept-Language` value. Missing or empty headers keep
    /// the historical Chinese responses; any other language falls back to
    /// English.
    pub fn from_accept_language(value: Option<&str>) -> Self {
        let Some(value) = value.map(str::trim).filter(|v| !v.is_empty()) else {
            return Self::Zh;
        };
        let mut best: Option<(f32, Self)> = None;
        for part in value.split(',') {
            let mut fields = part.split(';');
            let tag = fields.next().unwrap_or_default().trim().to_ascii_lowercase();
            let quality = fields
                .find_map(|f| f.trim().strip_prefix("q="))
                .and_then(|q| q.trim().parse::<f32>().ok())
                .unwrap_or(1.0);
            if quality <= 0.0 {
                continue;
            }
            let lang = match tag.split('-').next() {
                Some("zh") => Self::Zh,
                Some("en") => Self::En,
                _ => continue,
            };
            if best.is_none_or(|(q, _)| quality > q) {
                best = Some((quality, lang));
            }
        }
        best.map_or(Self::En, |(_, lang)| lang)
    }

    /// `lang` attribute value for HTML pages.
    pub fn html_tag(self) -> &'static str {
        match self {
            Self::Zh => "zh-CN",
            Self::En => "en",
        }
    }
}

tokio::task_local! {
    static LANG: Lang;
}

/// The current request's language (Chinese outside a request).
pub fn current() -> Lang {
    LANG.try_with(|lang| *lang).unwrap_or(Lang::Zh)
}

pub fn is_en() -> bool {
    current() == Lang::En
}

/// Runs `future` with `lang` as the current language, e.g. for work spawned
/// from a request.
pub async fn scope<F: std::future::Future>(lang: Lang, future: F) -> F::Output {
    LANG.scope(lang, future).await
}

/// Middleware that sets the language for the request from `Accept-Language`.
pub async fn scope_language(request: Request, next: Next) -> Response {
    let lang = Lang::from_accept_language(
        request
            .headers()
            .get(ACCEPT_LANGUAGE)
            .and_then(|v| v.to_str().ok()),
    );
    LANG.scope(lang, next.run(request)).await
}

/// Picks the Chinese or English literal for the current request.
#[macro_export]
macro_rules! t {
    ($zh:literal, $en:literal $(,)?) => {
        if $crate::i18n::is_en() { $en } else { $zh }
    };
}

/// `format!` with a Chinese and an English format string.
#[macro_export]
macro_rules! tf {
    ($zh:literal, $en:literal $(,)?) => {
        if $crate::i18n::is_en() { format!($en) } else { format!($zh) }
    };
    ($zh:literal, $en:literal, $($arg:tt)+) => {
        if $crate::i18n::is_en() { format!($en, $($arg)+) } else { format!($zh, $($arg)+) }
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accept_language_picks_the_preferred_supported_language() {
        assert_eq!(Lang::from_accept_language(None), Lang::Zh);
        assert_eq!(Lang::from_accept_language(Some("")), Lang::Zh);
        assert_eq!(Lang::from_accept_language(Some("en")), Lang::En);
        assert_eq!(Lang::from_accept_language(Some("zh-CN")), Lang::Zh);
        assert_eq!(Lang::from_accept_language(Some("zh-Hant-TW,en;q=0.8")), Lang::Zh);
        assert_eq!(Lang::from_accept_language(Some("en-US,en;q=0.9,zh;q=0.8")), Lang::En);
        assert_eq!(Lang::from_accept_language(Some("ja,zh;q=0.7,en;q=0.5")), Lang::Zh);
        assert_eq!(Lang::from_accept_language(Some("fr-FR,fr;q=0.9")), Lang::En);
        assert_eq!(Lang::from_accept_language(Some("zh;q=0,en;q=0.1")), Lang::En);
    }

    #[tokio::test]
    async fn macros_follow_the_scoped_language() {
        assert_eq!(t!("中文", "English"), "中文");
        let n = 3;
        assert_eq!(scope(Lang::En, async { tf!("{n} 项", "{n} items") }).await, "3 items");
        assert_eq!(scope(Lang::Zh, async { tf!("{} 项", "{} items", n) }).await, "3 项");
    }
}
