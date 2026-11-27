import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropdrawer_app/l10n/l10n.dart';
import 'package:dropdrawer_app/ui/drawer_screen.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _arb(String name) =>
    jsonDecode(File('lib/l10n/$name').readAsStringSync()) as Map<String, dynamic>;

Set<String> _placeholders(String message) =>
    RegExp(r'\{(\w+)[,}]').allMatches(message).map((m) => m.group(1)!).toSet()
      ..removeAll(const {'other', 'one'});

void main() {
  tearDown(() => AppLocale.apply(AppLanguage.chinese));

  test('every Chinese string has an English translation with the same placeholders', () {
    final zh = _arb('app_zh.arb');
    final en = _arb('app_en.arb');
    final keys = zh.keys.where((k) => !k.startsWith('@')).toSet();
    expect(en.keys.where((k) => !k.startsWith('@')).toSet(), keys);
    final cjk = RegExp(r'[㐀-鿿]');
    for (final key in keys) {
      final zhText = zh[key] as String;
      final enText = en[key] as String;
      expect(cjk.hasMatch(enText), isFalse, reason: '$key is not translated');
      expect(_placeholders(enText), _placeholders(zhText), reason: key);
    }
  });

  test('system language resolution falls back to English', () {
    const zh = ui.Locale('zh', 'CN');
    const hant = ui.Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
    expect(AppLocale.resolve(AppLanguage.system, [zh]), const ui.Locale('zh'));
    expect(AppLocale.resolve(AppLanguage.system, [hant]), const ui.Locale('zh'));
    expect(AppLocale.resolve(AppLanguage.system, [const ui.Locale('fr')]), const ui.Locale('en'));
    expect(
      AppLocale.resolve(AppLanguage.system, [const ui.Locale('ja'), zh]),
      const ui.Locale('zh'),
    );
    expect(AppLocale.resolve(AppLanguage.english, [zh]), const ui.Locale('en'));
    expect(AppLocale.resolve(AppLanguage.chinese, [const ui.Locale('en')]), const ui.Locale('zh'));
  });

  test('switching the language changes strings, plurals, dates and the request tag', () {
    var notified = 0;
    void listener() => notified++;
    AppLocale.changes.addListener(listener);
    addTearDown(() => AppLocale.changes.removeListener(listener));

    expect(AppLocale.apply(AppLanguage.english), isTrue);
    expect(notified, 1);
    expect(AppLocale.tag, 'en');
    expect(l10n.cancel, 'Cancel');
    expect(l10n.itemsCount(1), '1 item');
    expect(l10n.itemsCount(3), '3 items');
    final now = DateTime(2026, 11, 27, 12);
    expect(relativeTimeLabel(DateTime(2026, 3, 2, 9), now: now), 'Mar 2');
    expect(relativeTimeLabel(DateTime(2025, 3, 2, 9), now: now), 'Mar 2, 2025');
    expect(relativeTimeLabel(now.subtract(const Duration(minutes: 1)), now: now), '1 minute ago');
    expect(AppLocale.nativeStrings()['quitActiveTitle'], 'Transfers still in progress: {count}');

    expect(AppLocale.apply(AppLanguage.english), isFalse, reason: 'unchanged');
    expect(AppLocale.apply(AppLanguage.chinese), isTrue);
    expect(AppLocale.tag, 'zh-CN');
    expect(l10n.cancel, '取消');
    expect(l10n.itemsCount(3), '3 项');
    expect(relativeTimeLabel(DateTime(2026, 3, 2, 9), now: now), '3月2日');
    expect(relativeTimeLabel(DateTime(2025, 3, 2, 9), now: now), '2025年3月2日');
    expect(AppLocale.nativeStrings()['quitActiveTitle'], '还有 {count} 项传输正在进行');
  });
}
