import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../state/drawer_controller.dart';
import 'theme.dart';

/// Server-wide announcement published from the admin console. Sits next to the
/// update banner; closing it hides this revision until the admin edits it.
class AnnouncementBanner extends StatelessWidget {
  const AnnouncementBanner({super.key, required this.controller, required this.mobile});

  final DropDrawerController controller;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final announcement = controller.activeAnnouncement;
    if (announcement == null) return const SizedBox.shrink();
    final Color tint;
    final IconData iconData;
    switch (announcement.level) {
      case 'critical':
        tint = MacPalette.red;
        iconData = CupertinoIcons.exclamationmark_octagon;
      case 'warning':
        tint = MacPalette.amber;
        iconData = CupertinoIcons.exclamationmark_triangle;
      default:
        tint = MacPalette.accent;
        iconData = CupertinoIcons.speaker_2;
    }
    final titleSize = mobile ? 14.0 : 11.5;
    final bodySize = mobile ? 13.0 : 11.0;
    final hasTitle = announcement.title.trim().isNotEmpty;
    final hasBody = announcement.message.trim().isNotEmpty;
    return Semantics(
      container: true,
      label: '服务器公告',
      child: Container(
        margin: mobile
            ? const EdgeInsets.fromLTRB(14, 0, 14, 8)
            : const EdgeInsets.fromLTRB(12, 0, 12, 6),
        padding: EdgeInsets.fromLTRB(12, mobile ? 10 : 7, 4, mobile ? 10 : 7),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(mobile ? 12 : 9),
          border: Border.all(color: tint.withValues(alpha: 0.35), width: 0.8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(iconData, size: mobile ? 18 : 14, color: tint),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasTitle)
                    Text(
                      announcement.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: titleSize,
                        fontWeight: FontWeight.w600,
                        color: MacPalette.textPrimary,
                      ),
                    ),
                  if (hasBody) ...[
                    if (hasTitle) const SizedBox(height: 2),
                    Text(
                      announcement.message,
                      maxLines: mobile ? 6 : 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: bodySize, color: MacPalette.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: '关闭公告',
              onPressed: controller.dismissAnnouncement,
              icon: Icon(CupertinoIcons.xmark, size: mobile ? 16 : 12),
              color: MacPalette.textSecondary,
              visualDensity: VisualDensity.compact,
              constraints: BoxConstraints.tightFor(
                width: mobile ? 40 : 26,
                height: mobile ? 40 : 26,
              ),
              padding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }
}
