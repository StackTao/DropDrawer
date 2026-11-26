import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// A navigation bar button that opens a menu: the iOS pull-down menu, or a
/// Material 3 popup menu on Android.
class PhoneMenuButton extends StatelessWidget {
  const PhoneMenuButton({
    super.key,
    required this.icon,
    required this.materialIcon,
    required this.tooltip,
    required this.entries,
  });

  final IconData icon;
  final IconData materialIcon;
  final String tooltip;
  final List<PhoneMenuEntry> entries;

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
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Builder(
          builder: (context) => CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size(44, 44),
            onPressed: () => showPullDownMenu(context, entries),
            child: Icon(icon, size: 23, color: MacPalette.accent),
          ),
        ),
      ),
    );
  }
}

/// Shows an iOS pull-down menu below the widget of [context].
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
  Color? get barrierColor => MacPalette.shade(0.08);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '关闭菜单';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return CustomSingleChildLayout(
      delegate: _PullDownLayout(anchor, MediaQuery.paddingOf(context)),
      child: _PullDownPanel(entries: entries),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        alignment: anchor.center.dx > MediaQuery.sizeOf(context).width / 2
            ? Alignment.topRight
            : Alignment.topLeft,
        scale: Tween<double>(begin: 0.8, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}

/// Places the menu under its button, aligned to the button's outer edge and
/// kept on screen.
class _PullDownLayout extends SingleChildLayoutDelegate {
  _PullDownLayout(this.anchor, this.padding);

  final Rect anchor;
  final EdgeInsets padding;
  static const _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxHeight =
        constraints.maxHeight - padding.top - padding.bottom - 2 * _margin;
    return BoxConstraints(
      minWidth: 0,
      maxWidth: 250,
      maxHeight: maxHeight < 0 ? 0 : maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final rightAligned = anchor.center.dx > size.width / 2;
    var x = rightAligned ? anchor.right - childSize.width : anchor.left;
    x = x.clamp(_margin, size.width - childSize.width - _margin);
    var y = anchor.bottom + 4;
    final bottomLimit = size.height - padding.bottom - _margin;
    if (y + childSize.height > bottomLimit) {
      y = (anchor.top - 4 - childSize.height)
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
      if (index > 0) {
        rows.add(entry.startsGroup
            // iOS separates groups with a thicker band.
            ? Container(height: 8, color: MacPalette.shade(0.12))
            : Divider(height: 0.5, thickness: 0.5, color: MacPalette.hairline));
      }
      rows.add(_PullDownItem(entry: entry));
    }
    return SizedBox(
      width: 250,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          boxShadow: [
            BoxShadow(
              color: MacPalette.shade(0.35),
              blurRadius: 32,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: ColoredBox(
              color: MacPalette.elevatedBg.withValues(alpha: 0.86),
              child: SingleChildScrollView(
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
        onTap: () => Navigator.of(context).pop(entry),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          color: _pressed ? MacPalette.fill(0.10) : null,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  entry.label,
                  style: TextStyle(fontSize: 17, color: color),
                ),
              ),
              const SizedBox(width: 12),
              Icon(entry.icon, size: 20, color: color),
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
    this.label = '移出',
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;
  final VoidCallback onDelete;
  final String label;
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
        borderRadius: BorderRadius.circular(12),
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
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
              child: Text(
                header!,
                style: TextStyle(
                  fontSize: material ? 14 : 13,
                  fontWeight: material ? FontWeight.w600 : FontWeight.w400,
                  color: material ? MacPalette.accent : MacPalette.textSecondary,
                ),
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(material ? 18 : 10),
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
              padding: const EdgeInsets.fromLTRB(16, 7, 16, 0),
              child: Text(
                footer!,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
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
    this.value,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.chevron = true,
    this.action = false,
  });

  final String title;
  final String? subtitle;
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
        constraints: BoxConstraints(minHeight: material ? 56 : 44),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: subtitle == null ? 11 : 9,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: material ? 16 : 17,
                        color: destructive
                            ? MacPalette.red
                            : (action
                                ? (onTap == null
                                    ? MacPalette.textTertiary
                                    : MacPalette.accent)
                                : MacPalette.textPrimary),
                      ),
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: material ? 14 : 13,
                            color: MacPalette.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: material ? 14 : 17,
                      color: MacPalette.textSecondary,
                    ),
                  ),
                ),
              ],
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              if (onTap != null && chevron && !action && !material) ...[
                const SizedBox(width: 6),
                Icon(
                  CupertinoIcons.chevron_right,
                  size: 15,
                  color: MacPalette.textTertiary,
                ),
              ],
            ],
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
  String previousTitle = '设置',
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
            child: const Text('取消'),
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
            previousTitle: previousTitle,
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
