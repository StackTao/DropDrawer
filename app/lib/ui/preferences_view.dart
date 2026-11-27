import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/drawer_controller.dart';
import 'phone_page.dart';
import 'theme.dart';
import 'update_settings.dart';
import '../l10n/l10n.dart';

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
          ? l10n.pressACombinationThatIncludesCtrl
          : l10n.pressAKeyCombinationItMust;
    });
    final res = await widget.controller.windowService.recordHotkeyNative();
    if (!mounted) return;
    final recorded = res['recorded'] as bool? ?? false;
    final ok = res['ok'] as bool? ?? true;
    final label = res['label'] as String? ?? widget.controller.windowService.hotkeyLabel;
    setState(() {
      _recordingHotkey = false;
      if (recorded) {
        _hotkeyHint = ok ? l10n.hotkeyActive(label) : l10n.hotkeyTakenChooseAnother(label);
      } else {
        _hotkeyHint = null;
      }
    });
    if (recorded && ok) {
      widget.controller.setBanner(l10n.hotkeyUpdatedTo(label));
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
      _hotkeyHint = ok ? l10n.hotkeyActive(label) : l10n.hotkeyTakenTryAnother(label);
    });
    if (ok) {
      widget.controller.setBanner(l10n.hotkeySetTo(label));
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

  static List<(AppLanguage, String)> get _languages => [
        (AppLanguage.system, l10n.languageSystem),
        // Language names are shown in their own language.
        (AppLanguage.chinese, '简体中文'),
        (AppLanguage.english, 'English'),
      ];

  Future<void> _setLanguage(AppLanguage language) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppLocale.prefsKey, language.id);
    } catch (_) {}
    AppLocale.apply(language);
    if (mounted) setState(() {});
  }

  static List<(String, String)> get _policies => [
    ('smart', l10n.smart),
    ('p2p_only', l10n.p2pOnly),
    ('cloud_cached', l10n.saveToCloudShort),
  ];
  static List<(int, String)> get _ttls => [
    (0, l10n.serverDefault),
    (24, l10n.n24Hours),
    (168, l10n.n7Days),
    (720, l10n.n30Days),
  ];
  static const _thresholds = [
    (10, '10 MB'),
    (20, '20 MB'),
    (50, '50 MB'),
    (100, '100 MB'),
  ];

  /// Keep the server default available and limit explicit presets to the cap.
  static List<(int, String)> _ttlOptions(int? cap) {
    if (cap == null || cap <= 0) return _ttls;
    final options = _ttls.where((o) => o.$1 <= cap).toList();
    if (!options.any((o) => o.$1 == cap)) {
      options.add((cap, l10n.valueAtCap(cap % 24 == 0 ? l10n.daysCount(cap ~/ 24) : l10n.hoursCount(cap))));
    }
    return options;
  }

  /// The stored preference, shown as the cap when it exceeds it.
  static int _ttlValue(List<(int, String)> options, int value, int? cap) =>
      options.any((o) => o.$1 == value) ? value : (cap ?? value);

  static String _label<T>(List<(T, String)> options, T value) =>
      options.where((o) => o.$1 == value).firstOrNull?.$2 ?? '$value';

  Future<void> _choose<T>(
    String title,
    List<(T, String)> options,
    T selected,
    ValueChanged<T> onChanged, {
    String? footer,
  }) async {
    final value = await showPhoneChoice<T>(
      context,
      title: title,
      options: options,
      selected: selected,
      footer: footer,
      previousTitle: l10n.preferences,
    );
    if (value != null && value != selected) onChanged(value);
  }

  /// Phones: iOS Settings / Material 3 settings rows; each choice opens its
  /// own list, and explanations sit under the groups.
  Widget _buildPhoneBody(DropDrawerController c) {
    final thresholdMb = c.autoCloudThresholdBytes ~/ (1024 * 1024);
    final threshold = [10, 20, 50, 100].contains(thresholdMb) ? thresholdMb : 20;
    final policyFooter =
        l10n.smartSendsSmallFilesToThe;
    final isIosDefaultDir = c.windowService.isIOS && c.customDownloadDir == null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        PhoneSection(
          header: l10n.general,
          footer: l10n.languageFooter,
          children: [
            PhoneRow(
              title: l10n.language,
              value: _label(_languages, AppLocale.preference),
              onTap: () => _choose(
                l10n.language,
                _languages,
                AppLocale.preference,
                _setLanguage,
                footer: l10n.languageFooter,
              ),
            ),
          ],
        ),
        PhoneSection(
          header: l10n.transfer,
          footer: policyFooter,
          children: [
            PhoneRow(
              title: l10n.transferPolicyForNewFiles,
              value: _label(_policies, c.defaultDropPolicy),
              onTap: () => _choose(
                l10n.transferPolicy,
                _policies,
                c.defaultDropPolicy,
                c.setDropPolicy,
                footer: policyFooter,
              ),
            ),
            PhoneRow(
              title: l10n.smartModeCloudThreshold,
              value: _label(_thresholds, threshold),
              onTap: () => _choose(
                l10n.cloudThreshold,
                _thresholds,
                threshold,
                c.setAutoCloudThresholdMb,
                footer: l10n.inSmartModeFilesSmallerThan,
              ),
            ),
          ],
        ),
        PhoneSection(
          header: l10n.autoCleanup,
          footer: l10n.expiredItemsAreRemovedFromThe,
          children: [
            PhoneRow(
              title: l10n.defaultExpiration,
              value: _label(
                _ttlOptions(c.maxItemTtlHours),
                _ttlValue(_ttlOptions(c.maxItemTtlHours), c.defaultTtlHours, c.maxItemTtlHours),
              ),
              onTap: () => _choose(
                l10n.expiration,
                _ttlOptions(c.maxItemTtlHours),
                _ttlValue(_ttlOptions(c.maxItemTtlHours), c.defaultTtlHours, c.maxItemTtlHours),
                c.setDefaultTtlHours,
              ),
            ),
          ],
        ),
        PhoneSection(
          header: l10n.downloads,
          children: [
            if (isIosDefaultDir)
              PhoneRow(
                title: l10n.saveLocation,
                value: l10n.filesDropdrawer,
              )
            else
              PhoneRow(
                title: l10n.saveLocation,
                subtitle: _effectiveDir.isEmpty ? l10n.loading : _effectiveDir,
              ),
            if (c.customDownloadDir != null)
              PhoneRow(
                title: l10n.restoreDefaultLocation,
                action: true,
                onTap: () async {
                  await c.setCustomDownloadDir(null);
                  await _loadDir();
                },
              ),
          ],
        ),
        UpdateSettings(updates: c.updates, mobile: true),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final isWindows = c.windowService.isWindows;
    final thresholdMb = c.autoCloudThresholdBytes ~/ (1024 * 1024);
    if (UiDensity.isTouch(context)) {
      return PhonePage(title: l10n.preferences, body: _buildPhoneBody(c));
    }

    return AdaptivePage(
      title: l10n.preferences,
      desktopHeader: Padding(
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
                  tooltip: l10n.backToDrawer,
                  size: 15,
                  onPressed: widget.onBack,
                ),
                const SizedBox(width: 4),
                Text(
                  l10n.preferences,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      body: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              _SectionLabel(l10n.general),
              const SizedBox(height: 6),
              _GroupBox(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.language,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: MacPalette.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.languageFooter,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: MacPalette.textTertiary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        MacSegmentedControl<AppLanguage>(
                          selected: AppLocale.preference,
                          items: _languages,
                          onChanged: _setLanguage,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SectionLabel(l10n.transfersAutoCleanup),
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
                          l10n.transferPolicyForNewFiles,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: MacPalette.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.smartSmallFilesAlsoGoTo,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: MacPalette.textTertiary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        MacSegmentedControl<String>(
                          selected: c.defaultDropPolicy,
                          items: [
                            ('smart', l10n.smart),
                            ('p2p_only', l10n.p2pOnly),
                            ('cloud_cached', l10n.saveToCloudShort),
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
                          l10n.defaultExpirationCleanup,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: MacPalette.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.newFilesAndTextAreRemoved,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: MacPalette.textTertiary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        MacSegmentedControl<int>(
                          selected: _ttlValue(
                            _ttlOptions(c.maxItemTtlHours),
                            c.defaultTtlHours,
                            c.maxItemTtlHours,
                          ),
                          items: _ttlOptions(c.maxItemTtlHours),
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
                          l10n.smartModeAutoUploadThreshold,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: MacPalette.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.filesSmallerThanThisAreCached,
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
                              l10n.defaultDownloadFolder,
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
                                    l10n.restoreDefault,
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
                          _effectiveDir.isEmpty ? l10n.loadingDots : _effectiveDir,
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
                                    child: Text(
                                      l10n.changeFolder,
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
                                  child: Text(
                                    l10n.open,
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
                _SectionLabel(isWindows ? l10n.windowWindowsIntegration : l10n.windowMacosIntegration),
                const SizedBox(height: 6),
                _GroupBox(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.drawerEdge,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: MacPalette.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            l10n.youCanAlsoDragTheEdge,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: MacPalette.textTertiary,
                            ),
                          ),
                          const SizedBox(height: 8),
                          MacSegmentedControl<String>(
                            selected: c.windowService.dockSide,
                            items: [
                              ('left', l10n.leftSideOfTheScreen),
                              ('right', l10n.rightSideOfTheScreen),
                            ],
                            onChanged: (side) =>
                                c.windowService.setDockSide(side),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 0.5, thickness: 0.5, indent: 12),
                    _SwitchRow(
                      title: l10n.globalShortcutToOpenTheDrawer,
                      subtitle: l10n.opensOrClosesTheDrawerFrom,
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
                                  l10n.currentShortcut,
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
                                                ? l10n.pressAKeyCombination
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
                                              l10n.clickToChange,
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
                                              ? l10n.hotkeyReady(c.windowService.hotkeyLabel)
                                              : isWindows
                                                  ? l10n.theGlobalShortcutMayAlreadyBe
                                                  : l10n.dropdrawerNeedsMacosAccessibilityPermissionTo,
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
                                            child: Text(
                                              l10n.openAccessibilitySettings,
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
                                                c.setBanner(l10n.permissionGrantedTheGlobalShortcutWorks);
                                              } else {
                                                c.setBanner(
                                                  l10n.permissionNotDetectedYetEnableDropdrawer,
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
                                            child: Text(
                                              l10n.checkAgain,
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
                      title: isWindows ? l10n.showTheDrawerInTheTaskbar : l10n.showIconInTheDock,
                      subtitle: isWindows
                          ? l10n.whenOffOpenTheDrawerFrom
                          : l10n.whenOffDropdrawerStaysInThe,
                      value: c.windowService.showDockIcon,
                      onChanged: (v) => c.windowService.setShowDockIcon(v),
                    ),
                    if (isWindows) ...[
                      const Divider(height: 0.5, thickness: 0.5, indent: 12),
                      _SwitchRow(
                        title: l10n.translucentBackground,
                        subtitle: c.windowService.windowsBackdropEnabled &&
                                !c.windowService.windowsBackdrop
                            ? l10n.notSupportedOnThisSystemRequires
                            : l10n.usesTheWindows11MicaAcrylic,
                        value: c.windowService.windowsBackdropEnabled,
                        onChanged: (v) async {
                          await c.windowService.setWindowsBackdrop(v);
                          if (mounted) setState(() {});
                        },
                      ),
                    ],
                    const Divider(height: 0.5, thickness: 0.5, indent: 12),
                    _SwitchRow(
                      title: l10n.launchAtLogin,
                      subtitle: isWindows
                          ? l10n.staysInTheSystemTrayWhen
                          : l10n.runsQuietlyInTheMenuBar,
                      value: c.windowService.launchAtLogin,
                      onChanged: (v) async {
                        final ok = await c.windowService.setLaunchAtLogin(v);
                        c.setBanner(
                          ok
                              ? (v ? l10n.launchAtLoginTurnedOn : l10n.launchAtLoginTurnedOff)
                              : l10n.couldnTChangeLaunchAtLogin,
                        );
                      },
                    ),
                  ],
                ),
              ],
              // Rarely needed, so last: the version and updates.
              const SizedBox(height: 16),
              _SectionLabel(l10n.aboutUpdates),
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
