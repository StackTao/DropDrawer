import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// The language the user picked in Preferences.
enum AppLanguage {
  system('system'),
  chinese('zh'),
  english('en');

  const AppLanguage(this.id);

  /// Value stored in preferences.
  final String id;

  static AppLanguage fromId(String? id) =>
      values.firstWhere((l) => l.id == id, orElse: () => AppLanguage.system);
}

/// Current UI language.
///
/// Like `MacPalette`, the strings are read through a runtime getter ([l10n])
/// so controllers and helpers can produce messages without a `BuildContext`.
/// `main.dart` rebuilds the whole tree when [apply] changes the locale.
abstract final class AppLocale {
  static const prefsKey = 'app_language';
  static const supported = [Locale('zh'), Locale('en')];

  static AppLanguage _preference = AppLanguage.system;
  static Locale _locale = resolve(AppLanguage.system);
  static AppLocalizations _strings = lookupAppLocalizations(_locale);

  /// Notifies when the effective locale changes.
  static final ValueNotifier<Locale> changes = ValueNotifier(_locale);

  static AppLanguage get preference => _preference;
  static Locale get locale => _locale;
  static bool get isChinese => _locale.languageCode == 'zh';

  /// BCP 47 tag for `Accept-Language` and `intl` formatting.
  static String get tag => isChinese ? 'zh-CN' : 'en';

  /// Picks the first supported language from the system preference list.
  /// Languages without a translation fall back to English.
  static Locale resolve(AppLanguage preference, [List<ui.Locale>? system]) {
    switch (preference) {
      case AppLanguage.chinese:
        return const Locale('zh');
      case AppLanguage.english:
        return const Locale('en');
      case AppLanguage.system:
        final locales = system ?? ui.PlatformDispatcher.instance.locales;
        for (final l in locales) {
          if (l.languageCode == 'zh') return const Locale('zh');
          if (l.languageCode == 'en') return const Locale('en');
        }
        return const Locale('en');
    }
  }

  /// Applies [preference] (and the current system languages). Returns whether
  /// the effective locale changed.
  static bool apply(AppLanguage preference, [List<ui.Locale>? system]) {
    _preference = preference;
    final next = resolve(preference, system);
    final changed = next != _locale;
    if (changed) {
      _locale = next;
      _strings = lookupAppLocalizations(next);
    }
    Intl.defaultLocale = tag;
    if (changed) changes.value = next;
    return changed;
  }

  /// Strings the macOS / Windows runners show in menus, panels and alerts.
  static Map<String, String> nativeStrings() => {
        'trayToggle': l10n.nativeTrayToggle,
        'trayRegularWindow': l10n.nativeRegularWindow,
        'trayEdgeDrawer': l10n.nativeEdgeDrawer,
        'dockLeft': l10n.dockLeft,
        'dockRight': l10n.dockRight,
        'quit': l10n.quit,
        'quitActiveTitle': l10n.nativeQuitActiveTitle('{count}'),
        'quitActiveMessage': l10n.nativeQuitActiveMessage,
        'quitKeepRunning': l10n.keepRunningInBackground,
        'quitAnyway': l10n.quitAnyway,
        'menuShares': l10n.shareLinksTitle,
        'menuPreferences': l10n.preferences,
        'menuDevices': l10n.deviceStatus,
        'menuLogout': l10n.signOut,
        'pickFilesTitle': l10n.nativePickFilesTitle,
        'pickFilesPrompt': l10n.nativePickFilesPrompt,
        'pickFolderTitle': l10n.nativePickFolderTitle,
        'pickFolderPrompt': l10n.nativePickFolderPrompt,
      };

  /// Short date such as "Mar 5" / "3月5日", with the year when it differs.
  static String shortDate(DateTime local, {DateTime? now}) {
    final current = now ?? DateTime.now();
    return local.year == current.year
        ? DateFormat.MMMd(tag).format(local)
        : DateFormat.yMMMd(tag).format(local);
  }

  /// Date and time such as "Mar 5, 2026 2:03 PM" / "2026年3月5日 14:03".
  static String dateTime(DateTime local) {
    final date = DateFormat.yMMMd(tag);
    return (isChinese ? date.add_Hm() : date.add_jm()).format(local);
  }

  /// Time of day such as "2:03 PM" / "14:03" (Chinese uses the 24-hour clock).
  static String time(DateTime local) =>
      (isChinese ? DateFormat.Hm(tag) : DateFormat.jm(tag)).format(local);
}

/// Strings for the current UI language.
AppLocalizations get l10n => AppLocale._strings;
