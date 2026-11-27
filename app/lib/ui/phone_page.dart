import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';
import '../l10n/l10n.dart';

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

/// Undoes [PhoneTypeScale] for widgets already sized in phone points, such as
/// the phone sections and buttons below, keeping the system text size.
class NativeTypeScale extends StatelessWidget {
  const NativeTypeScale({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    var system = media.textScaler;
    if (system is! PhoneTypeScaler) return child;
    while (system is PhoneTypeScaler) {
      system = system.system;
    }
    return MediaQuery(data: media.copyWith(textScaler: system), child: child);
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

/// iOS 26 Liquid Glass translucent floating surface: backdrop blur, top-lit
/// glass gradient, specular rim highlight, and soft ambient elevation shadow.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.borderRadius,
    required this.child,
    this.blur = 28,
    this.shadow = true,
    this.tinted = false,
  });

  final BorderRadius borderRadius;
  final Widget child;
  final double blur;
  final bool shadow;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final light = MacPalette.isLight;
    final topColor = tinted
        ? MacPalette.accent.withValues(alpha: light ? 0.14 : 0.26)
        : MacPalette.elevatedBg.withValues(alpha: light ? 0.92 : 0.80);
    final bottomColor = tinted
        ? MacPalette.accent.withValues(alpha: light ? 0.09 : 0.18)
        : MacPalette.cardBg.withValues(alpha: light ? 0.82 : 0.68);
    final outerBorder = light
        ? MacPalette.fill(0.11)
        : MacPalette.onAccent.withValues(alpha: 0.18);
    final innerRim = light
        ? MacPalette.onAccent.withValues(alpha: 0.96)
        : MacPalette.onAccent.withValues(alpha: 0.10);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: light
                      ? MacPalette.fill(0.13)
                      : MacPalette.shade(0.65),
                  blurRadius: light ? 18 : 26,
                  offset: Offset(0, light ? 4 : 8),
                ),
                BoxShadow(
                  color: light
                      ? MacPalette.fill(0.06)
                      : MacPalette.shade(0.32),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [topColor, bottomColor],
              ),
              border: Border.all(color: outerBorder, width: 0.5),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                border: Border.all(color: innerRim, width: light ? 0.9 : 0.5),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Interactive circular or capsule iOS 26 Liquid Glass button with springy
/// press feedback.
class LiquidGlassButton extends StatefulWidget {
  const LiquidGlassButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.width,
    this.height = 38,
    this.padding = EdgeInsets.zero,
    this.borderRadius,
    this.tinted = false,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final double? width;
  final double height;
  final EdgeInsetsGeometry padding;
  final BorderRadius? borderRadius;
  final bool tinted;

  @override
  State<LiquidGlassButton> createState() => _LiquidGlassButtonState();
}

