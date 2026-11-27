import 'dart:async';

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
    unawaited(widget.controller.refreshAccountInfo());
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

  Future<void> _runWithModalGuard(Future<void> Function() action) async {
    await widget.controller.windowService.setModalOpen(true);
    try {
      await action();
    } finally {
      await widget.controller.windowService.setModalOpen(false);
    }
  }

  Future<void> _openChangePasswordDialog() async {
    final c = widget.controller;
    final hasPassword = c.accountInfo?.hasPassword ?? true;
    await _runWithModalGuard(() async {
      final changed = await showDialog<bool>(
        context: context,
        builder: (ctx) => _ChangePasswordDialog(
          controller: c,
          hasPassword: hasPassword,
        ),
      );
      if (changed == true && mounted) {
        c.setBanner(hasPassword ? l10n.passwordUpdated : l10n.passwordSetSuccess);
      }
    });
  }

  Future<void> _openBindEmailDialog() async {
    final c = widget.controller;
    final initialEmail = c.accountInfo?.email ?? c.user?.email ?? '';
    await _runWithModalGuard(() async {
      final bound = await showDialog<bool>(
        context: context,
        builder: (ctx) => _BindEmailDialog(
          controller: c,
          initialEmail: initialEmail,
        ),
      );
      if (bound == true && mounted) {
        c.setBanner(l10n.emailBoundSuccess);
      }
    });
  }

  Future<void> _openDeleteAccountDialog() async {
    final c = widget.controller;
    final info = c.accountInfo;
    final username = info?.username ?? c.user?.username ?? '';
    final hasPassword = info?.hasPassword ?? true;
    await _runWithModalGuard(() async {
      final deleted = await showDialog<bool>(
        context: context,
        builder: (ctx) => _DeleteAccountDialog(
          controller: c,
          username: username,
          hasPassword: hasPassword,
        ),
      );
      if (deleted == true && mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    });
  }

  /// Phones: iOS Settings / Material 3 settings rows; each choice opens its
  /// own list, and explanations sit under the groups.
  Widget _buildPhoneBody(DropDrawerController c) {
    final thresholdMb = c.autoCloudThresholdBytes ~/ (1024 * 1024);
    final threshold = [10, 20, 50, 100].contains(thresholdMb) ? thresholdMb : 20;
    final policyFooter =
        l10n.smartSendsSmallFilesToThe;
    final isIosDefaultDir = c.windowService.isIOS && c.customDownloadDir == null;
    final info = c.accountInfo;
    final username = info?.username ?? c.user?.username;
    final email = info?.email ?? c.user?.email;
    final hasEmail = email != null && email.isNotEmpty;
    final hasPassword = info?.hasPassword ?? true;
    final emailBindingAvailable = info?.emailBindingAvailable ?? false;
    final googleLinked = info?.googleLinked ?? false;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        if (username != null)
          PhoneSection(
            header: l10n.accountSecurity,
            footer: l10n.accountSectionFooter,
            children: [
              PhoneRow(
                title: l10n.currentAccount,
                value: username,
                subtitle: googleLinked ? l10n.googleAccountLinked : null,
                chevron: false,
              ),
              PhoneRow(
                title: hasEmail && emailBindingAvailable
                    ? l10n.changeEmail
                    : (emailBindingAvailable ? l10n.bindEmail : l10n.boundEmail),
                value: hasEmail ? email : l10n.emailNotBound,
                subtitle: hasEmail && (info?.emailVerified ?? false)
                    ? l10n.emailVerifiedTag
                    : (emailBindingAvailable ? l10n.bindEmailSubtitle : null),
                chevron: emailBindingAvailable,
                onTap: emailBindingAvailable ? _openBindEmailDialog : null,
              ),
              PhoneRow(
                title: hasPassword ? l10n.changePassword : l10n.setPassword,
                subtitle: hasPassword
                    ? l10n.changePasswordSubtitle
                    : l10n.setPasswordSubtitle,
                onTap: _openChangePasswordDialog,
              ),
              PhoneRow(
                title: l10n.deleteAccount,
                subtitle: l10n.deleteAccountSubtitle,
                destructive: true,
                chevron: false,
                onTap: _openDeleteAccountDialog,
              ),
            ],
          ),
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
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final c = widget.controller;
    final isWindows = c.windowService.isWindows;
    final thresholdMb = c.autoCloudThresholdBytes ~/ (1024 * 1024);
    if (UiDensity.isTouch(context)) {
      return PhonePage(title: l10n.preferences, body: _buildPhoneBody(c));
    }
    final info = c.accountInfo;
    final username = info?.username ?? c.user?.username;
    final email = info?.email ?? c.user?.email;
    final hasEmail = email != null && email.isNotEmpty;
    final hasPassword = info?.hasPassword ?? true;
    final emailBindingAvailable = info?.emailBindingAvailable ?? false;
    final googleLinked = info?.googleLinked ?? false;

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
                                Expanded(
                                  child: Text(
                                    l10n.currentShortcut,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: MacPalette.textSecondary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  flex: 2,
                                  child: GestureDetector(
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
                                          borderRadius:
                                              BorderRadius.circular(7),
                                          border: Border.all(
                                            color: _recordingHotkey
                                                ? MacPalette.accent
                                                : MacPalette.strongHairline,
                                            width:
                                                _recordingHotkey ? 1.0 : 0.7,
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
                                            Flexible(
                                              child: Text(
                                                _recordingHotkey
                                                    ? l10n.pressAKeyCombination
                                                    : c.windowService
                                                        .hotkeyLabel,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w600,
                                                  fontFamily: 'Menlo',
                                                  color: _recordingHotkey
                                                      ? MacPalette.accent
                                                      : MacPalette.textPrimary,
                                                ),
                                              ),
                                            ),
                                            if (!_recordingHotkey) ...[
                                              const SizedBox(width: 6),
                                              Flexible(
                                                child: Text(
                                                  l10n.clickToChange,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    color:
                                                        MacPalette.textTertiary,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
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
              // Rarely needed, so last: account security, then version and updates.
              if (username != null) ...[
                const SizedBox(height: 16),
                _SectionLabel(l10n.accountSecurity),
                const SizedBox(height: 6),
                _GroupBox(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  username,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: MacPalette.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  hasEmail
                                      ? (info?.emailVerified == true
                                          ? '$email · ${l10n.emailVerifiedTag}'
                                          : email)
                                      : l10n.emailNotBound,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: MacPalette.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (googleLinked) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: MacPalette.fill(0.08),
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(
                                  color: MacPalette.hairline,
                                  width: 0.6,
                                ),
                              ),
                              child: Text(
                                l10n.googleAccountLinked,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: MacPalette.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const Divider(height: 0.5, thickness: 0.5, indent: 12),
                    _AccountActionRow(
                      title: hasPassword
                          ? l10n.changePassword
                          : l10n.setPassword,
                      subtitle: hasPassword
                          ? l10n.changePasswordSubtitle
                          : l10n.setPasswordSubtitle,
                      buttonLabel: hasPassword
                          ? l10n.changePassword
                          : l10n.setPassword,
                      onPressed: _openChangePasswordDialog,
                    ),
                    if (emailBindingAvailable) ...[
                      const Divider(height: 0.5, thickness: 0.5, indent: 12),
                      _AccountActionRow(
                        title: hasEmail ? l10n.changeEmail : l10n.bindEmail,
                        subtitle: l10n.bindEmailSubtitle,
                        buttonLabel:
                            hasEmail ? l10n.changeEmail : l10n.bindEmail,
                        onPressed: _openBindEmailDialog,
                      ),
                    ],
                    const Divider(height: 0.5, thickness: 0.5, indent: 12),
                    _AccountActionRow(
                      title: l10n.deleteAccount,
                      subtitle: l10n.deleteAccountSubtitle,
                      buttonLabel: l10n.deleteAccount,
                      destructive: true,
                      onPressed: _openDeleteAccountDialog,
                    ),
                  ],
                ),
              ],
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

class _AccountActionRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final String buttonLabel;
  final bool destructive;
  final VoidCallback onPressed;

  const _AccountActionRow({
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    this.destructive = false,
    required this.onPressed,
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
                    color: destructive ? MacPalette.red : MacPalette.textPrimary,
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
          SizedBox(
            height: 26,
            child: OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor:
                    destructive ? MacPalette.red : MacPalette.textPrimary,
                side: BorderSide(
                  color: destructive
                      ? MacPalette.red.withValues(alpha: 0.45)
                      : MacPalette.strongHairline,
                  width: 0.7,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              child: Text(
                buttonLabel,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _friendlyError(Object e) =>
    e.toString().replaceFirst(RegExp(r'^(HttpException|Exception):\s*'), '');

class _ChangePasswordDialog extends StatefulWidget {
  final DropDrawerController controller;
  final bool hasPassword;

  const _ChangePasswordDialog({
    required this.controller,
    required this.hasPassword,
  });

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _currentCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final current = _currentCtrl.text;
    final next = _newCtrl.text;
    final confirm = _confirmCtrl.text;
    if (widget.hasPassword && current.isEmpty) {
      setState(() => _error = l10n.currentPassword);
      return;
    }
    if (next.length < 6) {
      setState(() => _error = l10n.newPasswordHint);
      return;
    }
    if (next != confirm) {
      setState(() => _error = l10n.passwordsDoNotMatch);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.controller.changeOwnPassword(
        currentPassword: widget.hasPassword ? current : null,
        newPassword: next,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = _friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: MacPalette.elevatedBg,
      title: Text(
        widget.hasPassword ? l10n.changePassword : l10n.setPassword,
        style: TextStyle(color: MacPalette.textPrimary, fontSize: 16),
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.hasPassword) ...[
                TextField(
                  controller: _currentCtrl,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l10n.currentPassword,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: _newCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.newPassword,
                  hintText: l10n.newPasswordHint,
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _confirmCtrl,
                obscureText: true,
                onSubmitted: (_) => _submitting ? null : _submit(),
                decoration: InputDecoration(
                  labelText: l10n.confirmNewPassword,
                  isDense: true,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(color: MacPalette.red, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.save),
        ),
      ],
    );
  }
}

class _BindEmailDialog extends StatefulWidget {
  final DropDrawerController controller;
  final String initialEmail;

  const _BindEmailDialog({
    required this.controller,
    required this.initialEmail,
  });

  @override
  State<_BindEmailDialog> createState() => _BindEmailDialogState();
}

class _BindEmailDialogState extends State<_BindEmailDialog> {
  late final TextEditingController _emailCtrl =
      TextEditingController(text: widget.initialEmail);
  final _codeCtrl = TextEditingController();
  Timer? _cooldownTimer;
  int _cooldownSeconds = 0;
  bool _sending = false;
  bool _submitting = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldownSeconds = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _cooldownSeconds <= 1) {
        timer.cancel();
        if (mounted) setState(() => _cooldownSeconds = 0);
      } else {
        setState(() => _cooldownSeconds--);
      }
    });
  }

  Future<void> _sendCode() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => _error = l10n.emailAddressLabel);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
      _info = null;
    });
    try {
      await widget.controller.sendBindEmailCode(email);
      if (!mounted) return;
      _startCooldown();
      setState(() {
        _sending = false;
        _info = l10n.verificationCodeSent;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = _friendlyError(e);
        });
      }
    }
  }

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    if (email.isEmpty || code.isEmpty) {
      setState(() => _error = l10n.verificationCodeLabel);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.controller.confirmBindEmail(email: email, code: code);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = _friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasInitial = widget.initialEmail.isNotEmpty;
    return AlertDialog(
      backgroundColor: MacPalette.elevatedBg,
      title: Text(
        hasInitial ? l10n.changeEmail : l10n.bindEmail,
        style: TextStyle(color: MacPalette.textPrimary, fontSize: 16),
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: l10n.emailAddressLabel,
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _codeCtrl,
                      keyboardType: TextInputType.number,
                      onSubmitted: (_) => _submitting ? null : _submit(),
                      decoration: InputDecoration(
                        labelText: l10n.verificationCodeLabel,
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: (_sending || _cooldownSeconds > 0)
                        ? null
                        : _sendCode,
                    child: Text(
                      _cooldownSeconds > 0
                          ? l10n.resendCodeCountdown(_cooldownSeconds)
                          : l10n.sendCode,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              if (_info != null) ...[
                const SizedBox(height: 10),
                Text(
                  _info!,
                  style: TextStyle(color: MacPalette.green, fontSize: 12),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(color: MacPalette.red, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.save),
        ),
      ],
    );
  }
}

class _DeleteAccountDialog extends StatefulWidget {
  final DropDrawerController controller;
  final String username;
  final bool hasPassword;

  const _DeleteAccountDialog({
    required this.controller,
    required this.username,
    required this.hasPassword,
  });

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _inputCtrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  bool get _canSubmit {
    if (_submitting) return false;
    final val = _inputCtrl.text.trim();
    if (widget.hasPassword) return _inputCtrl.text.isNotEmpty;
    return val == widget.username && widget.username.isNotEmpty;
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.controller.deleteOwnAccount(
        password: widget.hasPassword ? _inputCtrl.text : null,
        confirmUsername: widget.hasPassword ? null : _inputCtrl.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = _friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: MacPalette.elevatedBg,
      title: Text(
        l10n.deleteAccount,
        style: TextStyle(color: MacPalette.red, fontSize: 16),
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: MacPalette.red.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: MacPalette.red.withValues(alpha: 0.35),
                    width: 0.7,
                  ),
                ),
                child: Text(
                  l10n.deleteAccountWarning,
                  style: TextStyle(
                    fontSize: 12,
                    color: MacPalette.textPrimary,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _inputCtrl,
                obscureText: widget.hasPassword,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _canSubmit ? _submit() : null,
                decoration: InputDecoration(
                  labelText: widget.hasPassword
                      ? l10n.enterPasswordToDelete
                      : l10n.enterUsernameToDelete(widget.username),
                  isDense: true,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(color: MacPalette.red, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          style: FilledButton.styleFrom(
            backgroundColor: MacPalette.red,
            foregroundColor: MacPalette.onAccent,
          ),
          child: _submitting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.confirmDeleteAccount),
        ),
      ],
    );
  }
}
