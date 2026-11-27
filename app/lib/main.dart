import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n/l10n.dart';
import 'state/drawer_controller.dart';
import 'ui/drawer_screen.dart';
import 'ui/login_screen.dart';
import 'ui/theme.dart';

bool get _isMobile => Platform.isIOS || Platform.isAndroid;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_isMobile) {
    // Phones follow the system appearance; the desktop drawer is always dark.
    MacPalette.use(
      ui.PlatformDispatcher.instance.platformBrightness,
      trueBlack: Platform.isIOS,
      material: Platform.isAndroid,
    );
    _applySystemBars();
  }
  SharedPreferences? initialPrefs;
  try {
    initialPrefs = await SharedPreferences.getInstance();
  } catch (_) {}
  await initializeDateFormatting();
  AppLocale.apply(AppLanguage.fromId(initialPrefs?.getString(AppLocale.prefsKey)));
  runApp(DropDrawerApp(initialPrefs: initialPrefs));
}

void _applySystemBars() {
  final light = MacPalette.isLight;
  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle(
      // iOS: statusBarBrightness is the *background* brightness.
      statusBarBrightness: light ? Brightness.light : Brightness.dark,
      statusBarIconBrightness: light ? Brightness.dark : Brightness.light,
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: MacPalette.background,
      systemNavigationBarIconBrightness:
          light ? Brightness.dark : Brightness.light,
    ),
  );
}

class DropDrawerApp extends StatefulWidget {
  final SharedPreferences? initialPrefs;

  const DropDrawerApp({super.key, this.initialPrefs});

  @override
  State<DropDrawerApp> createState() => _DropDrawerAppState();
}

class _DropDrawerAppState extends State<DropDrawerApp>
    with WidgetsBindingObserver {
  late final DropDrawerController _controller = DropDrawerController(
    initialPrefs: widget.initialPrefs,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppLocale.changes.addListener(_onLocaleChanged);
    _controller.windowService.setNativeStrings(AppLocale.nativeStrings());
    _controller.bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppLocale.changes.removeListener(_onLocaleChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    if (!_isMobile) return;
    if (!MacPalette.use(
      ui.PlatformDispatcher.instance.platformBrightness,
      trueBlack: Platform.isIOS,
      material: Platform.isAndroid,
    )) {
      return;
    }
    _applySystemBars();
    _rebuildAll();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    // Only matters while the language follows the system.
    AppLocale.apply(AppLocale.preference, locales);
  }

  void _onLocaleChanged() {
    _controller.windowService.setNativeStrings(AppLocale.nativeStrings());
    _rebuildAll();
  }

  void _rebuildAll() {
    if (!mounted) return;
    setState(() {});
    // Palette colors and strings are read during build, and widgets built
    // with `const` constructors are not rebuilt by a parent rebuild, so mark
    // every element.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      void markAll(Element element) {
        element.markNeedsBuild();
        element.visitChildren(markAll);
      }

      if (mounted) (context as Element).visitChildren(markAll);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DropDrawer',
      debugShowCheckedModeBanner: false,
      locale: AppLocale.locale,
      supportedLocales: AppLocale.supported,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildAppTheme(
        mobile: _isMobile,
        android: Platform.isAndroid,
      ),
      home: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          if (!_controller.isLoggedIn) {
            return LoginScreen(controller: _controller);
          }
          return DrawerScreen(controller: _controller);
        },
      ),
    );
  }
}
