import 'dart:async';
import 'dart:io';

import 'package:dropdrawer_app/l10n/l10n.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Existing tests assert the Chinese strings, so the suite runs in Chinese
/// unless a test switches the language itself (see l10n_test.dart).
/// `DROPDRAWER_TEST_LANGUAGE=en` runs everything in English to look for
/// layout overflows (text assertions are then expected to fail).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await initializeDateFormatting();
  AppLocale.apply(
    Platform.environment['DROPDRAWER_TEST_LANGUAGE'] == 'en'
        ? AppLanguage.english
        : AppLanguage.chinese,
  );
  await testMain();
}
