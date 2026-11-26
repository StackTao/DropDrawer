import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Restrained macOS-inspired neutral palette. Desktop is always dark (the macOS
/// window forces a dark vibrancy material); phones follow the system light/dark
/// setting via [MacPalette.use].
///
/// Colors are getters, not constants, so they can switch at runtime. After
/// calling [MacPalette.use], rebuild the whole tree (see `main.dart`).
class MacPalette {
  static _Palette _active = _Palette.dark;

  static Brightness get brightness => _active.brightness;
  static bool get isLight => _active.brightness == Brightness.light;

  /// Selects the light or dark colors. Returns whether anything changed.
  ///
  /// [trueBlack] picks the iOS dark appearance (black background, #1C1C1E
  /// grouped rows) instead of the desktop's dark grey.
  static bool use(Brightness brightness, {bool trueBlack = false}) {
    final next = brightness == Brightness.light
        ? _Palette.light
        : (trueBlack ? _Palette.trueBlack : _Palette.dark);
    if (identical(next, _active)) return false;
    _active = next;
    return true;
  }

  static Color get surfaceTint => _active.surfaceTint;
  static Color get cardBg => _active.cardBg;
  static Color get cardHoverBg => _active.cardHoverBg;
  static Color get elevatedBg => _active.elevatedBg;
  static Color get hairline => _active.hairline;
  static Color get strongHairline => _active.strongHairline;

  static Color get textPrimary => _active.textPrimary;
  static Color get textSecondary => _active.textSecondary;
  static Color get textTertiary => _active.textTertiary;

  static Color get accent => _active.accent;
  static Color get green => _active.green;
  static Color get amber => _active.amber;
  static Color get red => _active.red;

  /// Page background on phones.
  static Color get background => _active.background;

  /// Text on a [textPrimary]-filled (inverted) button.
  static Color get onTextPrimary => _active.onTextPrimary;

  /// Text and icons on an [accent] or [red] fill.
  static Color get onAccent => const Color(0xFFFFFFFF);

  static Color get toastBackground => _active.toastBackground;
  static Color get toastText => _active.toastText;

  /// A neutral plate or highlight: lightens on dark, darkens on light.
  static Color fill(double alpha) => isLight
      ? Colors.black.withValues(alpha: alpha * 0.55)
      : Colors.white.withValues(alpha: alpha);

  /// A grouped panel (settings groups, forms): recessed on dark, a white card
  /// on the light grouped background, like iOS.
  static Color group(double alpha) => isLight || _isTrueBlack
      ? _active.cardBg
      : Colors.black.withValues(alpha: alpha);

  /// A recessed area (input fields, bars): dark on dark, faint grey on light.
  static Color shade(double alpha) => isLight
      ? Colors.black.withValues(alpha: alpha * 0.18)
      : (_isTrueBlack
          // iOS tertiary fill; black would vanish on the black background.
          ? const Color(0xFF767680).withValues(alpha: alpha * 0.85)
          : Colors.black.withValues(alpha: alpha));

  static bool get _isTrueBlack => identical(_active, _Palette.trueBlack);
}

class _Palette {
  final Brightness brightness;
  final Color surfaceTint;
  final Color cardBg;
  final Color cardHoverBg;
  final Color elevatedBg;
  final Color hairline;
  final Color strongHairline;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color accent;
  final Color green;
  final Color amber;
  final Color red;
  final Color background;
  final Color onTextPrimary;
  final Color toastBackground;
  final Color toastText;

  const _Palette({
    required this.brightness,
    required this.surfaceTint,
    required this.cardBg,
    required this.cardHoverBg,
    required this.elevatedBg,
    required this.hairline,
    required this.strongHairline,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.green,
    required this.amber,
    required this.red,
    required this.background,
    required this.onTextPrimary,
    required this.toastBackground,
    required this.toastText,
  });

  static const dark = _Palette(
    brightness: Brightness.dark,
    surfaceTint: Color(0x99161618),
    cardBg: Color(0x12FFFFFF),
    cardHoverBg: Color(0x1EFFFFFF),
    elevatedBg: Color(0xFF1E1E20),
    hairline: Color(0x1CFFFFFF),
    strongHairline: Color(0x30FFFFFF),
    textPrimary: Color(0xFFF5F5F7),
    textSecondary: Color(0x99EBEBF5),
    textTertiary: Color(0x5CEBEBF5),
    accent: Color(0xFF0A84FF),
    green: Color(0xFF30D158),
    amber: Color(0xFFFFD60A),
    red: Color(0xFFFF453A),
    background: Color(0xFF141417),
    onTextPrimary: Color(0xFF111113),
    toastBackground: Color(0xFF2C2C30),
    toastText: Color(0xFFF5F5F7),
  );

  // iOS dark system colors: black background, elevated grouped rows.
  static const trueBlack = _Palette(
    brightness: Brightness.dark,
    surfaceTint: Color(0x99161618),
    cardBg: Color(0xFF1C1C1E),
    cardHoverBg: Color(0xFF2C2C2E),
    elevatedBg: Color(0xFF2C2C2E),
    hairline: Color(0xA6545458),
    strongHairline: Color(0xCC545458),
    textPrimary: Color(0xFFF5F5F7),
    textSecondary: Color(0x99EBEBF5),
    textTertiary: Color(0x5CEBEBF5),
    accent: Color(0xFF0A84FF),
    green: Color(0xFF30D158),
    amber: Color(0xFFFFD60A),
    red: Color(0xFFFF453A),
    background: Color(0xFF000000),
    onTextPrimary: Color(0xFF111113),
    toastBackground: Color(0xFF2C2C2E),
    toastText: Color(0xFFF5F5F7),
  );

  // iOS light system colors (grouped background with white cards).
  static const light = _Palette(
    brightness: Brightness.light,
    surfaceTint: Color(0xF2F2F2F7),
    cardBg: Color(0xFFFFFFFF),
    cardHoverBg: Color(0xFFE9E9EE),
    elevatedBg: Color(0xFFFFFFFF),
    hairline: Color(0x1F000000),
    strongHairline: Color(0x33000000),
    textPrimary: Color(0xFF1C1C1E),
    textSecondary: Color(0x993C3C43),
    textTertiary: Color(0x663C3C43),
    accent: Color(0xFF007AFF),
    green: Color(0xFF34C759),
    amber: Color(0xFFFF9500),
    red: Color(0xFFFF3B30),
    background: Color(0xFFF2F2F7),
    onTextPrimary: Color(0xFFFFFFFF),
    toastBackground: Color(0xFF2C2C30),
    toastText: Color(0xFFF5F5F7),
  );
}

/// App theme. Desktop mimics macOS (no ink splashes, always dark); phones
/// follow [MacPalette]'s brightness, and Android keeps Material ripples.
ThemeData buildAppTheme({required bool mobile, required bool android}) {
  final light = MacPalette.isLight;
  final base = light
      ? ThemeData.light(useMaterial3: true)
      : ThemeData.dark(useMaterial3: true);
  final background = mobile ? MacPalette.background : Colors.transparent;
  final scheme = light
      ? ColorScheme.light(
          primary: MacPalette.accent,
          secondary: MacPalette.accent,
          surface: MacPalette.elevatedBg,
          onSurface: MacPalette.textPrimary,
          error: MacPalette.red,
          outline: MacPalette.strongHairline,
          outlineVariant: MacPalette.hairline,
        )
      : ColorScheme.dark(
          primary: MacPalette.textPrimary,
          secondary: MacPalette.accent,
          surface: MacPalette.elevatedBg,
          error: MacPalette.red,
          // Material 3 draws dividers with outlineVariant, not dividerColor.
          outline: MacPalette.strongHairline,
          outlineVariant: MacPalette.hairline,
        );
  return base.copyWith(
    scaffoldBackgroundColor: background,
    canvasColor: background,
    colorScheme: scheme,
    dividerColor: MacPalette.hairline,
    splashFactory: android ? InkRipple.splashFactory : NoSplash.splashFactory,
    highlightColor: android ? MacPalette.fill(0.08) : Colors.transparent,
    textTheme: base.textTheme.apply(
      bodyColor: MacPalette.textPrimary,
      displayColor: MacPalette.textPrimary,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: MacPalette.elevatedBg,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: MacPalette.elevatedBg,
      surfaceTintColor: Colors.transparent,
    ),
    // Phone navigation bars: iOS tints bar buttons with the system blue (the
    // dark scheme's primary is white); Android app bars tint when content
    // scrolls under them.
    cupertinoOverrideTheme: mobile
        ? CupertinoThemeData(
            primaryColor: MacPalette.accent,
            scaffoldBackgroundColor: MacPalette.background,
            barBackgroundColor: MacPalette.background,
          )
        : null,
    appBarTheme: mobile
        ? AppBarTheme(
            backgroundColor: MacPalette.background,
            foregroundColor: MacPalette.textPrimary,
            surfaceTintColor: MacPalette.accent,
            scrolledUnderElevation: 3,
          )
        : null,
  );
}

bool _isAndroid(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.android;

/// Material switch on Android, Cupertino elsewhere. Compact (scaled down) on
/// the desktop drawer, full size under a touch [UiDensity].
class AdaptiveSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;
  final double compactScale;

  const AdaptiveSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.compactScale = 0.78,
  });

  @override
  Widget build(BuildContext context) {
    final active = activeColor ?? MacPalette.accent;
    if (_isAndroid(context)) {
      return Switch(
        value: value,
        onChanged: onChanged,
        activeTrackColor: active,
      );
    }
    return Transform.scale(
      scale: UiDensity.isTouch(context) ? 1.0 : compactScale,
      child: CupertinoSwitch(
        value: value,
        activeTrackColor: active,
        onChanged: onChanged,
      ),
    );
  }
}