class _LiquidGlassButtonState extends State<LiquidGlassButton> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? BorderRadius.circular(widget.height / 2);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onPressed == null ? null : (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onPressed == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              widget.onPressed!();
            },
      child: AnimatedScale(
        scale: _pressed ? 0.92 : 1.0,
        duration: Duration(milliseconds: _pressed ? 70 : 180),
        curve: Curves.easeOutCubic,
        child: LiquidGlass(
          borderRadius: radius,
          tinted: widget.tinted,
          blur: 24,
          child: Container(
            width: widget.width,
            height: widget.height,
            padding: widget.padding,
            alignment: widget.width != null ? Alignment.center : null,
            color: _pressed ? MacPalette.fill(0.08) : null,
            child: widget.width != null
                ? widget.child
                : Center(widthFactor: 1, child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// Navigation bar button: an iOS 26 Liquid Glass circular button, or a
/// Material [IconButton] on Android.
class PhoneBarButton extends StatelessWidget {
  const PhoneBarButton({
    super.key,
    required this.action,
    this.glass = true,
  });

  final PageAction action;
  final bool glass;

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
    if (!glass) {
      return Semantics(
        button: true,
        label: action.tooltip,
        child: Tooltip(
          message: action.tooltip,
          excludeFromSemantics: true,
          child: CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size(38, 38),
            onPressed: action.onPressed,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: MacPalette.fill(0.07),
              ),
              alignment: Alignment.center,
              child: Icon(
                action.icon,
                size: 18,
                color: color ??
                    (action.onPressed == null
                        ? MacPalette.textTertiary
                        : MacPalette.accent),
              ),
            ),
          ),
        ),
      );
    }
    return Semantics(
      button: true,
      label: action.tooltip,
      child: Tooltip(
        message: action.tooltip,
        excludeFromSemantics: true,
        child: Padding(
          padding: const EdgeInsets.only(left: 6),
          child: LiquidGlassButton(
            width: 36,
            height: 36,
            onPressed: action.onPressed,
            child: Icon(
              action.icon,
              size: 18,
              color: color ??
                  (action.onPressed == null
                      ? MacPalette.textTertiary
                      : MacPalette.textPrimary),
            ),
          ),
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
    this._previousTitle,
  });

  final String title;
  final Widget body;
  final List<PageAction> actions;
  final String? _previousTitle;

  String get previousTitle => _previousTitle ?? l10n.back;

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
        backgroundColor: MacPalette.background.withValues(alpha: 0.88),
        border: null,
        middle: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.41,
            color: MacPalette.textPrimary,
          ),
        ),
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

/// An entry in a [PhoneMenuButton].
class PhoneMenuEntry {
  const PhoneMenuEntry({
    required this.label,
    required this.icon,
    required this.materialIcon,
    required this.onSelected,
    this.destructive = false,
    this.startsGroup = false,
  });

  final String label;
  final IconData icon;
  final IconData materialIcon;
  final VoidCallback onSelected;
  final bool destructive;

  /// Draws a separator above this entry.
  final bool startsGroup;
}

/// A button that opens a menu: an iOS 26 Liquid Glass circular button opening a
/// compact glass popover, or a Material 3 popup menu on Android.
class PhoneMenuButton extends StatelessWidget {
  const PhoneMenuButton({
    super.key,
    required this.icon,
    required this.materialIcon,
    required this.tooltip,
    required this.entries,
    this.prominent = false,
  });

  final IconData icon;
  final IconData materialIcon;
  final String tooltip;
  final List<PhoneMenuEntry> entries;

  /// Larger floating orb (48pt) used for the bottom-right iOS 26 compose/add button.
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    if (usesMaterialChrome(context)) {
      return PopupMenuButton<int>(
        tooltip: tooltip,
        icon: Icon(materialIcon),
        onSelected: (index) => entries[index].onSelected(),
        itemBuilder: (_) => [
          for (final (index, entry) in entries.indexed) ...[
            if (entry.startsGroup && index > 0) const PopupMenuDivider(),
            PopupMenuItem<int>(
              value: index,
              child: Row(
                children: [
                  Icon(
                    entry.materialIcon,
                    size: 22,
                    color: entry.destructive ? MacPalette.red : null,
                  ),
                  const SizedBox(width: 14),
                  Text(
                    entry.label,
                    style: entry.destructive
                        ? TextStyle(color: MacPalette.red)
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    }
    final size = prominent ? 48.0 : 38.0;
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Builder(
          builder: (context) => LiquidGlassButton(
            width: size,
            height: size,
            onPressed: () => showPullDownMenu(context, entries),
            child: Icon(
              icon,
              size: prominent ? 23 : 19,
              color: MacPalette.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows an iOS 26 Liquid Glass menu anchored to the widget of [context].
///
/// A route rather than [CupertinoMenuAnchor]: the anchor's overlay portal
/// cannot be moved while the large-title navigation bar re-lays out its
/// buttons (collapsing, page transitions).
Future<void> showPullDownMenu(
  BuildContext context,
  List<PhoneMenuEntry> entries,
) async {
  final navigator = Navigator.of(context);
  final box = context.findRenderObject() as RenderBox?;
  final overlay = navigator.overlay?.context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null) return;
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  HapticFeedback.selectionClick();
  final chosen = await navigator.push<PhoneMenuEntry>(
    _PullDownMenuRoute(anchor: anchor, entries: entries),
  );
  chosen?.onSelected();
}

class _PullDownMenuRoute extends PopupRoute<PhoneMenuEntry> {
  _PullDownMenuRoute({required this.anchor, required this.entries});

  final Rect anchor;
  final List<PhoneMenuEntry> entries;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => l10n.closeMenu;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 240);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final screen = MediaQuery.sizeOf(context);
    final rightAligned = anchor.center.dx > screen.width / 2;
    final opensAbove = anchor.center.dy > screen.height * 0.58;
    final curved = CurvedAnimation(
      parent: animation,
      curve: const Cubic(0.18, 1.0, 0.22, 1.0),
      reverseCurve: Curves.easeInCubic,
    );
    final fade = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.0, 0.65, curve: Curves.easeOut),
      reverseCurve: Curves.easeIn,
    );
    final alignment = opensAbove
        ? (rightAligned ? Alignment.bottomRight : Alignment.bottomLeft)
        : (rightAligned ? Alignment.topRight : Alignment.topLeft);
    return CustomSingleChildLayout(
      delegate: _PullDownLayout(anchor, MediaQuery.paddingOf(context)),
      child: FadeTransition(
        opacity: fade,
        child: ScaleTransition(
          alignment: alignment,
          scale: Tween<double>(begin: 0.72, end: 1.0).animate(curved),
          child: _PullDownPanel(entries: entries),
        ),
      ),
    );
  }
}

/// Places the menu below (or above, when near the bottom) its button, aligned
/// to the button's outer edge and kept inside the safe area.
class _PullDownLayout extends SingleChildLayoutDelegate {
  _PullDownLayout(this.anchor, this.padding);

  final Rect anchor;
  final EdgeInsets padding;
  static const _margin = 14.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxHeight =
        constraints.maxHeight - padding.top - padding.bottom - 2 * _margin;
    return BoxConstraints(
      minWidth: 0,
      maxWidth: 204,
      maxHeight: maxHeight < 0 ? 0 : maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final rightAligned = anchor.center.dx > size.width / 2;
    var x = rightAligned ? anchor.right - childSize.width : anchor.left;
    x = x.clamp(_margin, size.width - childSize.width - _margin);
    var y = anchor.bottom + 8;
    final bottomLimit = size.height - padding.bottom - _margin;
    if (y + childSize.height > bottomLimit) {
      y = (anchor.top - 8 - childSize.height)
          .clamp(padding.top + _margin, bottomLimit - childSize.height);
    }
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_PullDownLayout oldDelegate) =>
      anchor != oldDelegate.anchor || padding != oldDelegate.padding;
}

class _PullDownPanel extends StatelessWidget {
  const _PullDownPanel({required this.entries});

  final List<PhoneMenuEntry> entries;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (final (index, entry) in entries.indexed) {
      if (index > 0 && entry.startsGroup) {
        rows.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Divider(height: 0.5, thickness: 0.5, color: MacPalette.hairline),
          ),
        );
      }
      rows.add(_PullDownItem(entry: entry));
    }
    // PopupRoute sits outside Scaffold/Material, so supply an explicit iOS
    // DefaultTextStyle; without it Flutter draws debug yellow underlines.
    final baseStyle = CupertinoTheme.of(context).textTheme.textStyle.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          letterSpacing: -0.32,
          height: 1.25,
          decoration: TextDecoration.none,
          color: MacPalette.textPrimary,
        );
    return DefaultTextStyle(
      style: baseStyle,
      child: CupertinoUserInterfaceLevel(
        data: CupertinoUserInterfaceLevelData.elevated,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 164, maxWidth: 204),
          child: IntrinsicWidth(
            child: LiquidGlass(
              borderRadius: BorderRadius.circular(22),
              blur: 34,
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PullDownItem extends StatefulWidget {
  const _PullDownItem({required this.entry});

  final PhoneMenuEntry entry;

  @override
  State<_PullDownItem> createState() => _PullDownItemState();
}

class _PullDownItemState extends State<_PullDownItem> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final color = entry.destructive ? MacPalette.red : MacPalette.textPrimary;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: () {
          HapticFeedback.selectionClick();
          Navigator.of(context).pop(entry);
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          constraints: const BoxConstraints(minHeight: 40),
          decoration: BoxDecoration(
            color: _pressed ? MacPalette.fill(0.11) : null,
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(entry.icon, size: 18, color: color),
              const SizedBox(width: 11),
              Flexible(
                child: Text(
                  entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                    letterSpacing: -0.32,
                    decoration: TextDecoration.none,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// iOS trailing swipe action: dragging a row left reveals a red button;
/// tapping it or swiping all the way across calls [onDelete].
class PhoneSwipeToDelete extends StatefulWidget {
  const PhoneSwipeToDelete({
    super.key,
    required this.child,
    required this.onDelete,
    this._label,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;
  final VoidCallback onDelete;
  final String? _label;

  String get label => _label ?? l10n.remove;
  final BorderRadius borderRadius;

  @override
  State<PhoneSwipeToDelete> createState() => _PhoneSwipeToDeleteState();
}

class _PhoneSwipeToDeleteState extends State<PhoneSwipeToDelete>
    with SingleTickerProviderStateMixin {
  static const _buttonWidth = 84.0;
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<double>? _settleTween;
  double _dx = 0;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _settle.addListener(() {
      final tween = _settleTween;
      if (tween != null) setState(() => _dx = tween.value);
    });
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  Future<void> _animateTo(double target) async {
    _settleTween = Tween<double>(begin: _dx, end: target).animate(
      CurvedAnimation(parent: _settle, curve: Curves.easeOutCubic),
    );
    await _settle.forward(from: 0);
  }

  Future<void> _delete(double width) async {
    if (_deleting) return;
    _deleting = true;
    HapticFeedback.mediumImpact();
    await _animateTo(-width);
    if (mounted) widget.onDelete();
  }

  void _onDragEnd(DragEndDetails details, double width) {
    final velocity = details.primaryVelocity ?? 0;
    final open = -_dx;
    if (open > width * 0.6 || (velocity < -1800 && open > _buttonWidth)) {
      _delete(width);
    } else if (open > _buttonWidth / 2 || velocity < -400) {
      _animateTo(-_buttonWidth);
    } else {
      _animateTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final open = -_dx;
        return GestureDetector(
          onHorizontalDragStart: (_) => _settle.stop(),
          onHorizontalDragUpdate: _deleting
              ? null
              : (details) => setState(() {
                    _dx = (_dx + details.delta.dx).clamp(-width, 0.0);
                  }),
          onHorizontalDragEnd: _deleting ? null : (d) => _onDragEnd(d, width),
          child: ClipRRect(
            borderRadius: widget.borderRadius,
            child: Stack(
              children: [
                if (open > 0)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: open < _buttonWidth ? _buttonWidth : open,
                    child: Semantics(
                      button: true,
                      child: GestureDetector(
                        onTap: () => _delete(width),
                        child: ColoredBox(
                          color: MacPalette.red,
                          child: Center(
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: MacPalette.onAccent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Transform.translate(
                  offset: Offset(_dx, 0),
                  child: widget.child,
                ),
                // While open, a tap on the row closes it instead.
                if (open > 0 && !_deleting)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    right: open,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _animateTo(0),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

enum PhoneButtonKind { primary, secondary, destructive }

/// A full-width phone button: the iOS filled / tinted button (50pt, rounded),
/// or a Material 3 filled / tonal / outlined button.
class PhoneButton extends StatelessWidget {
  const PhoneButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.kind = PhoneButtonKind.primary,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final PhoneButtonKind kind;

  @override
  Widget build(BuildContext context) =>
      NativeTypeScale(child: Builder(builder: _build));

  Widget _build(BuildContext context) {
    final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    final content = icon == null
        ? text
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 19),
              const SizedBox(width: 8),
              Flexible(child: text),
            ],
          );
    if (usesMaterialChrome(context)) {
      const size = Size.fromHeight(48);
      return switch (kind) {
        PhoneButtonKind.primary => FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: size,
              backgroundColor: MacPalette.accent,
              foregroundColor: MacPalette.onAccent,
            ),
            onPressed: onPressed,
            child: content,
          ),
        PhoneButtonKind.secondary => FilledButton.tonal(
            style: FilledButton.styleFrom(
              minimumSize: size,
              backgroundColor: MacPalette.accent.withValues(alpha: 0.14),
              foregroundColor: MacPalette.accent,
            ),
            onPressed: onPressed,
            child: content,
          ),
        PhoneButtonKind.destructive => OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: size,
              foregroundColor: MacPalette.red,
            ),
            onPressed: onPressed,
            child: content,
          ),
      };
    }
    final primary = kind == PhoneButtonKind.primary;
    final foreground = switch (kind) {
      PhoneButtonKind.primary => MacPalette.onAccent,
      PhoneButtonKind.secondary => MacPalette.accent,
      PhoneButtonKind.destructive => MacPalette.red,
    };
    return SizedBox(
      width: double.infinity,
      child: CupertinoButton(
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        borderRadius: BorderRadius.circular(25),
        color: primary ? MacPalette.accent : MacPalette.fill(0.10),
        disabledColor: MacPalette.fill(0.08),
        onPressed: onPressed,
        child: DefaultTextStyle.merge(
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: onPressed == null ? MacPalette.textTertiary : foreground,
          ),
          child: IconTheme.merge(
            data: IconThemeData(
              color: onPressed == null ? MacPalette.textTertiary : foreground,
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// A titled group of rows: the iOS inset grouped list, or a Material 3
/// rounded settings group. [footer] explains the group below it.
class PhoneSection extends StatelessWidget {
  const PhoneSection({
    super.key,
    this.header,
    this.footer,
    required this.children,
  });

  final String? header;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final material = usesMaterialChrome(context);
    return NativeTypeScale(
      child: Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                header!,
                style: TextStyle(
                  fontSize: material ? 14 : 13,
                  fontWeight: material ? FontWeight.w600 : FontWeight.w400,
                  letterSpacing: material ? null : -0.08,
                  color: material ? MacPalette.accent : MacPalette.textSecondary,
                ),
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(material ? 18 : 16),
            child: ColoredBox(
              color: MacPalette.cardBg,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (index, child) in children.indexed) ...[
                    if (index > 0)
                      Divider(
                        height: 0.5,
                        thickness: 0.5,
                        indent: 16,
                        color: MacPalette.hairline,
                      ),
                    child,
                  ],
                ],
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                footer!,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: MacPalette.textSecondary,
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }
}

/// A settings row: title on the left, an optional value and a chevron (iOS)
/// on the right.
class PhoneRow extends StatelessWidget {
  const PhoneRow({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleParts,
    this.value,
    this.leading,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.chevron = true,
    this.action = false,
    this.dimmed = false,
    this.selectable = false,
  });

  final String title;
  final Widget? leading;

  /// Greys out the title (an inactive entry that can still be opened).
  final bool dimmed;

  /// Lets the subtitle be selected and copied (paths, links).
  final bool selectable;
  final String? subtitle;

  /// Details shown as "a · b · c" that wrap only between parts, so a part
  /// like "剩余 19 小时" never splits across lines. Used instead of [subtitle].
  final List<String>? subtitleParts;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;
  final bool chevron;

  /// A button row: tinted title, no chevron (iOS Settings style).
  final bool action;

  @override
  Widget build(BuildContext context) {
    final material = usesMaterialChrome(context);
    return InkWell(
      onTap: onTap,
      splashFactory: material ? InkRipple.splashFactory : NoSplash.splashFactory,
      highlightColor: MacPalette.fill(0.08),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: material ? 56 : 46),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: subtitle == null ? 11 : 10,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Cap the trailing value width without wrapping it in Flexible so
              // Expanded(title) pushes value + chevron flush to the right edge.
              // The value gets at least 46% of the row, and all the room a short
              // title leaves (e.g. "添加时间" next to a full date).
              var maxValueWidth = constraints.maxWidth.isFinite
                  ? constraints.maxWidth * 0.46
                  : 160.0;
              if (constraints.maxWidth.isFinite && value != null) {
                final titleWidth = (TextPainter(
                  text: TextSpan(
                    text: title,
                    style: TextStyle(fontSize: material ? 16 : 16.5),
                  ),
                  maxLines: 1,
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                )..layout())
                    .width;
                final reserved = titleWidth +
                    12 +
                    (leading != null ? 40 : 0) +
                    (trailing != null ? 40 : 0) +
                    (onTap != null && chevron ? 24 : 0);
                final room = constraints.maxWidth - reserved;
                if (room > maxValueWidth) maxValueWidth = room;
              }
              return Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 12)],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: material ? 16 : 16.5,
                            letterSpacing: material ? null : -0.35,
                            color: dimmed
                                ? MacPalette.textTertiary
                                : destructive
                                    ? MacPalette.red
                                    : (action
                                        ? (onTap == null
                                            ? MacPalette.textTertiary
                                            : MacPalette.accent)
                                        : MacPalette.textPrimary),
                          ),
                        ),
                        if (subtitle == null && subtitleParts != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Wrap(
                              children: [
                                for (var i = 0; i < subtitleParts!.length; i++)
                                  Text(
                                    i == subtitleParts!.length - 1
                                        ? subtitleParts![i]
                                        : '${subtitleParts![i]} · ',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: material ? 14 : 13,
                                      height: 1.35,
                                      color: MacPalette.textSecondary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: selectable
                                ? SelectableText(
                                    subtitle!,
                                    style: TextStyle(
                                      fontSize: material ? 14 : 13,
                                      height: 1.35,
                                      color: MacPalette.textSecondary,
                                    ),
                                  )
                                : Text(
                                    subtitle!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: material ? 14 : 13,
                                      height: 1.35,
                                      color: MacPalette.textSecondary,
                                    ),
                                  ),
                          ),
                      ],
                    ),
                  ),
                  if (value != null) ...[
                    const SizedBox(width: 12),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxValueWidth),
                      child: Text(
                        value!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: material ? 14 : 16,
                          letterSpacing: material ? null : -0.3,
                          color: MacPalette.textSecondary,
                        ),
                      ),
                    ),
                  ],
                  if (trailing != null) ...[const SizedBox(width: 8), trailing!],
                  if (onTap != null && chevron && !action && !material) ...[
                    const SizedBox(width: 5),
                    Icon(
                      CupertinoIcons.chevron_right,
                      size: 13.5,
                      color: MacPalette.textTertiary,
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Lets the person pick one option: an iOS Settings-style list page with a
/// checkmark, or a Material 3 dialog with radio buttons.
Future<T?> showPhoneChoice<T>(
  BuildContext context, {
  required String title,
  required List<(T, String)> options,
  required T selected,
  String? footer,
  String? previousTitle,
}) {
  if (usesMaterialChrome(context)) {
    return showDialog<T>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (value, label) in options)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: Icon(
                  value == selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: value == selected ? MacPalette.accent : null,
                ),
                title: Text(label),
                onTap: () => Navigator.of(context).pop(value),
              ),
            if (footer != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Text(
                  footer,
                  style: TextStyle(fontSize: 13, color: MacPalette.textSecondary),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );
  }
  return Navigator.of(context).push<T>(
    CupertinoPageRoute<T>(
      builder: (context) => UiDensity(
        touch: true,
        child: Scaffold(
          backgroundColor: MacPalette.background,
          body: PhonePage(
            title: title,
            previousTitle: previousTitle ?? l10n.settings,
            body: ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
              children: [
                PhoneSection(
                  footer: footer,
                  children: [
                    for (final (value, label) in options)
                      PhoneRow(
                        title: label,
                        chevron: false,
                        trailing: value == selected
                            ? Icon(
                                CupertinoIcons.checkmark_alt,
                                size: 20,
                                color: MacPalette.accent,
                              )
                            : null,
                        onTap: () => Navigator.of(context).pop(value),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// A labelled text field row for a [PhoneSection].
class PhoneFieldRow extends StatelessWidget {
  const PhoneFieldRow({
    super.key,
    required this.controller,
    this.label,
    this.placeholder,
    this.obscureText = false,
    this.trailing,
    this.onSubmitted,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String? label;
  final String? placeholder;
  final bool obscureText;
  final Widget? trailing;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final size = usesMaterialChrome(context) ? 16.0 : 17.0;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: usesMaterialChrome(context) ? 56 : 44),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, trailing == null ? 16 : 4, 0),
        child: Row(
          children: [
            if (label != null)
              SizedBox(
                width: 96,
                child: Text(
                  label!,
                  style: TextStyle(fontSize: size, color: MacPalette.textPrimary),
                ),
              ),
            Expanded(
              child: TextField(
                controller: controller,
                obscureText: obscureText,
                keyboardType: keyboardType,
                onSubmitted: onSubmitted,
                style: TextStyle(fontSize: size, color: MacPalette.textPrimary),
                cursorColor: MacPalette.accent,
                decoration: InputDecoration.collapsed(
                  hintText: placeholder,
                  hintStyle: TextStyle(
                    fontSize: size,
                    color: MacPalette.textTertiary,
                  ),
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Offers actions for one thing: an iOS action sheet, or a Material 3 bottom
/// sheet. Entries flagged [PhoneMenuEntry.destructive] are shown in red.
Future<void> showPhoneActions(
  BuildContext context, {
  String? title,
  String? message,
  required List<PhoneMenuEntry> entries,
}) async {
  PhoneMenuEntry? chosen;
  if (usesMaterialChrome(context)) {
    chosen = await showModalBottomSheet<PhoneMenuEntry>(
      context: context,
      showDragHandle: true,
      backgroundColor: MacPalette.elevatedBg,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            for (final entry in entries)
              ListTile(
                leading: Icon(
                  entry.materialIcon,
                  color: entry.destructive ? MacPalette.red : null,
                ),
                title: Text(
                  entry.label,
                  style: entry.destructive ? TextStyle(color: MacPalette.red) : null,
                ),
                onTap: () => Navigator.of(context).pop(entry),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  } else {
    chosen = await showCupertinoModalPopup<PhoneMenuEntry>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: title == null ? null : Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        message: message == null ? null : Text(message),
        actions: [
          for (final entry in entries)
            CupertinoActionSheetAction(
              isDestructiveAction: entry.destructive,
              onPressed: () => Navigator.of(context).pop(entry),
              child: Text(entry.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
      ),
    );
  }
  chosen?.onSelected();
}

/// The platform segmented control: iOS sliding segments or a Material 3
/// segmented button.
class PhoneSegmented<T extends Object> extends StatelessWidget {
  const PhoneSegmented({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    if (usesMaterialChrome(context)) {
      return SegmentedButton<T>(
        showSelectedIcon: false,
        segments: [
          for (final (value, label) in options)
            ButtonSegment<T>(value: value, label: Text(label)),
        ],
        selected: {selected},
        onSelectionChanged: (values) => onChanged(values.first),
      );
    }
    return CupertinoSlidingSegmentedControl<T>(
      groupValue: selected,
      children: {
        for (final (value, label) in options)
          value: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(label, style: const TextStyle(fontSize: 14)),
          ),
      },
      onValueChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }
}
