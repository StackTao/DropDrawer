import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../state/drawer_controller.dart';
import 'theme.dart';

/// Full-width macOS in-drawer quick preview for text notes, images, and files.
class ItemPreviewView extends StatelessWidget {
  final DropDrawerController controller;
  final DrawerItem item;
  final VoidCallback onBack;
  final VoidCallback onShare;

  const ItemPreviewView({
    super.key,
    required this.controller,
    required this.item,
    required this.onBack,
    required this.onShare,
  });

  bool get _isImage {
    if (item.kind != 'file') return false;
    final mime = (item.mimeType ?? '').toLowerCase();
    final lower = item.name.toLowerCase();
    return mime.startsWith('image/') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.heic') ||
        lower.endsWith('.gif');
  }

  bool get _isVideo {
    if (item.kind != 'file') return false;
    final mime = (item.mimeType ?? '').toLowerCase();
    final lower = item.name.toLowerCase();
    return mime.startsWith('video/') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.webm');
  }

  bool get _canSaveToGallery => _isImage || _isVideo;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final localPath = c.localFilePaths[item.id];
    final hasLocalFile = localPath != null && File(localPath).existsSync();
    final isMine = item.ownerDeviceId == c.deviceId;

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
                  onPressed: onBack,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    item.kind == 'text'
                        ? '文本预览'
                        : (_isImage ? '图片预览' : '文件详情'),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                MacIconButton(
                  icon: CupertinoIcons.link,
                  tooltip: '创建外链分享',
                  size: 14,
                  onPressed: onShare,
                ),
                const SizedBox(width: 2),
                MacIconButton(
                  icon: CupertinoIcons.trash,
                  tooltip: '移出抽屉',
                  size: 14,
                  color: MacPalette.red,
                  onPressed: () async {
                    try {
                      await c.deleteItem(item.id);
                    } catch (e) {
                      c.setBanner('移出失败：$e');
                    }
                    onBack();
                  },
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
              if (item.kind == 'text')
                _buildTextBody()
              else if (_isImage)
                _buildImageBody(hasLocalFile ? localPath : null)
              else
                _buildFileHero(),
              const SizedBox(height: 12),
              _buildMetaCard(hasLocalFile ? localPath : null),
              _buildTransferStatus(c),
              const SizedBox(height: 12),
              _buildActionsRow(c, hasLocalFile ? localPath : null, isMine),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTextBody() {
    final fullText = item.textContent ?? item.name;
    return Container(
      constraints: const BoxConstraints(minHeight: 160, maxHeight: 300),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MacPalette.shade(0.28),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: MacPalette.hairline, width: 0.7),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          fullText,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.55,
            color: MacPalette.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _buildImageBody(String? localPath) {
    Widget? preview;
    if (localPath != null) {
      preview = Image.file(
        File(localPath),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    } else if (item.thumbnailBase64 != null &&
        item.thumbnailBase64!.isNotEmpty) {
      try {
        final bytes = base64Decode(item.thumbnailBase64!);
        preview = Image.memory(bytes, fit: BoxFit.contain);
      } catch (_) {}
    }

    return Container(
      height: 240,
      decoration: BoxDecoration(
        color: MacPalette.shade(0.32),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: MacPalette.hairline, width: 0.7),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: preview != null
            ? InteractiveViewer(
                minScale: 0.8,
                maxScale: 4.0,
                child: Center(child: preview),
              )
            : Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      CupertinoIcons.photo,
                      size: 34,
                      color: MacPalette.textTertiary,
                    ),
                    SizedBox(height: 6),
                    Text(
                      '下载到本地后可查看高清原图',
                      style: TextStyle(
                        fontSize: 11,
                        color: MacPalette.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildFileHero() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
      decoration: BoxDecoration(
        color: MacPalette.group(0.24),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: MacPalette.hairline, width: 0.7),
      ),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: MacPalette.fill(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: MacPalette.hairline, width: 0.7),
            ),
            child: Icon(
              CupertinoIcons.doc_fill,
              size: 24,
              color: MacPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          SelectableText(
            item.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: MacPalette.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaCard(String? localPath) {
    final rows = <(String, String)>[
      if (item.kind == 'file') ('文件名', item.name),
      ('大小', formatBytes(item.size)),
      if (item.ownerDeviceName != null) ('来源设备', item.ownerDeviceName!),
      (
        '传输状态',
        item.canP2p && item.cloudReady
            ? 'P2P 直连 + ${item.storageBackendName ?? '云端缓存'}'
            : (item.canP2p
                ? '仅 P2P 端到端直连'
                : (item.cloudReady
                    ? (item.storageBackendName ?? '已存云盘')
                    : '来源离线')),
      ),
      ('到期清理', item.expiresAt != null ? _formatDateTime(item.expiresAt!) : '永不过期'),
      if (localPath != null) ('本机路径', localPath),
    ];

    return Container(
      decoration: BoxDecoration(
        color: MacPalette.group(0.2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: MacPalette.hairline, width: 0.7),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 0.5, thickness: 0.5, indent: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      rows[i].$1,
                      style: TextStyle(
                        fontSize: 11,
                        color: MacPalette.textTertiary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      rows[i].$2,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: MacPalette.textSecondary,
                      ),
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

  Widget _buildTransferStatus(DropDrawerController c) {
    final progress = c.activeTransfers[item.id];
    final isTransferring = progress != null && !progress.finished;
    final outgoing = c.outgoingTransfers.entries
        .where((e) => e.value.itemId == item.id)
        .toList();
    if (!isTransferring && outgoing.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: MacPalette.group(0.22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: MacPalette.hairline, width: 0.7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isTransferring) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress.fraction > 0 ? progress.fraction : null,
                minHeight: 3,
                backgroundColor: MacPalette.fill(0.1),
                valueColor: AlwaysStoppedAnimation<Color>(
                  MacPalette.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  switch (progress.channel) {
                    'preparing' => '正在准备下载',
                    'upload' => '正在上传到云盘',
                    'p2p_connecting' => '正在建立 P2P 连接',
                    'p2p_direct' => 'P2P 端到端直连',
                    'p2p_relay' => 'P2P 加密中继',
                    _ => '云端高速下载',
                  },
                  style: TextStyle(
                    fontSize: 11,
                    color: MacPalette.textSecondary,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${(progress.fraction * 100).toStringAsFixed(0)}%'
                      '${progress.speedBps > 0 ? ' · ${formatBytes(progress.speedBps)}/s' : ''}',
                      style: TextStyle(
                        fontSize: 11,
                        color: MacPalette.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: const Size(0, 24),
                      onPressed: c.isCancelling(item.id) ? null : () => c.cancelTransfer(item.id),
                      child: Text(
                        c.isCancelling(item.id) ? '正在取消' : (progress.channel == 'upload' ? '取消上传' : '取消下载'),
                        style: TextStyle(fontSize: 11, color: MacPalette.red),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
          for (final entry in outgoing)
            Row(
              children: [
                Expanded(
                  child: Text(
                    '正在发送给 ${c.recipientName(entry.value.sendingTo!)} · ${(entry.value.fraction * 100).floor()}%',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: MacPalette.textSecondary,
                    ),
                  ),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(0, 24),
                  onPressed: c.isCancellingSend(entry.key) ? null : () => c.cancelOutgoingTransfer(entry.key),
                  child: Text(
                    c.isCancellingSend(entry.key) ? '正在取消' : '取消发送',
                    style: TextStyle(fontSize: 11, color: MacPalette.red),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildActionsRow(
    DropDrawerController c,
    String? localPath,
    bool isMine,
  ) {
    if (item.kind == 'text') {
      return Row(
        children: [
          Expanded(
            child: _primaryButton(
              icon: CupertinoIcons.doc_on_doc,
              label: '复制全部文本',
              onTap: () {
                Clipboard.setData(
                  ClipboardData(text: item.textContent ?? item.name),
                );
                c.setBanner('已复制全部文本');
              },
            ),
          ),
          const SizedBox(width: 8),
          _secondaryButton(
            icon: CupertinoIcons.link,
            label: '外链',
            onTap: onShare,
          ),
        ],
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (localPath != null && c.windowService.supportsEdgeDrawer) ...[
          _primaryButton(
            icon: CupertinoIcons.doc_on_doc,
            label: '复制文件',
            onTap: () async {
              final ok = await c.windowService.copyFileToClipboard(localPath);
              c.setBanner(ok ? '已复制文件，可直接 ${c.windowService.pasteShortcutLabel} 粘贴' : '复制文件失败');
            },
          ),
          _secondaryButton(
            icon: CupertinoIcons.folder,
            label: c.windowService.isWindows ? '在资源管理器中显示' : '访达中显示',
            onTap: () => c.windowService.revealInFinder(localPath),
          ),
        ] else if (localPath != null && c.windowService.isMobile) ...[
          _primaryButton(
            icon: CupertinoIcons.share,
            label: '系统分享',
            onTap: () async {
              final ok = await c.windowService.shareFilesNative([localPath]);
              if (!ok) c.setBanner('打开系统分享失败');
            },
          ),
          if (_canSaveToGallery)
            _secondaryButton(
              icon: CupertinoIcons.photo_on_rectangle,
              label: '存到相册',
              onTap: () async {
                final ok = await c.windowService.saveToGalleryNative(localPath);
                c.setBanner(ok ? '已保存到系统相册' : '保存相册失败（请检查相册权限）');
              },
            ),
        ] else
          _primaryButton(
            icon: CupertinoIcons.arrow_down_circle,
            label: item.canP2p ? 'P2P 优先下载' : '云端下载',
            onTap: () => c.downloadItem(item),
          ),
        if (isMine && !item.cloudReady && localPath != null)
          _secondaryButton(
            icon: CupertinoIcons.cloud_upload,
            label: '存云盘',
            onTap: () => c.cacheItemToCloud(item.id, localPath),
          ),
        _secondaryButton(
          icon: CupertinoIcons.link,
          label: '外链分享',
          onTap: onShare,
        ),
      ],
    );
  }

  Widget _primaryButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 32,
      child: FilledButton.icon(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: MacPalette.textPrimary,
          foregroundColor: MacPalette.onTextPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: Icon(icon, size: 13.5),
        label: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _secondaryButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 32,
      child: OutlinedButton.icon(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: MacPalette.textPrimary,
          side: BorderSide(color: MacPalette.strongHairline, width: 0.7),
          padding: const EdgeInsets.symmetric(horizontal: 11),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: Icon(icon, size: 13.5),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}