/// Material spinner on Android, Cupertino elsewhere.
class AdaptiveSpinner extends StatelessWidget {
  final double radius;

  const AdaptiveSpinner({super.key, this.radius = 7});

  @override
  Widget build(BuildContext context) {
    if (_isAndroid(context)) {
      return SizedBox.square(
        dimension: radius * 2,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: MacPalette.textSecondary,
        ),
      );
    }
    return CupertinoActivityIndicator(radius: radius);
  }
}

/// Confirmation dialog in the platform's style (Material on Android).
Future<bool> showAdaptiveConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final android = _isAndroid(context);
  Widget action(BuildContext ctx, String label, bool result, {bool danger = false}) {
    if (android) {
      return TextButton(
        onPressed: () => Navigator.of(ctx).pop(result),
        style: danger ? TextButton.styleFrom(foregroundColor: MacPalette.red) : null,
        child: Text(label),
      );
    }
    return CupertinoDialogAction(
      isDestructiveAction: danger,
      onPressed: () => Navigator.of(ctx).pop(result),
      child: Text(label),
    );
  }

  final confirmed = await showAdaptiveDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog.adaptive(
      title: Text(title),
      content: Text(message),
      actions: [
        action(ctx, '取消', false),
        action(ctx, confirmLabel, true, danger: destructive),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Sizing mode for the shared controls below: compact for the desktop drawer,
/// touch for phones (larger hit targets and text, press feedback).
class UiDensity extends InheritedWidget {
  final bool touch;

  const UiDensity({super.key, required this.touch, required super.child});

  static bool isTouch(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiDensity>()?.touch ?? false;

  /// Height of a page header row.
  static double headerHeight(BuildContext context) =>
      isTouch(context) ? 44 : 26;

  @override
  bool updateShouldNotify(UiDensity oldWidget) => oldWidget.touch != touch;
}

/// Compact 26x26 macOS toolbar/action icon button with subtle hover plate.
/// Under a touch [UiDensity] it grows to at least 40x40 and shows a pressed state.
class MacIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  final double boxSize;
  final bool active;

  const MacIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.color,
    this.size = 15,
    this.boxSize = 26,
    this.active = false,
  });

  @override
  State<MacIconButton> createState() => _MacIconButtonState();
}

