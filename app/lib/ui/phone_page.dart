import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// Whether phone chrome follows Material 3 (Android) rather than iOS.
bool usesMaterialChrome(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.android;

/// Maps the compact desktop font sizes used throughout the shared pages onto
/// the phone type ramp, then applies the system text size.
///
/// iOS: footnote 13, callout 16, body 17. Android (Material 3): body small 12,
/// body large 16. Sizes above the body size grow slightly.
class PhoneTypeScaler extends TextScaler {
  const PhoneTypeScaler(this.system, {required this.material});

  final TextScaler system;
  final bool material;

  double ramp(double size) {
    final shift = material ? 1.0 : 0.0;
    if (size < 10) return 11 - shift;
    if (size < 11.75) return 13 - shift; // descriptions, section labels
    if (size < 12.75) return 16 - shift; // row titles, field text
    if (size < 13.5) return 17 - shift; // emphasized rows, button labels
    final grown = size * (material ? 1.05 : 1.1);
    return grown < 17 - shift ? 17 - shift : grown;
  }

  @override
  double scale(double fontSize) => system.scale(ramp(fontSize));

  @override
  @Deprecated('Use scale instead.')
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is PhoneTypeScaler &&
      other.system == system &&
      other.material == material;

  @override
  int get hashCode => Object.hash(system, material);
}

/// Applies [PhoneTypeScaler] to [child], keeping the system text size.
class PhoneTypeScale extends StatelessWidget {
  const PhoneTypeScale({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    var system = media.textScaler;
    // Never stack two ramps.
    while (system is PhoneTypeScaler) {
      system = system.system;
    }
    return MediaQuery(
      data: media.copyWith(
        textScaler: PhoneTypeScaler(
          system,
          material: usesMaterialChrome(context),
        ),
      ),
      child: child,
    );
  }
}

/// A button in a phone navigation bar or app bar.
class PageAction {
  const PageAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.destructive = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool destructive;
}

/// Navigation bar button: a tinted icon on iOS, an [IconButton] on Android.
class PhoneBarButton extends StatelessWidget {
  const PhoneBarButton({super.key, required this.action});

  final PageAction action;

  @override
  Widget build(BuildContext context) {
    final color = action.destructive ? MacPalette.red : null;
    if (usesMaterialChrome(context)) {
      return IconButton(
        tooltip: action.tooltip,
        onPressed: action.onPressed,
        color: color,
        icon: Icon(action.icon, size: 22),
      );
    }
    return Semantics(
      button: true,
      label: action.tooltip,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size(44, 44),
        onPressed: action.onPressed,
        child: Icon(
          action.icon,
          size: 23,
          color: color ??
              (action.onPressed == null
                  ? MacPalette.textTertiary
                  : MacPalette.accent),
        ),
      ),
    );
  }
}

/// A secondary page on a phone: an iOS navigation bar (centered title, back
/// button named after the previous page) or a Material 3 top app bar, above
/// [body] set in the phone type ramp.
///
/// The page is expected to be a pushed route; the back button pops it.
class PhonePage extends StatelessWidget {
  const PhonePage({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.previousTitle = '抽屉',
  });

  final String title;
  final Widget body;
  final List<PageAction> actions;
  final String previousTitle;

  @override
  Widget build(BuildContext context) {
    final PreferredSizeWidget bar;
    if (usesMaterialChrome(context)) {
      bar = AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          for (final action in actions) PhoneBarButton(action: action),
          const SizedBox(width: 4),
        ],
      );
    } else {
      bar = CupertinoNavigationBar(
        previousPageTitle: previousTitle,
        backgroundColor: MacPalette.background,
        border: Border(
          bottom: BorderSide(color: MacPalette.hairline, width: 0.5),
        ),
        middle: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: actions.isEmpty
            ? null
            : Material(
                type: MaterialType.transparency,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final action in actions) PhoneBarButton(action: action),
                  ],
                ),
              ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bar,
        Expanded(
          child: SafeArea(
            top: false,
            child: PhoneTypeScale(child: body),
          ),
        ),
      ],
    );
  }
}

/// A secondary page shared by the desktop drawer and phones. The desktop keeps
/// its compact header row; phones get a [PhonePage].
class AdaptivePage extends StatelessWidget {
  const AdaptivePage({
    super.key,
    required this.title,
    required this.desktopHeader,
    required this.body,
    this.actions = const [],
  });

  final String title;
  final Widget desktopHeader;
  final Widget body;
  final List<PageAction> actions;

  @override
  Widget build(BuildContext context) {
    if (UiDensity.isTouch(context)) {
      return PhonePage(title: title, actions: actions, body: body);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        desktopHeader,
        const Divider(height: 0.5, thickness: 0.5),
        Expanded(child: body),
      ],
    );
  }
}
