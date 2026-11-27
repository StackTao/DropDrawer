import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../state/drawer_controller.dart';
import 'phone_page.dart';
import 'theme.dart';
import '../l10n/l10n.dart';

class ShareView extends StatefulWidget {
  final DropDrawerController controller;
  final List<DrawerItem> targetItems;
  final VoidCallback onBack;

  const ShareView({
    super.key,
    required this.controller,
    this.targetItems = const [],
    required this.onBack,
  });

  @override
  State<ShareView> createState() => _ShareViewState();
}

class _ShareViewState extends State<ShareView> {
  final _titleCtrl = TextEditingController();
  final _passcodeCtrl = TextEditingController();

  /// 0 means permanent (no expiration)
  int _expiresHours = 24;

  /// 0 means unlimited downloads
  int _maxDownloads = 0;

  bool _creating = false;
  bool _loadingList = false;
  String? _error;
  ShareLinkInfo? _justCreated;
  String? _justCreatedPasscode;

  @override
  void initState() {
    super.initState();
    _refreshList();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _passcodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshList() async {
    setState(() => _loadingList = true);
    try {
      await widget.controller.refreshShareLinks();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  void _generateRandomPasscode() {
    const chars = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final rand = Random.secure();
    final code =
        List.generate(4, (_) => chars[rand.nextInt(chars.length)]).join();
    setState(() => _passcodeCtrl.text = code);
  }

  String _formatCopyText(ShareLinkInfo link, {String? plainPasscode}) {
    final url = widget.controller.buildFullShareUrl(link.sharePath);
    if (plainPasscode != null && plainPasscode.isNotEmpty) {
      return l10n.shareClipboardText(url, plainPasscode);
    }
    return url;
  }

  Future<void> _createShare() async {
    if (widget.targetItems.isEmpty || _creating) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final pass = _passcodeCtrl.text.trim();
      final customTitle = _titleCtrl.text.trim();
      if (pass.isEmpty &&
          (widget.controller.clientConfig?.features.shareRequiresPasscode ?? false)) {
        throw StateError(l10n.thisServerRequiresAPasscodeFor);
      }
      final created = await widget.controller.createShareLinkForItems(
        widget.targetItems,
        title: customTitle.isEmpty ? null : customTitle,
        passcode: pass.isEmpty ? null : pass,
        expiresHours: _expiresHours > 0 ? _expiresHours : null,
        maxDownloads: _maxDownloads > 0 ? _maxDownloads : null,
      );
      final copyText = _formatCopyText(created, plainPasscode: pass);
      await Clipboard.setData(ClipboardData(text: copyText));
      if (mounted) {
        setState(() {
          _justCreated = created;
          _justCreatedPasscode = pass.isEmpty ? null : pass;
        });
      }
      widget.controller.setBanner(l10n.shareLinkCreatedAndCopiedTo);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    _clampChoices();
    final hasTargets = widget.targetItems.isNotEmpty;
    final isBundle = widget.targetItems.length > 1;

    final title = !hasTargets
        ? l10n.manageShareLinks
        : (isBundle
            ? l10n.createBundleLinkItems(widget.targetItems.length)
            : l10n.createShareLink);
    final phoneTitle = hasTargets
        ? (isBundle ? l10n.bundleLinkCount(widget.targetItems.length) : l10n.createShareLink2)
        : l10n.shareLinksTitle;
    final refresh = PageAction(
      icon: CupertinoIcons.refresh,
      tooltip: l10n.refreshShareLinks,
      onPressed: _loadingList ? null : _refreshList,
    );
    if (UiDensity.isTouch(context)) {
      return PhonePage(
        title: phoneTitle,
        actions: [refresh],
        body: NativeTypeScale(child: _buildPhoneBody(c)),
      );
    }
    return AdaptivePage(
      title: phoneTitle,
      actions: [refresh],
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
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                MacIconButton(
                  icon: CupertinoIcons.refresh,
                  tooltip: l10n.refreshShareLinks,
                  size: 13.5,
                  onPressed: _loadingList ? null : _refreshList,
                ),
              ],
            ),
          ),
        ),
      body: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              if (hasTargets && c.canCreateShares) ...[
                _buildCreateSection(c, widget.targetItems),
                const SizedBox(height: 16),
              ] else if (hasTargets) ...[
                Text(
                  l10n.shareLinksAreTurnedOffOn2,
                  style: TextStyle(fontSize: 12.5, color: MacPalette.amber),
                ),
                const SizedBox(height: 16),
              ],
              Row(
                children: [
                  Text(
                    l10n.createdLinksCount(c.shareLinks.length),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: MacPalette.textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  if (_loadingList)
                    SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: MacPalette.textSecondary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (c.shareLinks.isEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 20,
                  ),
                  decoration: BoxDecoration(
                    color: MacPalette.group(0.2),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: MacPalette.hairline, width: 0.7),
                  ),
                  child: Text(
                    l10n.noShareLinksYetNclickAn,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: MacPalette.textTertiary,
                    ),
                  ),
                )
              else
                ...c.shareLinks.map((link) => Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: _buildShareCard(c, link),
                    )),
            ],
          ),
    );
  }

  static List<(int, String)> get _baseExpiryOptions => [
    (1, l10n.n1Hour),
    (24, l10n.n24Hours),
    (168, l10n.n7Days),
    (0, l10n.forever),
  ];
  static List<(int, String)> get _baseDownloadOptions => [
    (0, l10n.unlimited),
    (1, l10n.n1TimeBurnAfterReading),
    (5, l10n.n5Times),
    (20, l10n.n20Times),
  ];

  static String _hoursLabel(int h) => h % 24 == 0 ? l10n.daysCount(h ~/ 24) : l10n.hoursCountH(h);

  /// Applies an administrator cap: drops "unlimited" (0) and larger choices,
  /// and offers the cap itself when it is not one of the presets.
  static List<(int, String)> _capped(
    List<(int, String)> base,
    int? cap,
    String Function(int) label,
  ) {
    if (cap == null || cap <= 0) return base;
    final options = base.where((o) => o.$1 > 0 && o.$1 <= cap).toList();
    if (!options.any((o) => o.$1 == cap)) options.add((cap, label(cap)));
    return options;
  }

  List<(int, String)> get _expiryOptions => _capped(
        _baseExpiryOptions,
        widget.controller.maxShareExpiresHours,
        (h) => l10n.valueAtCap(_hoursLabel(h)),
      );
  List<(int, String)> get _downloadOptions => _capped(
        _baseDownloadOptions,
        widget.controller.maxShareDownloads,
        (n) => l10n.timesAtCap(n),
      );

  /// Keeps the selected values inside the administrator's caps.
  void _clampChoices() {
    final expiry = _expiryOptions;
    if (!expiry.any((o) => o.$1 == _expiresHours)) {
      final fallback = expiry.where((o) => o.$1 <= 24 && o.$1 > 0).lastOrNull ?? expiry.first;
      _expiresHours = fallback.$1;
    }
    final downloads = _downloadOptions;
    if (!downloads.any((o) => o.$1 == _maxDownloads)) _maxDownloads = downloads.last.$1;
  }

  static String _optionLabel(List<(int, String)> options, int value) =>
      options.where((o) => o.$1 == value).firstOrNull?.$2 ?? '$value';

  /// Phones: what is shared, the access settings and the created links as
  /// settings groups. Tapping a link offers copy, open and revoke.
  Widget _buildPhoneBody(DropDrawerController c) {
    final items = widget.targetItems;
    final material = usesMaterialChrome(context);
    final isBundle = items.length > 1;
    final pendingUploadCount =
        items.where((it) => it.kind == 'file' && !it.cloudReady).length;
    final totalBytes = items.fold<int>(0, (sum, it) => sum + it.size);

    Future<void> choose(
      String title,
      List<(int, String)> options,
      int selected,
      ValueChanged<int> onChanged,
    ) async {
      final value = await showPhoneChoice<int>(
        context,
        title: title,
        options: options,
        selected: selected,
        previousTitle: l10n.link,
      );
      if (value != null && mounted) setState(() => onChanged(value));
    }

    IconData itemIcon(DrawerItem item) => item.kind == 'text'
        ? (material ? Icons.notes : CupertinoIcons.text_quote)
        : (material ? Icons.insert_drive_file_outlined : CupertinoIcons.doc);

    final created = _justCreated;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      children: [
        if (items.isNotEmpty) ...[
          PhoneSection(
            header: isBundle ? l10n.bundleItemsSize(items.length, formatBytes(totalBytes)) : l10n.sharedContent,
            footer: pendingUploadCount > 0
                ? l10n.uploadBeforeShareNote(pendingUploadCount, c.defaultStorageBackendName)
                : l10n.anyoneWithTheLinkCanDownload,
            children: [
              for (final item in items.take(8))
                PhoneRow(
                  leading: Icon(itemIcon(item), size: 22, color: MacPalette.textSecondary),
                  title: item.name,
                  value: formatBytes(item.size),
                ),
              if (items.length > 8)
                PhoneRow(title: l10n.andMoreItems(items.length - 8), dimmed: true),
            ],
          ),
          if (isBundle)
            PhoneSection(
              header: l10n.bundleTitle,
              children: [
                PhoneFieldRow(
                  controller: _titleCtrl,
                  placeholder: l10n.firstNameAndMore(items.first.name, items.length),
                ),
              ],
            ),
          PhoneSection(
            header: l10n.access,
            footer: widget.controller.shareRequiresPasscode
                ? l10n.thisServerRequiresAPasscodeFor2
                : l10n.ifYouLeaveThePasscodeEmpty,
            children: [
              PhoneRow(
                title: l10n.expiresAfter,
                value: _optionLabel(_expiryOptions, _expiresHours),
                onTap: () => choose(l10n.expiresAfter, _expiryOptions, _expiresHours,
                    (v) => _expiresHours = v),
              ),
              PhoneRow(
                title: l10n.downloads2,
                value: _optionLabel(_downloadOptions, _maxDownloads),
                onTap: () => choose(l10n.downloads2, _downloadOptions, _maxDownloads,
                    (v) => _maxDownloads = v),
              ),
              PhoneFieldRow(
                controller: _passcodeCtrl,
                label: widget.controller.shareRequiresPasscode ? l10n.passcodeRequired : l10n.passcode,
                placeholder: l10n.leaveEmptyForPublic,
                trailing: PhoneBarButton(
                  glass: false,
                  action: PageAction(
                    icon: material ? Icons.casino_outlined : CupertinoIcons.sparkles,
                    tooltip: l10n.generateA4CharacterPasscode,
                    onPressed: _generateRandomPasscode,
                  ),
                ),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 13, color: MacPalette.red),
              ),
            ),
          PhoneButton(
            label: _creating
                ? l10n.creating
                : (pendingUploadCount > 0
                    ? l10n.uploadAndCreateLink
                    : (isBundle ? l10n.createBundleLinkAndCopy : l10n.createLinkAndCopy)),
            onPressed: _creating ? null : _createShare,
          ),
          const SizedBox(height: 24),
          if (created != null)
            PhoneSection(
              header: l10n.createdAndCopiedToTheClipboard,
              children: [
                PhoneRow(
                  title: l10n.linkLabel,
                  subtitle: _formatCopyText(created, plainPasscode: _justCreatedPasscode),
                  selectable: true,
                ),
                PhoneRow(
                  title: l10n.copyAgain,
                  action: true,
                  onTap: () {
                    Clipboard.setData(ClipboardData(
                      text: _formatCopyText(created, plainPasscode: _justCreatedPasscode),
                    ));
                    c.setBanner(l10n.copiedLinkDetails);
                  },
                ),
                PhoneRow(
                  title: l10n.openInBrowser,
                  action: true,
                  onTap: () {
                    final base = c.buildFullShareUrl(created.sharePath);
                    final pass = _justCreatedPasscode;
                    c.windowService.openExternalUrl(
                      pass != null ? '$base?p=${Uri.encodeQueryComponent(pass)}' : base,
                    );
                  },
                ),
              ],
            ),
        ],
        PhoneSection(
          header: l10n.createdLinksCountFull(c.shareLinks.length),
          footer: c.shareLinks.isEmpty
              ? l10n.longPressOrOpenAnyItem
              : l10n.tapALinkToCopyOpen,
          children: [
            if (c.shareLinks.isEmpty)
              PhoneRow(
                title: _loadingList ? l10n.loadingEllipsis : l10n.noShareLinksYet,
                dimmed: true,
              )
            else
              for (final link in c.shareLinks) _buildPhoneLinkRow(c, link),
          ],
        ),
      ],
    );
  }

  Widget _buildPhoneLinkRow(DropDrawerController c, ShareLinkInfo link) {
    final material = usesMaterialChrome(context);
    final fullUrl = c.buildFullShareUrl(link.sharePath);
    final inactive = link.isExpired || link.isExhausted;
    final meta = <String>[
      if (link.itemCount > 1) l10n.bundleOfItems(link.itemCount),
      if (link.hasPasscode) l10n.passcodeRequired2,
      link.maxDownloads != null
          ? l10n.downloadedOfMax(link.downloadCount, link.maxDownloads!)
          : l10n.downloadedCount(link.downloadCount),
      if (link.isExpired)
        l10n.expired
      else if (link.isExhausted)
        l10n.downloadLimitReached
      else if (link.expiresAt != null)
        _formatRemaining(link.expiresAt!)
      else
        l10n.neverExpires2,
    ];
    return PhoneRow(
      leading: Icon(
        link.hasPasscode
            ? (material ? Icons.lock_outline : CupertinoIcons.lock)
            : (link.itemCount > 1
                ? (material ? Icons.collections_outlined : CupertinoIcons.collections)
                : (material ? Icons.link : CupertinoIcons.link)),
        size: 22,
        color: inactive ? MacPalette.textTertiary : MacPalette.accent,
      ),
      title: link.itemName,
      subtitle: meta.join(' · '),
      dimmed: inactive,
      onTap: () => showPhoneActions(
        context,
        title: link.itemName,
        message: fullUrl,
        entries: [
          PhoneMenuEntry(
            label: l10n.copyLink,
            icon: CupertinoIcons.doc_on_doc,
            materialIcon: Icons.content_copy,
            onSelected: () {
              Clipboard.setData(ClipboardData(text: fullUrl));
              c.setBanner(l10n.linkCopied);
            },
          ),
          PhoneMenuEntry(
            label: l10n.openInBrowser,
            icon: CupertinoIcons.globe,
            materialIcon: Icons.open_in_browser,
            onSelected: () => c.windowService.openExternalUrl(fullUrl),
          ),
          PhoneMenuEntry(
            label: l10n.revokeLink,
            icon: CupertinoIcons.trash,
            materialIcon: Icons.link_off,
            destructive: true,
            onSelected: () => c.revokeShareLink(link.code),
          ),
        ],
      ),
    );
  }

  Widget _buildCreateSection(
    DropDrawerController c,
    List<DrawerItem> items,
  ) {
    final isBundle = items.length > 1;
    final totalBytes = items.fold<int>(0, (sum, it) => sum + it.size);
    final pendingUploadCount =
        items.where((it) => it.kind == 'file' && !it.cloudReady).length;
    final primary = items.first;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MacPalette.group(0.24),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: MacPalette.hairline, width: 0.7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: MacPalette.fill(0.08),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(
                  isBundle
                      ? CupertinoIcons.collections_solid
                      : (primary.kind == 'text'
                          ? CupertinoIcons.text_quote
                          : CupertinoIcons.doc_fill),
                  size: 15,
                  color: MacPalette.textPrimary,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isBundle
                          ? l10n.primaryNameAndMore(primary.name, items.length)
                          : primary.name,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: MacPalette.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      pendingUploadCount > 0
                          ? l10n.sizeUploadBeforeShare(formatBytes(totalBytes), pendingUploadCount, c.defaultStorageBackendName)
                          : l10n.sizeReadyNoSignIn(formatBytes(totalBytes)),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: MacPalette.textTertiary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (isBundle) ...[
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 84),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                color: MacPalette.fill(0.04),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: MacPalette.hairline, width: 0.5),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 3),
                itemBuilder: (_, idx) {
                  final it = items[idx];
                  return Row(
                    children: [
                      Icon(
                        it.kind == 'text'
                            ? CupertinoIcons.text_quote
                            : CupertinoIcons.doc,
                        size: 11,
                        color: MacPalette.textTertiary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          it.name,
                          style: TextStyle(
                            fontSize: 11,
                            color: MacPalette.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        formatBytes(it.size),
                        style: TextStyle(
                          fontSize: 10,
                          color: MacPalette.textTertiary,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: MacPalette.fill(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: MacPalette.hairline, width: 0.6),
              ),
              child: MacFormField(
                controller: _titleCtrl,
                label: l10n.bundleTitle,
                placeholder: l10n.optionalDefaultTitle(primary.name, items.length),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            l10n.expiresAfter,
            style: TextStyle(fontSize: 11, color: MacPalette.textSecondary),
          ),
          const SizedBox(height: 5),
          MacSegmentedControl<int>(
            selected: _expiresHours,
            items: _expiryOptions,
            onChanged: (v) => setState(() => _expiresHours = v),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.downloadLimit,
            style: TextStyle(fontSize: 11, color: MacPalette.textSecondary),
          ),
          const SizedBox(height: 5),
          MacSegmentedControl<int>(
            selected: _maxDownloads,
            items: _downloadOptions
                .map((o) => o.$1 == 1 ? (1, l10n.oneTimeBurn) : o)
                .toList(),
            onChanged: (v) => setState(() => _maxDownloads = v),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: MacPalette.fill(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: MacPalette.hairline, width: 0.6),
            ),
            child: Row(
              children: [
                Expanded(
                  child: MacFormField(
                    controller: _passcodeCtrl,
                    label: widget.controller.shareRequiresPasscode ? l10n.passcodeRequired : l10n.passcode,
                    placeholder: l10n.leaveEmptyForPublicAccess,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: MacIconButton(
                    icon: CupertinoIcons.sparkles,
                    tooltip: l10n.generateA4CharacterPasscode,
                    size: 14,
                    onPressed: _generateRandomPasscode,
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(fontSize: 11, color: MacPalette.red),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
              height: 34,
              child: FilledButton(
                onPressed: _creating ? null : _createShare,
                style: FilledButton.styleFrom(
                  backgroundColor: MacPalette.textPrimary,
                  foregroundColor: MacPalette.onTextPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _creating
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: MacPalette.onTextPrimary,
                        ),
                      )
                    : Text(
                        pendingUploadCount > 0
                            ? l10n.uploadToCloudAndCreateLink
                            : (isBundle ? l10n.createBundleLinkAndCopy : l10n.createLinkAndCopy),
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
          if (_justCreated != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: MacPalette.green.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: MacPalette.green.withValues(alpha: 0.35),
                  width: 0.7,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        CupertinoIcons.checkmark_circle_fill,
                        size: 13,
                        color: MacPalette.green,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        l10n.createdAndCopiedToTheClipboard,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: MacPalette.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      MacIconButton(
                        icon: CupertinoIcons.doc_on_doc,
                        tooltip: l10n.copyLinkAgain,
                        size: 13.5,
                        onPressed: () {
                          Clipboard.setData(ClipboardData(
                            text: _formatCopyText(
                              _justCreated!,
                              plainPasscode: _justCreatedPasscode,
                            ),
                          ));
                          c.setBanner(l10n.copiedLinkDetails);
                        },
                      ),
                      MacIconButton(
                        icon: CupertinoIcons.globe,
                        tooltip: l10n.previewInBrowser,
                        size: 13.5,
                        onPressed: () {
                          final base = c.buildFullShareUrl(
                            _justCreated!.sharePath,
                          );
                          final url = _justCreatedPasscode != null
                              ? '$base?p=${Uri.encodeQueryComponent(_justCreatedPasscode!)}'
                              : base;
                          c.windowService.openExternalUrl(url);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    _formatCopyText(
                      _justCreated!,
                      plainPasscode: _justCreatedPasscode,
                    ),
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'Menlo',
                      color: MacPalette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildShareCard(DropDrawerController c, ShareLinkInfo link) {
    final fullUrl = c.buildFullShareUrl(link.sharePath);
    final inactive = link.isExpired || link.isExhausted;

    final meta = <String>[
      if (link.itemCount > 1) l10n.bundleOfItems(link.itemCount),
      if (link.hasPasscode) l10n.passcodeRequired2,
      link.maxDownloads != null
          ? l10n.downloadedOfMax(link.downloadCount, link.maxDownloads!)
          : l10n.downloadedCount(link.downloadCount),
      if (link.isExpired)
        l10n.expired
      else if (link.isExhausted)
        l10n.downloadLimitReached
      else if (link.expiresAt != null)
        _formatRemaining(link.expiresAt!)
      else
        l10n.neverExpires2,
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: MacPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: MacPalette.hairline, width: 0.7),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: MacPalette.fill(0.07),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(
              link.hasPasscode
                  ? CupertinoIcons.lock_fill
                  : (link.itemCount > 1
                      ? CupertinoIcons.collections
                      : CupertinoIcons.link),
              size: 14,
              color:
                  inactive ? MacPalette.textTertiary : MacPalette.textPrimary,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  link.itemName,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: inactive
                        ? MacPalette.textTertiary
                        : MacPalette.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  meta.join(' · '),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: inactive
                        ? MacPalette.red.withValues(alpha: 0.85)
                        : MacPalette.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          MacIconButton(
            icon: CupertinoIcons.doc_on_doc,
            tooltip: l10n.copyLinkUrl(fullUrl),
            size: 13.5,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: fullUrl));
              c.setBanner(l10n.linkCopiedUrl(fullUrl));
            },
          ),
          MacIconButton(
            icon: CupertinoIcons.globe,
            tooltip: l10n.openInBrowserShort,
            size: 13.5,
            onPressed: () => c.windowService.openExternalUrl(fullUrl),
          ),
          MacIconButton(
            icon: CupertinoIcons.trash,
            tooltip: l10n.revokeLink,
            size: 13.5,
            color: MacPalette.red,
            onPressed: () => c.revokeShareLink(link.code),
          ),
        ],
      ),
    );
  }

  String _formatRemaining(DateTime expiresAt) {
    final diff = expiresAt.difference(DateTime.now());
    if (diff.isNegative) return l10n.expired;
    if (diff.inDays >= 1) return l10n.daysLeft(diff.inDays);
    if (diff.inHours >= 1) return l10n.hoursLeft(diff.inHours);
    return l10n.minutesLeft(diff.inMinutes.clamp(1, 59));
  }
}
