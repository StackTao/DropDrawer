import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../state/drawer_controller.dart';
import 'phone_page.dart';
import 'theme.dart';

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
      return '链接：$url\n提取码：$plainPasscode';
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
      widget.controller.setBanner('外链已生成并自动复制到剪贴板');
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
    final hasTargets = widget.targetItems.isNotEmpty;
    final isBundle = widget.targetItems.length > 1;

    final title = !hasTargets
        ? '外链分享管理'
        : (isBundle
            ? '打包创建外链 (${widget.targetItems.length} 项)'
            : '创建外链分享');
    return AdaptivePage(
      title: hasTargets ? (isBundle ? '打包外链 (${widget.targetItems.length})' : '创建外链') : '外链管理',
      actions: [
        PageAction(
          icon: CupertinoIcons.refresh,
          tooltip: '刷新外链列表',
          onPressed: _loadingList ? null : _refreshList,
        ),
      ],
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
                  tooltip: '返回抽屉',
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
                  tooltip: '刷新外链列表',
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
              if (hasTargets) ...[
                _buildCreateSection(c, widget.targetItems),
                const SizedBox(height: 16),
              ],
              Row(
                children: [
                  Text(
                    '已创建的外链 (${c.shareLinks.length})',
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
                    '暂无外链分享\n点击单条链接图标，或进入「多选」打包创建合集外链',
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
                          ? '${primary.name} 等 ${items.length} 项'
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
                          ? '${formatBytes(totalBytes)} · 生成前自动上云 $pendingUploadCount 个文件至「${c.defaultStorageBackendName}」'
                          : '${formatBytes(totalBytes)} · 已就绪，外部浏览器免登录提取',
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
                label: '合集标题',
                placeholder: '可选，默认「${primary.name} 等 ${items.length} 项」',
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '有效期',
            style: TextStyle(fontSize: 11, color: MacPalette.textSecondary),
          ),
          const SizedBox(height: 5),
          MacSegmentedControl<int>(
            selected: _expiresHours,
            items: const [
              (1, '1 小时'),
              (24, '24 小时'),
              (168, '7 天'),
              (0, '永久'),
            ],
            onChanged: (v) => setState(() => _expiresHours = v),
          ),
          const SizedBox(height: 10),
          Text(
            '下载次数限制',
            style: TextStyle(fontSize: 11, color: MacPalette.textSecondary),
          ),
          const SizedBox(height: 5),
          MacSegmentedControl<int>(
            selected: _maxDownloads,
            items: const [
              (0, '不限'),
              (1, '1次(阅后即焚)'),
              (5, '5 次'),
              (20, '20 次'),
            ],
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
                    label: '提取码',
                    placeholder: '留空为公开免密',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: MacIconButton(
                    icon: CupertinoIcons.sparkles,
                    tooltip: '随机生成 4 位提取码',
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
                          ? '自动上云并生成外链'
                          : (isBundle ? '生成合集外链并复制' : '生成外链并复制'),
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
                        '已生成并复制到剪贴板',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: MacPalette.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      MacIconButton(
                        icon: CupertinoIcons.doc_on_doc,
                        tooltip: '再次复制链接',
                        size: 13.5,
                        onPressed: () {
                          Clipboard.setData(ClipboardData(
                            text: _formatCopyText(
                              _justCreated!,
                              plainPasscode: _justCreatedPasscode,
                            ),
                          ));
                          c.setBanner('已复制外链信息');
                        },
                      ),
                      MacIconButton(
                        icon: CupertinoIcons.globe,
                        tooltip: '在浏览器中打开预览',
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
      if (link.itemCount > 1) '${link.itemCount} 项合集',
      if (link.hasPasscode) '需提取码',
      link.maxDownloads != null
          ? '已下 ${link.downloadCount}/${link.maxDownloads} 次'
          : '已下 ${link.downloadCount} 次',
      if (link.isExpired)
        '已过期'
      else if (link.isExhausted)
        '次数用尽'
      else if (link.expiresAt != null)
        _formatRemaining(link.expiresAt!)
      else
        '永久有效',
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
            tooltip: '复制外链 ($fullUrl)',
            size: 13.5,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: fullUrl));
              c.setBanner('已复制外链：$fullUrl');
            },
          ),
          MacIconButton(
            icon: CupertinoIcons.globe,
            tooltip: '浏览器打开',
            size: 13.5,
            onPressed: () => c.windowService.openExternalUrl(fullUrl),
          ),
          MacIconButton(
            icon: CupertinoIcons.trash,
            tooltip: '撤销外链',
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
    if (diff.isNegative) return '已过期';
    if (diff.inDays >= 1) return '剩余 ${diff.inDays} 天';
    if (diff.inHours >= 1) return '剩余 ${diff.inHours} 小时';
    return '剩余 ${diff.inMinutes.clamp(1, 59)} 分钟';
  }
}
