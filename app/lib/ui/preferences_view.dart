import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../state/drawer_controller.dart';
import 'theme.dart';
import 'update_settings.dart';

/// macOS System-Settings style in-drawer Preferences view.
class PreferencesView extends StatefulWidget {
  final DropDrawerController controller;
  final VoidCallback onBack;

  const PreferencesView({
    super.key,
    required this.controller,
    required this.onBack,
  });

  @override
  State<PreferencesView> createState() => _PreferencesViewState();
}

class _PreferencesViewState extends State<PreferencesView> {
  String _effectiveDir = '';
  bool _recordingHotkey = false;
  String? _hotkeyHint;

  @override
  void initState() {
    super.initState();
    _loadDir();
    widget.controller.windowService.refreshSystemSettings();
  }

  @override
  void dispose() {
    if (_recordingHotkey) {
      widget.controller.windowService.cancelHotkeyRecording();
    }
    super.dispose();
  }

  Future<void> _toggleRecordHotkey() async {
    if (_recordingHotkey) {
      await widget.controller.windowService.cancelHotkeyRecording();
      if (mounted) setState(() => _recordingHotkey = false);
      return;
    }
    setState(() {
      _recordingHotkey = true;
      _hotkeyHint = widget.controller.windowService.isWindows
          ? '请按下含 Ctrl、Alt 或 Win 的组合键，也可使用 F1–F24。按 Esc 取消。'
          : '请直接按下组合键（需含 ⌘ / ⌥ / ⌃ 或 F1-F12，Esc 取消）';
    });
    final res = await widget.controller.windowService.recordHotkeyNative();
    if (!mounted) return;
    final recorded = res['recorded'] as bool? ?? false;
    final ok = res['ok'] as bool? ?? true;
    final label = res['label'] as String? ?? widget.controller.windowService.hotkeyLabel;
    setState(() {
      _recordingHotkey = false;
      if (recorded) {
        _hotkeyHint = ok ? '已生效：$label' : '系统可能已占用 $label，请换一个组合键';
      } else {
        _hotkeyHint = null;
      }
    });
    if (recorded && ok) {
      widget.controller.setBanner('全局呼出快捷键已更新为 $label');
    }
  }

  Future<void> _applyHotkeyPreset(
    String label,
    int keyCode,
    List<String> modifiers,
  ) async {
    if (_recordingHotkey) {
      await widget.controller.windowService.cancelHotkeyRecording();
      if (mounted) setState(() => _recordingHotkey = false);
    }
    final ok = await widget.controller.windowService.setHotkeyPreset(
      keyCode: keyCode,
      modifiers: modifiers,
    );
    if (!mounted) return;
    setState(() {
      _hotkeyHint = ok ? '已生效：$label' : '系统可能已占用 $label，请尝试其他组合';
    });
    if (ok) {
      widget.controller.setBanner('全局呼出快捷键已设为 $label');
    }
  }

  Future<void> _loadDir() async {
    final dir = await widget.controller.getEffectiveDownloadDir();
    if (mounted) setState(() => _effectiveDir = dir);
  }

