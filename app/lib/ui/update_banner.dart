import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../state/app_update_controller.dart';
import 'theme.dart';
import '../l10n/l10n.dart';

/// A slim bar above the drawer's footer when an update is available, with a
/// one-click install. Hidden when there is nothing to install or after "稍后".
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.updates, required this.mobile});

  final AppUpdateController updates;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final update = updates.update;
        if (!updates.showBanner || update == null) return const SizedBox.shrink();
        final phase = updates.phase;
        final fontSize = mobile ? 14.0 : 11.5;
        final String text;
        if (phase == UpdatePhase.downloading) {
          text = l10n.downloadingUpdateProgress(update.version, ((updates.progress ?? 0) * 100).round());
        } else if (phase == UpdatePhase.installing) {
          text = updates.platform.isDesktop
              ? l10n.installingDropdrawerWillRestartAutomatically(update.version)
              : (updates.message ?? l10n.openingTheSystemInstaller);
        } else if (phase == UpdatePhase.failed) {
          text = updates.message ?? l10n.updateFailed;
        } else {
          text = l10n.versionIsAvailable(update.version);
        }
        final actionable =
            phase == UpdatePhase.available || phase == UpdatePhase.failed;
        return Container(
          margin: mobile
              ? const EdgeInsets.fromLTRB(14, 0, 14, 8)
              : const EdgeInsets.fromLTRB(12, 0, 12, 6),
          padding: EdgeInsets.fromLTRB(12, mobile ? 8 : 6, 4, mobile ? 8 : 6),
          decoration: BoxDecoration(
            color: MacPalette.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(mobile ? 12 : 9),
            border: Border.all(color: MacPalette.accent.withValues(alpha: 0.35), width: 0.8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    phase == UpdatePhase.failed
                        ? CupertinoIcons.exclamationmark_circle
                        : CupertinoIcons.arrow_down_circle,
                    size: mobile ? 18 : 14,
                    color: phase == UpdatePhase.failed ? MacPalette.red : MacPalette.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: fontSize, color: MacPalette.textPrimary),
                    ),
                  ),
                  if (updates.manualPackage != null)
                    _action(l10n.openInstaller, updates.openManualPackage, fontSize, strong: true)
                  else if (actionable)
                    _action(
                      phase == UpdatePhase.failed ? l10n.retry : l10n.update,
                      updates.install,
                      fontSize,
                      strong: true,
                    ),
                  if (actionable)
                    _action(l10n.later, updates.dismiss, fontSize),
                ],
              ),
              if (phase == UpdatePhase.downloading || phase == UpdatePhase.installing) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: phase == UpdatePhase.downloading ? updates.progress : null,
                      minHeight: 2.5,
                      backgroundColor: MacPalette.fill(0.1),
                      color: MacPalette.accent,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _action(String label, VoidCallback onTap, double fontSize, {bool strong = false}) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: Size(mobile ? 44 : 0, mobile ? 40 : 26),
        padding: EdgeInsets.symmetric(horizontal: mobile ? 10 : 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: strong ? MacPalette.accent : MacPalette.textSecondary,
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: fontSize, fontWeight: strong ? FontWeight.w600 : FontWeight.w400),
      ),
    );
  }
}
