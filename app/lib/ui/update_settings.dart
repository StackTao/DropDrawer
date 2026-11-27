import 'package:flutter/material.dart';

import '../services/app_update_service.dart';
import '../state/app_update_controller.dart';
import 'phone_page.dart';
import 'theme.dart';
import '../l10n/l10n.dart';

/// "关于与更新" in Preferences: version, automatic checks and manual actions.
class UpdateSettings extends StatelessWidget {
  const UpdateSettings({super.key, required this.updates, required this.mobile});

  final AppUpdateController updates;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final installed = updates.installed;
        final version = installed?.version;
        if (mobile) return _buildPhone(version?.toString());
        final titleSize = mobile ? 14.0 : 12.0;
        final noteSize = mobile ? 12.5 : 10.5;
        final buttonHeight = mobile ? 44.0 : 30.0;
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      version == null ? 'DropDrawer' : 'DropDrawer $version',
                      style: TextStyle(
                        fontSize: titleSize,
                        fontWeight: FontWeight.w500,
                        color: MacPalette.textPrimary,
                      ),
                    ),
                  ),
                  if (updates.canUpdate)
                    Text(
                      l10n.checkAutomatically,
                      style: TextStyle(fontSize: noteSize, color: MacPalette.textSecondary),
                    ),
                  if (updates.canUpdate)
                    AdaptiveSwitch(
                      value: updates.autoCheck,
                      onChanged: updates.setAutoCheck,
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Semantics(
                liveRegion: true,
                child: Text(
                  _status(),
                  style: TextStyle(fontSize: noteSize, color: MacPalette.textTertiary),
                ),
              ),
              if (updates.phase == UpdatePhase.checking ||
                  updates.phase == UpdatePhase.downloading) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: updates.progress,
                    minHeight: 3,
                    backgroundColor: MacPalette.fill(0.1),
                    color: MacPalette.accent,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (updates.canUpdate)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: Size(0, buttonHeight)),
                      onPressed: updates.busy ? null : () => updates.check(),
                      child: Text(l10n.checkForUpdates),
                    ),
                  if (updates.update != null && updates.manualPackage == null)
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: Size(0, buttonHeight)),
                      onPressed: updates.busy ? null : updates.install,
                      child: Text(_installLabel(updates.update!)),
                    ),
                  if (updates.manualPackage != null)
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: Size(0, buttonHeight)),
                      onPressed: updates.openManualPackage,
                      child: Text(l10n.openInstaller),
                    ),
                  TextButton(
                    style: TextButton.styleFrom(minimumSize: Size(0, buttonHeight)),
                    onPressed: updates.openReleasePage,
                    child: Text(updates.update == null ? l10n.releases : l10n.releaseNotes),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// Phones: a settings group with the version, the automatic-check switch
  /// and action rows; the status reads as the group's footer.
  Widget _buildPhone(String? version) {
    final busy = updates.busy;
    return PhoneSection(
      header: l10n.aboutUpdates,
      footer: _status(),
      children: [
        PhoneRow(title: 'DropDrawer', value: version ?? '—'),
        if (updates.canUpdate)
          PhoneRow(
            title: l10n.checkForUpdatesAutomatically,
            trailing: AdaptiveSwitch(
              value: updates.autoCheck,
              onChanged: updates.setAutoCheck,
            ),
          ),
        if (updates.phase == UpdatePhase.checking ||
            updates.phase == UpdatePhase.downloading)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: updates.progress,
                minHeight: 3,
                backgroundColor: MacPalette.fill(0.1),
                color: MacPalette.accent,
              ),
            ),
          ),
        if (updates.update != null && updates.manualPackage == null)
          PhoneRow(
            title: _installLabel(updates.update!),
            action: true,
            onTap: busy ? null : updates.install,
          ),
        if (updates.manualPackage != null)
          PhoneRow(
            title: l10n.openInstaller,
            action: true,
            onTap: updates.openManualPackage,
          ),
        if (updates.canUpdate)
          PhoneRow(
            title: l10n.checkForUpdates,
            action: true,
            onTap: busy ? null : () => updates.check(),
          ),
        PhoneRow(
          title: updates.update == null ? l10n.releases : l10n.releaseNotes,
          action: true,
          onTap: updates.openReleasePage,
        ),
      ],
    );
  }

  String _installLabel(AppUpdate update) {
    final mb = (update.package.size / 1048576).toStringAsFixed(1);
    return updates.platform.isDesktop
        ? l10n.updateToMbAndRestart(update.version, mb)
        : l10n.updateToMb(update.version, mb);
  }

  String _status() {
    final installed = updates.installed;
    if (installed == null) return l10n.readingVersion;
    if (updates.platform == UpdatePlatform.unsupported) {
      return l10n.getNewVersionsForThisPlatform;
    }
    if (!installed.isRelease) {
      return l10n.developmentBuildNoReleaseTagAt;
    }
    return switch (updates.phase) {
      UpdatePhase.idle => updates.autoCheck ? l10n.checksForANewVersionOnce : l10n.automaticChecksAreOff,
      UpdatePhase.checking => l10n.checkingForUpdates,
      UpdatePhase.upToDate => updates.hasNewerReleaseForOtherPlatforms
          ? l10n.aNewVersionWasReleasedBut
          : l10n.youReUpToDate,
      UpdatePhase.available => l10n.versionIsReadyToInstall(updates.update!.version),
      UpdatePhase.downloading =>
        l10n.downloadingAndVerifyingProgress(((updates.progress ?? 0) * 100).round()),
      UpdatePhase.installing => updates.platform.isDesktop
          ? l10n.installingDropdrawerWillRestartAutomatically2
          : (updates.message ?? l10n.openingTheSystemInstaller2),
      UpdatePhase.failed => updates.message ?? l10n.updateFailedTryAgain,
    };
  }
}