  Future<void> _pickDownloadDir() async {
    await widget.controller.windowService.setModalOpen(true);
    try {
      final chosen =
          await widget.controller.windowService.pickDirectoryNative();
      if (chosen != null && chosen.isNotEmpty) {
        await widget.controller.setCustomDownloadDir(chosen);
        await _loadDir();
      }
    } finally {
      await widget.controller.windowService.setModalOpen(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final isWindows = c.windowService.isWindows;
    final thresholdMb = c.autoCloudThresholdBytes ~/ (1024 * 1024);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: c.windowService.needsMacTrafficLightPadding
              ? const EdgeInsets.fromLTRB(78, 1, 10, 3)
              : const EdgeInsets.fromLTRB(10, 10, 12, 9),
          child: SizedBox(
            height: UiDensity.headerHeight(context),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                MacIconButton(
                  icon: CupertinoIcons.chevron_left,
                  tooltip: '返回抽屉',
                  size: 15,
                  onPressed: widget.onBack,
                ),
                const SizedBox(width: 4),
                const Text(
                  '偏好设置',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 0.5, thickness: 0.5),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              const _SectionLabel('传输与自动清理'),
              const SizedBox(height: 6),
              _GroupBox(
                children: [
                  // Phones have no drop header, so the policy is chosen here.
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '新文件传输策略',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: MacPalette.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '智能：小文件同时存云盘、大文件只走 P2P；纯 P2P：不经过服务器；强制存云盘：来源离线也能下载',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: MacPalette.textTertiary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        MacSegmentedControl<String>(
                          selected: c.defaultDropPolicy,
                          items: const [
                            ('smart', '智能'),
                            ('p2p_only', '纯 P2P'),
                            ('cloud_cached', '存云盘'),
                          ],
                          onChanged: c.setDropPolicy,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 0.5, thickness: 0.5, indent: 12),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '默认过期自动清理',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: MacPalette.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '新拖入的文件/文本到期后自动清理云端缓存与抽屉记录',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: MacPalette.textTertiary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        MacSegmentedControl<int>(
                          selected: c.defaultTtlHours,
                          items: const [
                            (0, '永不过期'),
                            (24, '24 小时'),
                            (168, '7 天'),
                            (720, '30 天'),
                          ],
                          onChanged: c.setDefaultTtlHours,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 0.5, thickness: 0.5, indent: 12),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '智能模式自动上云阈值',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: MacPalette.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '小于该体积自动缓存至云盘，超过则纯 P2P 端到端直连',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: MacPalette.textTertiary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        MacSegmentedControl<int>(
                          selected: [10, 20, 50, 100].contains(thresholdMb)
                              ? thresholdMb
                              : 20,
                          items: const [
                            (10, '10 MB'),
                            (20, '20 MB'),
                            (50, '50 MB'),
                            (100, '100 MB'),
                          ],
                          onChanged: c.setAutoCloudThresholdMb,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 0.5, thickness: 0.5, indent: 12),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '默认下载目录',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: MacPalette.textPrimary,
                              ),
                            ),
                            const Spacer(),
                            if (c.customDownloadDir != null)
                              GestureDetector(
                                onTap: () async {
                                  await c.setCustomDownloadDir(null);
                                  await _loadDir();
                                },
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: Text(
                                    '恢复默认',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: MacPalette.accent,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _effectiveDir.isEmpty ? '加载中...' : _effectiveDir,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontFamily: 'Menlo',
                            color: MacPalette.textSecondary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (c.windowService.supportsEdgeDrawer)
                              Expanded(
                                child: SizedBox(
                                  height: 28,
                                  child: OutlinedButton(
                                    onPressed: _pickDownloadDir,
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: MacPalette.textPrimary,
                                      side: BorderSide(
                                        color: MacPalette.strongHairline,
                                        width: 0.7,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(7),
                                      ),
                                    ),
                                    child: const Text(
                                      '更改目录',
                                      style: TextStyle(fontSize: 11.5),
                                    ),
                                  ),
                                ),
                              ),
                            if (c.windowService.supportsEdgeDrawer &&
                                _effectiveDir.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              SizedBox(
                                height: 28,
                                child: OutlinedButton(
                                  onPressed: () => c.windowService
                                      .openDirectoryNative(_effectiveDir),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: MacPalette.textSecondary,
                                    side: BorderSide(
                                      color: MacPalette.hairline,
                                      width: 0.7,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(7),
                                    ),
                                  ),
                                  child: const Text(
                                    '打开',
                                    style: TextStyle(fontSize: 11.5),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (c.windowService.supportsEdgeDrawer) ...[
                const SizedBox(height: 16),
                _SectionLabel(isWindows ? '窗口与 Windows 集成' : '窗口与 macOS 集成'),
                const SizedBox(height: 6),
                _GroupBox(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '边缘抽屉停靠侧',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: MacPalette.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '也可直接按住边缘悬浮手柄上下或跨屏拖动调整',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: MacPalette.textTertiary,
                            ),
                          ),
                          const SizedBox(height: 8),
                          MacSegmentedControl<String>(
                            selected: c.windowService.dockSide,
                            items: const [
                              ('left', '屏幕左侧'),
                              ('right', '屏幕右侧'),
                            ],
                            onChanged: (side) =>
                                c.windowService.setDockSide(side),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 0.5, thickness: 0.5, indent: 12),
                    _SwitchRow(
                      title: '全局快捷键呼出抽屉',
                      subtitle: '任意应用下快速展开或收起抽屉，可自定义避免冲突',
                      value: c.windowService.hotkeyEnabled,
                      onChanged: (v) async {
                        if (_recordingHotkey) {
                          await c.windowService.cancelHotkeyRecording();
                          if (mounted) setState(() => _recordingHotkey = false);
                        }
                        await c.windowService.setHotkeyEnabled(v);
                      },
                    ),
                    if (c.windowService.hotkeyEnabled)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '当前快捷键',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: MacPalette.textSecondary,
                                  ),
                                ),
                                const Spacer(),
                                GestureDetector(
                                  onTap: _toggleRecordHotkey,
                                  child: MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    child: AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 140),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _recordingHotkey
                                            ? MacPalette.accent
                                                .withValues(alpha: 0.22)
                                            : MacPalette.fill(0.09),
                                        borderRadius: BorderRadius.circular(7),
                                        border: Border.all(
                                          color: _recordingHotkey
                                              ? MacPalette.accent
                                              : MacPalette.strongHairline,
                                          width: _recordingHotkey ? 1.0 : 0.7,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _recordingHotkey
                                                ? CupertinoIcons.keyboard
                                                : CupertinoIcons.command,
                                            size: 12,
                                            color: _recordingHotkey
                                                ? MacPalette.accent
                                                : MacPalette.textSecondary,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            _recordingHotkey
                                                ? '按下组合键...'
                                                : c.windowService.hotkeyLabel,
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                              fontFamily: 'Menlo',
                                              color: _recordingHotkey
                                                  ? MacPalette.accent
                                                  : MacPalette.textPrimary,
                                            ),
                                          ),
                                          if (!_recordingHotkey) ...[
                                            const SizedBox(width: 6),
                                            Text(
                                              '点击修改',
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: MacPalette.textTertiary,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (_hotkeyHint != null) ...[
                              const SizedBox(height: 6),
                              Text(
                                _hotkeyHint!,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: _recordingHotkey
                                      ? MacPalette.accent
                                      : MacPalette.textSecondary,
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final (label, key, modifiers) in isWindows
                                    ? const [
                                        ('Alt+Shift+D', 0x44, ['option', 'shift']),
                                        ('Ctrl+Alt+D', 0x44, ['control', 'option']),
                                        ('Ctrl+Shift+D', 0x44, ['control', 'shift']),
                                        ('Ctrl+Shift+X', 0x58, ['control', 'shift']),
                                      ]
                                    : const [
                                        ('⌥⇧D', 2, ['option', 'shift']),
                                        ('⌃⌥D', 2, ['control', 'option']),
                                        ('⌃⇧D', 2, ['control', 'shift']),
                                        ('⌘⇧X', 7, ['command', 'shift']),
                                      ])
                                  _hotkeyPresetChip(
                                    label: label,
                                    active: c.windowService.hotkeyLabel == label,
                                    onTap: () => _applyHotkeyPreset(label, key, modifiers),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(9),
                              decoration: BoxDecoration(
                                color: c.windowService.hasGlobalHotkeyPermission
                                    ? MacPalette.green.withValues(alpha: 0.1)
                                    : MacPalette.amber.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: c.windowService.hasGlobalHotkeyPermission
                                      ? MacPalette.green.withValues(alpha: 0.3)
                                      : MacPalette.amber.withValues(alpha: 0.35),
                                  width: 0.6,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: c.windowService
                                                  .hasGlobalHotkeyPermission
                                              ? MacPalette.green
                                              : MacPalette.amber,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          c.windowService
                                                  .hasGlobalHotkeyPermission
                                              ? '全局监听已就绪 · 任意应用按 ${c.windowService.hotkeyLabel} 即可呼出'
                                              : isWindows
                                                  ? '全局快捷键可能已被占用，请换一个组合键'
                                                  : '需要开启 macOS「辅助功能」权限才能在其他应用下响应全局快捷键',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            color: MacPalette.textPrimary,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (!isWindows &&
                                      !c.windowService.hasGlobalHotkeyPermission) ...[
                                    const SizedBox(height: 7),
                                    Row(
                                      children: [
                                        SizedBox(
                                          height: 25,
                                          child: FilledButton(
                                            onPressed: () => c.windowService
                                                .requestAccessibilityPermission(),
                                            style: FilledButton.styleFrom(
                                              backgroundColor:
                                                  MacPalette.textPrimary,
                                              foregroundColor:
                                                  MacPalette.onTextPrimary,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 10,
                                              ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                            ),
                                            child: const Text(
                                              '前往开启辅助功能',
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        SizedBox(
                                          height: 25,
                                          child: OutlinedButton(
                                            onPressed: () async {
                                              await c.windowService
                                                  .refreshSystemSettings();
                                              if (c.windowService
                                                  .hasGlobalHotkeyPermission) {
                                                c.setBanner('已检测到权限，全局快捷键立即生效');
                                              } else {
                                                c.setBanner(
                                                  '尚未检测到权限，请在系统设置中勾选 dropdrawer_app',
                                                );
                                              }
                                            },
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor:
                                                  MacPalette.textSecondary,
                                              side: BorderSide(
                                                color: MacPalette.hairline,
                                                width: 0.7,
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 9,
                                              ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                            ),
                                            child: const Text(
                                              '重新检测',
                                              style: TextStyle(fontSize: 10.5),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    const Divider(height: 0.5, thickness: 0.5, indent: 12),
                    _SwitchRow(
                      title: isWindows ? '在任务栏显示抽屉' : '在程序坞 (Dock) 显示图标',
                      subtitle: isWindows
                          ? '关闭时可通过系统托盘打开抽屉'
                          : '关闭时仅常驻顶部菜单栏，开启后同时在 Dock 显示',
                      value: c.windowService.showDockIcon,
                      onChanged: (v) => c.windowService.setShowDockIcon(v),
                    ),
                    if (isWindows) ...[
                      const Divider(height: 0.5, thickness: 0.5, indent: 12),
                      _SwitchRow(
                        title: '毛玻璃背景',
                        subtitle: c.windowService.windowsBackdropEnabled &&
                                !c.windowService.windowsBackdrop
                            ? '当前系统不支持（需 Windows 11 22H2 及以上），已使用不透明背景'
                            : '使用 Windows 11 的 Mica / 亚克力效果；如背景显示异常可关闭',
                        value: c.windowService.windowsBackdropEnabled,
                        onChanged: (v) async {
                          await c.windowService.setWindowsBackdrop(v);
                          if (mounted) setState(() {});
                        },
                      ),
                    ],
                    const Divider(height: 0.5, thickness: 0.5, indent: 12),
                    _SwitchRow(
                      title: '开机自动启动',
                      subtitle: isWindows
                          ? '登录 Windows 时自动驻留系统托盘'
                          : '登录 macOS 时自动静默驻留状态栏与屏幕边缘',
                      value: c.windowService.launchAtLogin,
                      onChanged: (v) async {
                        final ok = await c.windowService.setLaunchAtLogin(v);
                        c.setBanner(
                          ok
                              ? (v ? '已开启开机自启动' : '已关闭开机自启动')
                              : '修改开机自启动失败',
                        );
                      },
                    ),
                  ],
                ),
              ],
              // Rarely needed, so last: the version and updates.
              const SizedBox(height: 16),
              const _SectionLabel('关于与更新'),
              const SizedBox(height: 6),
              _GroupBox(
                children: [
                  UpdateSettings(
                    updates: c.updates,
                    mobile: c.windowService.isMobile,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _hotkeyPresetChip({
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: active
                ? MacPalette.fill(0.16)
                : MacPalette.fill(0.05),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? MacPalette.strongHairline : MacPalette.hairline,
              width: 0.6,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontFamily: 'Menlo',
              color: active ? MacPalette.textPrimary : MacPalette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w500,
        color: MacPalette.textSecondary,
      ),
    );
  }
}

class _GroupBox extends StatelessWidget {
  final List<Widget> children;
  const _GroupBox({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: MacPalette.group(0.22),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: MacPalette.hairline, width: 0.7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: MacPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: MacPalette.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AdaptiveSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
