import 'package:flutter/material.dart';

/// Restrained macOS-inspired neutral dark palette (pairs with native NSVisualEffectView).
class MacPalette {
  static const surfaceTint = Color(0x99161618);
  static const cardBg = Color(0x12FFFFFF);
  static const cardHoverBg = Color(0x1EFFFFFF);
  static const elevatedBg = Color(0xFF1E1E20);
  static const hairline = Color(0x1CFFFFFF);
  static const strongHairline = Color(0x30FFFFFF);

  static const textPrimary = Color(0xFFF5F5F7);
  static const textSecondary = Color(0x99EBEBF5);
  static const textTertiary = Color(0x5CEBEBF5);

  static const accent = Color(0xFF0A84FF);
  static const green = Color(0xFF30D158);
  static const amber = Color(0xFFFFD60A);
  static const red = Color(0xFFFF453A);
}

/// Compact 26x26 macOS toolbar/action icon button with subtle hover plate.
class MacIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  final bool active;

  const MacIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.color,
    this.size = 15,
    this.active = false,
  });

  @override
  State<MacIconButton> createState() => _MacIconButtonState();
}

class _MacIconButtonState extends State<MacIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.active
        ? Colors.white.withValues(alpha: 0.16)
        : (_hovered ? Colors.white.withValues(alpha: 0.10) : Colors.transparent);
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
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(widget.icon, size: widget.size, color: fg),
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
    return Container(
      height: 26,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: MacPalette.hairline, width: 0.5),
      ),
      child: Row(
        children: items.map((entry) {
          final isSelected = entry.$1 == selected;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(entry.$1),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.white.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(5),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 2,
                            offset: const Offset(0, 1),
                          )
                        ]
                      : null,
                ),
                child: Text(
                  entry.$2,
                  style: TextStyle(
                    fontSize: 11,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 68,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
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
              style: const TextStyle(
                fontSize: 12.5,
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
                hintStyle: const TextStyle(
                  fontSize: 12.5,
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
