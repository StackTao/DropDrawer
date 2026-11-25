import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'state/drawer_controller.dart';
import 'ui/drawer_screen.dart';
import 'ui/login_screen.dart';
import 'ui/theme.dart';

bool get _isMobile => Platform.isIOS || Platform.isAndroid;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (_isMobile) {
    // Phones follow the system appearance; the desktop drawer is always dark.
    MacPalette.use(ui.PlatformDispatcher.instance.platformBrightness);
    _applySystemBars();
  }
  runApp(const DropDrawerApp());
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
  const DropDrawerApp({super.key});

  @override
  State<DropDrawerApp> createState() => _DropDrawerAppState();
}

class _DropDrawerAppState extends State<DropDrawerApp>
    with WidgetsBindingObserver {
  final DropDrawerController _controller = DropDrawerController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    if (!_isMobile) return;
    if (!MacPalette.use(ui.PlatformDispatcher.instance.platformBrightness)) {
      return;
    }
    _applySystemBars();
    setState(() {});
    // Palette colors are read during build, and widgets built with `const`
    // constructors are not rebuilt by a parent rebuild, so mark every element.
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