class _MacIconButtonState extends State<MacIconButton> {
  bool _hovered = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final touch = UiDensity.isTouch(context);
    final boxSize = touch ? (widget.boxSize < 40 ? 40.0 : widget.boxSize) : widget.boxSize;
    final iconSize = touch && widget.size < 17 ? widget.size + 2.5 : widget.size;
    final bg = widget.active
        ? MacPalette.fill(0.16)
        : (_pressed
            ? MacPalette.fill(0.14)
            : (_hovered ? MacPalette.fill(0.10) : Colors.transparent));
    final fg = widget.color ??
        (widget.active
            ? MacPalette.textPrimary
            : (_hovered ? MacPalette.textPrimary : MacPalette.textSecondary));

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: widget.onPressed != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: widget.onPressed == null
              ? null
              : () {
                  if (touch) HapticFeedback.selectionClick();
                  widget.onPressed!();
                },
          onTapDown: touch && widget.onPressed != null ? (_) => _setPressed(true) : null,
          onTapUp: touch ? (_) => _setPressed(false) : null,
          onTapCancel: touch ? () => _setPressed(false) : null,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: Duration(milliseconds: _pressed ? 60 : 120),
            width: boxSize,
            height: boxSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(boxSize > 30 ? 10 : 6),
            ),
            child: Icon(widget.icon, size: iconSize, color: fg),
          ),
        ),
      ),
    );
  }
}

