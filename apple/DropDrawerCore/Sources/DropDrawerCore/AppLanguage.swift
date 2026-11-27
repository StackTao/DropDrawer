import Foundation

/// The language the app is shown in.
///
/// iOS picks it from the system language list or the per-app language in
/// Settings, limited to the localizations the app ships (Chinese and English).
public enum AppLanguage {
    /// The localization in use, such as "zh-Hans" or "en".
    public static var current: String {
        Bundle.main.preferredLocalizations.first ?? "zh-Hans"
    }

    public static var isChinese: Bool { current.hasPrefix("zh") }

    /// `Accept-Language` for server requests, so server messages match the UI.
    public static var acceptLanguage: String { isChinese ? "zh-CN" : "en" }

    /// Locale for dates and numbers in the UI language.
    public static var locale: Locale { Locale(identifier: isChinese ? "zh-Hans" : "en") }
}
