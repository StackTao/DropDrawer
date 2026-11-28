part of 'drawer_screen.dart';

/// Small widgets and helpers used by the drawer screen.

class _ToastCapsule extends StatelessWidget {
  final String message;

  const _ToastCapsule({required this.message});

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + 6;
    return Positioned(
      top: top,
      left: 24,
      right: 24,
      child: IgnorePointer(
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, (1 - t) * -16),
                child: child,
              ),
            ),
            child: Material(
              color: MacPalette.toastBackground,
              elevation: 8,
              shadowColor: MacPalette.shade(0.5),
              borderRadius: BorderRadius.circular(22),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: MacPalette.toastText),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingDropTile extends StatelessWidget {
  final PendingDrop drop;
  final bool isMobile;

  /// Inside a phone row frame, which draws the background.
  final bool framed;

  const _PendingDropTile({
    required this.drop,
    required this.isMobile,
    this.framed = false,
  });

  @override
  Widget build(BuildContext context) {
    final box = isMobile ? 44.0 : 34.0;
    return Container(
      padding: framed
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 10)
          : EdgeInsets.symmetric(
              horizontal: isMobile ? 12 : 10,
              vertical: isMobile ? 11 : 9,
            ),
      decoration: framed
          ? null
          : BoxDecoration(
              color: MacPalette.cardBg,
              borderRadius: BorderRadius.circular(isMobile ? 12 : 10),
            ),
      child: Row(
        children: [
          Container(
            width: box,
            height: box,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: MacPalette.fill(0.08),
              borderRadius: BorderRadius.circular(box * 0.235),
            ),
            child: const AdaptiveSpinner(radius: 7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  drop.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isMobile ? 15 : 12.5,
                    fontWeight: FontWeight.w500,
                    color: MacPalette.textSecondary,
                  ),
                ),
                SizedBox(height: isMobile ? 3 : 2),
                Text(
                  l10n.addingToTheDrawer,
                  style: TextStyle(
                    fontSize: isMobile ? 12.5 : 10.5,
                    color: MacPalette.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints a soft inward-blooming luminous halo + crisp glowing rim clipped to
/// the rounded window interior so desktop windows glow during drag hover
/// without overflowing native window bounds or shifting layout.
class _InnerEdgeGlowPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double pulse;
  final bool subtle;

  const _InnerEdgeGlowPainter({
    required this.color,
    required this.radius,
    required this.pulse,
    this.subtle = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final outer = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas.save();
    canvas.clipRRect(outer);

    final wideHalo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = subtle ? 14 : 26
      ..color = color.withValues(alpha: subtle ? 0.16 : (0.24 + 0.10 * pulse))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, subtle ? 8 : 14);
    canvas.drawRRect(outer, wideHalo);

    final midRim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = subtle ? 6 : 10
      ..color = color.withValues(alpha: subtle ? 0.24 : (0.38 + 0.14 * pulse))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, subtle ? 3.5 : 5);
    canvas.drawRRect(outer, midRim);

    final rimRect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.9),
      Radius.circular((radius - 0.9).clamp(0.0, radius)),
    );
    final crispRim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = subtle ? 1.2 : 1.8
      ..color = color.withValues(alpha: subtle ? 0.65 : (0.84 + 0.16 * pulse));
    canvas.drawRRect(rimRect, crispRim);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_InnerEdgeGlowPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.pulse != pulse ||
      old.subtle != subtle;
}

/// Short relative time in the UI language, e.g. "Just now", "5 minutes ago",
/// "Yesterday" or "Mar 2".
@visibleForTesting
String relativeTimeLabel(DateTime time, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final local = time.toLocal();
  final diff = current.difference(local);
  if (diff.inMinutes < 1) return l10n.justNow;
  if (diff.inHours < 1) return l10n.minutesAgo(diff.inMinutes);
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(local.year, local.month, local.day);
  final days = today.difference(day).inDays;
  if (days == 0) return l10n.hoursAgo(diff.inHours);
  if (days == 1) return l10n.yesterday;
  return AppLocale.shortDate(local, now: current);
}