/// Native macOS Control-Center style pill segmented control.
class MacSegmentedControl<T> extends StatelessWidget {
  final List<(T, String)> items;
  final T selected;
  final ValueChanged<T> onChanged;

  const MacSegmentedControl({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final touch = UiDensity.isTouch(context);
    return Container(
      height: touch ? 36 : 26,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: MacPalette.shade(0.28),
        borderRadius: BorderRadius.circular(touch ? 9 : 7),
        border: Border.all(color: MacPalette.hairline, width: 0.5),
      ),
      child: Row(
        children: items.map((entry) {
          final isSelected = entry.$1 == selected;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                if (touch && !isSelected) HapticFeedback.selectionClick();
                onChanged(entry.$1);
              },
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? (MacPalette.isLight
                          ? Colors.white
                          : MacPalette.fill(0.16))
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(touch ? 7 : 5),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: MacPalette.shade(0.2),
                            blurRadius: 2,
                            offset: const Offset(0, 1),
                          )
                        ]
                      : null,
                ),
                child: Text(
                  entry.$2,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: touch ? 13 : 11,
                    fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                    color: isSelected
                        ? MacPalette.textPrimary
                        : MacPalette.textSecondary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Clean macOS System-Settings style grouped text field row.
class MacFormField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? placeholder;
  final bool obscureText;
  final ValueChanged<String>? onSubmitted;

  const MacFormField({
    super.key,
    required this.controller,
    required this.label,
    this.placeholder,
    this.obscureText = false,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final touch = UiDensity.isTouch(context);
    final fieldFont = touch ? 15.0 : 12.5;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: touch ? 12 : 8),
      child: Row(
        children: [
          SizedBox(
            width: touch ? 92 : 68,
            child: Text(
              label,
              style: TextStyle(
                fontSize: touch ? 14 : 12,
                color: MacPalette.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscureText,
              onSubmitted: onSubmitted,
              style: TextStyle(
                fontSize: fieldFont,
                color: MacPalette.textPrimary,
              ),
              cursorColor: MacPalette.textPrimary,
              cursorWidth: 1.5,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                filled: false,
                hintText: placeholder,
                hintStyle: TextStyle(
                  fontSize: fieldFont,
                  color: MacPalette.textTertiary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
