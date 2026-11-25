import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'state/drawer_controller.dart';
import 'ui/drawer_screen.dart';
import 'ui/login_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isIOS || Platform.isAndroid) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarBrightness: Brightness.dark,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFF141417),
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }
  runApp(const DropDrawerApp());
}

class DropDrawerApp extends StatefulWidget {
  const DropDrawerApp({super.key});

  @override
  State<DropDrawerApp> createState() => _DropDrawerAppState();
}

class _DropDrawerAppState extends State<DropDrawerApp> {
  final DropDrawerController _controller = DropDrawerController();

  @override
  void initState() {
    super.initState();
    _controller.bootstrap();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = Platform.isIOS || Platform.isAndroid;
    return MaterialApp(
      title: 'DropDrawer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor:
            isMobile ? const Color(0xFF141417) : Colors.transparent,
        canvasColor: isMobile ? const Color(0xFF141417) : Colors.transparent,
        colorScheme: const ColorScheme.dark(
          primary: MacPalette.textPrimary,
          secondary: MacPalette.accent,
          surface: MacPalette.elevatedBg,
        ),
        dividerColor: MacPalette.hairline,
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        textTheme: ThemeData.dark().textTheme.apply(
              bodyColor: MacPalette.textPrimary,
              displayColor: MacPalette.textPrimary,
            ),
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
