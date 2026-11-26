import 'package:flutter/material.dart';

import '../services/app_update_service.dart';
import '../state/app_update_controller.dart';
import 'phone_page.dart';
import 'theme.dart';

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
                      '自动检查',
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
                      child: const Text('检查更新'),
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
                      child: const Text('打开安装包'),
                    ),
                  TextButton(
                    style: TextButton.styleFrom(minimumSize: Size(0, buttonHeight)),
                    onPressed: updates.openReleasePage,
                    child: Text(updates.update == null ? '发布页' : '更新说明'),
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
      header: '关于与更新',
      footer: _status(),
      children: [
        PhoneRow(title: 'DropDrawer', value: version ?? '—'),
        if (updates.canUpdate)
          PhoneRow(
            title: '自动检查更新',
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
            title: '打开安装包',
            action: true,
            onTap: updates.openManualPackage,
          ),
        if (updates.canUpdate)
          PhoneRow(
            title: '检查更新',
            action: true,
            onTap: busy ? null : () => updates.check(),
          ),
        PhoneRow(
          title: updates.update == null ? '发布页' : '更新说明',
          action: true,
          onTap: updates.openReleasePage,
        ),
      ],
    );
  }

  String _installLabel(AppUpdate update) {
    final mb = (update.package.size / 1048576).toStringAsFixed(1);
    return updates.platform.isDesktop
        ? '更新到 ${update.version}（$mb MB）并重启'
        : '更新到 ${update.version}（$mb MB）';
  }

  String _status() {
    final installed = updates.installed;
    if (installed == null) return '正在读取版本…';
    if (updates.platform == UpdatePlatform.unsupported) {
      return '这个平台的新版本请从发布页获取。';
    }
    if (!installed.isRelease) {
      return '开发版本（构建时未指定发布标签），不检查更新。';
    }
    return switch (updates.phase) {
      UpdatePhase.idle => updates.autoCheck ? '每天自动检查一次新版本。' : '已关闭自动检查。',
      UpdatePhase.checking => '正在检查更新…',
      UpdatePhase.upToDate => updates.hasNewerReleaseForOtherPlatforms
          ? '已有新版本发布，但还没有这个平台的安装包。'
          : '已是最新版本。',
      UpdatePhase.available => '新版本 ${updates.update!.version} 可以更新。',
      UpdatePhase.downloading =>
        '正在下载并校验 ${((updates.progress ?? 0) * 100).round()}%…',
      UpdatePhase.installing => updates.platform.isDesktop
          ? '正在安装，DropDrawer 将自动重启。'
          : (updates.message ?? '正在打开系统安装界面…'),
      UpdatePhase.failed => updates.message ?? '更新失败，请重试。',
    };
  }
}
