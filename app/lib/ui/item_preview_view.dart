import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../state/drawer_controller.dart';
import 'phone_page.dart';
import 'theme.dart';
import '../l10n/l10n.dart';

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

    final title = item.kind == 'text'
        ? l10n.textPreview
        : (_isImage ? l10n.imagePreview : l10n.fileDetails);
    Future<void> remove() async {
      try {
        await c.deleteItem(item.id);
      } catch (e) {
        c.setBanner(l10n.removeFailedError(e));
      }
      onBack();
    }

    final actions = [
      if (c.canCreateShares)
        PageAction(icon: CupertinoIcons.link, tooltip: l10n.createShareLink, onPressed: onShare),
      PageAction(
        icon: CupertinoIcons.trash,
        tooltip: l10n.removeFromDrawer,
        destructive: true,
        onPressed: remove,
      ),
    ];
    if (UiDensity.isTouch(context)) {
      return PhonePage(
        title: title,
        actions: actions,
        body: NativeTypeScale(
          child: _buildPhoneBody(context, c, hasLocalFile ? localPath : null, isMine),
        ),
      );
    }

    return AdaptivePage(
      title: title,
      actions: [
        if (c.canCreateShares)
          PageAction(icon: CupertinoIcons.link, tooltip: l10n.createShareLink, onPressed: onShare),
        PageAction(
          icon: CupertinoIcons.trash,
          tooltip: l10n.removeFromDrawer,
          destructive: true,
          onPressed: remove,
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
                  tooltip: l10n.backToDrawer,
                  size: 15,
                  onPressed: onBack,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (c.canCreateShares)
                  MacIconButton(
                    icon: CupertinoIcons.link,
                    tooltip: l10n.createShareLink,
                    size: 14,
                    onPressed: onShare,
                  ),
                const SizedBox(width: 2),
                MacIconButton(
                  icon: CupertinoIcons.trash,
                  tooltip: l10n.removeFromDrawer,
                  size: 14,
                  color: MacPalette.red,
                  onPressed: remove,
                ),
              ],
            ),
          ),
        ),
      body: ListView(
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
    );
  }

  List<(String, String)> _infoRows(String? localPath) => [
        if (item.kind == 'file') (l10n.fileName, item.name),
        (l10n.size, formatBytes(item.size)),
        if (item.ownerDeviceName != null)
          (
            l10n.sourceDevice,
            item.ownerDeviceName!.replaceAll(RegExp(r'\.local$', caseSensitive: false), ''),
          ),
        (l10n.added, _formatDateTime(item.createdAt)),
        (
          l10n.transferMethod,
          controller.canDownloadP2p(item) && item.cloudReady
              ? l10n.p2pDirectPlus(item.storageBackendName ?? l10n.cloudCache)
              : (controller.canDownloadP2p(item)
                  ? l10n.p2pDirectOnly
                  : (item.cloudReady
                      ? (item.storageBackendName ?? l10n.savedToCloud)
                      : l10n.sourceOffline)),
        ),
        (l10n.expires, item.expiresAt != null ? _formatDateTime(item.expiresAt!) : l10n.neverExpires),
        if (localPath != null)
          controller.windowService.isIOS
              ? (l10n.localCopy, l10n.savedOnThisDevice)
              : (l10n.locationOnThisDevice, localPath),
      ];

  /// Phones: the content up top (text, image, or a large file icon and name
  /// like the Files info view), then actions, transfer progress and details
  /// as settings groups.
  Widget _buildPhoneBody(
    BuildContext context,
    DropDrawerController c,
    String? localPath,
    bool isMine,
  ) {
    final material = usesMaterialChrome(context);
    final Widget hero;
    if (item.kind == 'text') {
      hero = PhoneSection(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              item.textContent ?? item.name,
              style: TextStyle(
                fontSize: material ? 16 : 17,
                height: 1.45,
                color: MacPalette.textPrimary,
              ),
            ),
          ),
        ],
      );
    } else if (_isImage) {
      hero = Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(material ? 18 : 16),
          child: ColoredBox(
            color: MacPalette.cardBg,
            child: SizedBox(height: 320, child: _imagePreview(localPath)),
          ),
        ),
      );
    } else {
      hero = Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        child: Column(
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: MacPalette.cardBg,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(
                material ? Icons.insert_drive_file : CupertinoIcons.doc_fill,
                size: 38,
                color: MacPalette.accent,
              ),
            ),
            const SizedBox(height: 14),
            SelectableText(
              item.name,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: MacPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              formatBytes(item.size),
              style: TextStyle(fontSize: 15, color: MacPalette.textSecondary),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        hero,
        _buildPhoneActions(c, localPath, isMine),
        const SizedBox(height: 24),
        ListenableBuilder(
          listenable: c.transferTicks,
          builder: (context, _) => _buildPhoneTransfer(c),
        ),
        PhoneSection(
          header: l10n.info,
          children: [
            for (final (label, value) in _infoRows(localPath))
              value.length > 22
                  ? PhoneRow(title: label, subtitle: value, selectable: true)
                  : PhoneRow(title: label, value: value),
          ],
        ),
      ],
    );
  }

  Widget _buildPhoneTransfer(DropDrawerController c) {
    final progress = c.activeTransfers[item.id];
    final isTransferring = progress != null && !progress.finished;
    final outgoing = c.outgoingTransfers.entries
        .where((e) => e.value.itemId == item.id)
        .toList();
    if (!isTransferring && outgoing.isEmpty) return const SizedBox.shrink();
    return PhoneSection(
      header: l10n.transfer,
      children: [
        if (isTransferring)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress.indicatorValue,
                    minHeight: 4,
                    backgroundColor: MacPalette.fill(0.1),
                    color: MacPalette.accent,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${switch (progress.channel) {
                          'preparing' => l10n.preparingDownload,
                          'upload' => progress.uploadLabel,
                          'p2p_connecting' => l10n.connectingOverP2p,
                          'p2p_replica' => l10n.p2pLanCopy,
                          'p2p_direct' => l10n.p2pDirectConnection,
                          'p2p_relay' => l10n.p2pEncryptedRelay,
                          _ => l10n.cloudDownloadShort,
                        }}'
                        '${progress.progressText != null ? ' · ${progress.progressText}' : ''}',
                        style: TextStyle(fontSize: 13, color: MacPalette.textSecondary),
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.only(left: 8),
                      minimumSize: const Size(0, 36),
                      onPressed: c.isCancelling(item.id)
                          ? null
                          : () => c.cancelTransfer(item.id),
                      child: Text(
                        c.isCancelling(item.id) ? l10n.canceling : l10n.cancel,
                        style: TextStyle(fontSize: 15, color: MacPalette.red),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        for (final entry in outgoing)
          PhoneRow(
            title: l10n.sendingToDevice(c.recipientName(entry.value.sendingTo!)),
            value: '${(entry.value.fraction * 100).floor()}%',
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 36),
              onPressed: c.isCancellingSend(entry.key)
                  ? null
                  : () => c.cancelOutgoingTransfer(entry.key),
              child: Text(
                c.isCancellingSend(entry.key) ? l10n.canceling : l10n.cancel,
                style: TextStyle(fontSize: 15, color: MacPalette.red),
              ),
            ),
          ),
      ],
    );
  }

  Widget _imagePreview(String? localPath) {
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
        preview = Image.memory(base64Decode(item.thumbnailBase64!), fit: BoxFit.contain);
      } catch (_) {}
    }
    if (preview != null) {
      return InteractiveViewer(
        minScale: 0.8,
        maxScale: 4.0,
        child: Center(child: preview),
      );
    }
    return Center(
      child: Text(
        l10n.downloadItToViewTheOriginal,
        style: TextStyle(fontSize: 15, color: MacPalette.textTertiary),
      ),
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
                      l10n.downloadItToViewTheFull,
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
      if (item.kind == 'file') (l10n.fileName, item.name),
      (l10n.size, formatBytes(item.size)),
      if (item.ownerDeviceName != null) (l10n.sourceDevice, item.ownerDeviceName!),
      (
        l10n.transferStatus,
        controller.canDownloadP2p(item) && item.cloudReady
            ? l10n.p2pDirectPlus(item.storageBackendName ?? l10n.cloudCache)
            : (controller.canDownloadP2p(item)
                ? l10n.p2pEndToEndOnly
                : (item.cloudReady
                    ? (item.storageBackendName ?? l10n.savedToCloud)
                    : l10n.sourceOffline)),
      ),
      (l10n.expires, item.expiresAt != null ? _formatDateTime(item.expiresAt!) : l10n.neverExpires),
      if (localPath != null) (l10n.localPath, localPath),
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
                value: progress.indicatorValue,
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
                    'preparing' => l10n.preparingDownload,
                    'upload' => progress.uploadLabel,
                    'p2p_connecting' => l10n.connectingOverP2p,
                    'p2p_replica' => l10n.p2pLanCopy,
                    'p2p_direct' => l10n.p2pDirectConnection,
                    'p2p_relay' => l10n.p2pEncryptedRelay,
                    _ => l10n.cloudDownload,
                  },
                  style: TextStyle(
                    fontSize: 11,
                    color: MacPalette.textSecondary,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (progress.progressText case final text?)
                      Text(
                        text,
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
                        c.isCancelling(item.id) ? l10n.canceling : (progress.channel == 'upload' ? l10n.cancelUpload : l10n.cancelDownload),
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
                    l10n.sendingToProgress(c.recipientName(entry.value.sendingTo!), (entry.value.fraction * 100).floor()),
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
                    c.isCancellingSend(entry.key) ? l10n.canceling : l10n.cancelSending,
                    style: TextStyle(fontSize: 11, color: MacPalette.red),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// Phones: stacked full-width buttons. Sharing links and removing live in
  /// the navigation bar.
  Widget _buildPhoneActions(
    DropDrawerController c,
    String? localPath,
    bool isMine,
  ) {
    final ios = c.windowService.isIOS;
    final buttons = <Widget>[
      if (item.kind == 'text')
        PhoneButton(
          icon: CupertinoIcons.doc_on_doc,
          label: l10n.copyAllText,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: item.textContent ?? item.name));
            c.setBanner(l10n.copiedAllText);
          },
        )
      else if (localPath != null) ...[
        PhoneButton(
          icon: ios ? CupertinoIcons.eye : Icons.open_in_new,
          // Quick Look on iOS, the default app for the type on Android.
          label: ios ? l10n.quickLook : l10n.open,
          onPressed: () async {
            if (await c.windowService.openFileNative(localPath)) return;
            // Nothing can show this type: offer other apps instead.
            final ok = await c.windowService.shareFilesNative([localPath]);
            if (!ok) c.setBanner(l10n.noAppCanOpenThisFile);
          },
        ),
        PhoneButton(
          kind: PhoneButtonKind.secondary,
          icon: ios ? CupertinoIcons.share : Icons.share_outlined,
          label: l10n.share,
          onPressed: () async {
            final ok = await c.windowService.shareFilesNative([localPath]);
            if (!ok) c.setBanner(l10n.couldnTOpenTheShareSheet);
          },
        ),
        if (_canSaveToGallery)
          PhoneButton(
            kind: PhoneButtonKind.secondary,
            icon: ios ? CupertinoIcons.photo_on_rectangle : Icons.photo_library_outlined,
            label: l10n.saveToPhotos,
            onPressed: () async {
              final ok = await c.windowService.saveToGalleryNative(localPath);
              c.setBanner(ok ? l10n.savedToPhotos : l10n.couldnTSaveToPhotosCheck);
            },
          ),
      ] else
        PhoneButton(
          icon: ios ? CupertinoIcons.arrow_down_circle : Icons.download_outlined,
          label: c.canDownloadP2p(item) ? l10n.downloadP2pFirst : l10n.downloadFromCloud,
          onPressed: () => c.downloadItem(item),
        ),
      if (item.kind == 'file' && isMine && !item.cloudReady && localPath != null &&
          c.canUploadToCloud)
        PhoneButton(
          kind: PhoneButtonKind.secondary,
          icon: ios ? CupertinoIcons.cloud_upload : Icons.cloud_upload_outlined,
          label: l10n.saveToCloudDownloadableWhileThe,
          onPressed: () => c.cacheItemToCloud(item.id, localPath),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, button) in buttons.indexed) ...[
          if (index > 0) const SizedBox(height: 10),
          button,
        ],
      ],
    );
  }

  Widget _buildActionsRow(
    DropDrawerController c,
    String? localPath,
    bool isMine,
  ) {
    if (c.windowService.isMobile) return _buildPhoneActions(c, localPath, isMine);
    if (item.kind == 'text') {
      return Row(
        children: [
          Expanded(
            child: _primaryButton(
              icon: CupertinoIcons.doc_on_doc,
              label: l10n.copyAllText,
              onTap: () {
                Clipboard.setData(
                  ClipboardData(text: item.textContent ?? item.name),
                );
                c.setBanner(l10n.copiedAllText);
              },
            ),
          ),
          if (c.canCreateShares) ...[
            const SizedBox(width: 8),
            _secondaryButton(
              icon: CupertinoIcons.link,
              label: l10n.link,
              onTap: onShare,
            ),
          ],
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
            label: l10n.copyFile,
            onTap: () async {
              final ok = await c.windowService.copyFileToClipboard(localPath);
              c.setBanner(ok ? l10n.fileCopiedPasteItWith(c.windowService.pasteShortcutLabel) : l10n.couldnTCopyTheFile);
            },
          ),
          _secondaryButton(
            icon: CupertinoIcons.folder,
            label: c.windowService.isWindows ? l10n.showInFileExplorer : l10n.showInFinder,
            onTap: () => c.windowService.revealInFinder(localPath),
          ),
        ] else if (localPath != null && c.windowService.isMobile) ...[
          _primaryButton(
            icon: CupertinoIcons.share,
            label: l10n.share2,
            onTap: () async {
              final ok = await c.windowService.shareFilesNative([localPath]);
              if (!ok) c.setBanner(l10n.couldnTOpenTheShareSheet);
            },
          ),
          if (_canSaveToGallery)
            _secondaryButton(
              icon: CupertinoIcons.photo_on_rectangle,
              label: l10n.saveToPhotos,
              onTap: () async {
                final ok = await c.windowService.saveToGalleryNative(localPath);
                c.setBanner(ok ? l10n.savedToPhotos : l10n.couldnTSaveToPhotosCheck);
              },
            ),
        ] else
          _primaryButton(
            icon: CupertinoIcons.arrow_down_circle,
            label: controller.canDownloadP2p(item) ? l10n.downloadP2pFirst : l10n.cloudDownloadShort,
            onTap: () => c.downloadItem(item),
          ),
        if (isMine && !item.cloudReady && localPath != null && c.canUploadToCloud)
          _secondaryButton(
            icon: CupertinoIcons.cloud_upload,
            label: l10n.saveToCloudShort,
            onTap: () => c.cacheItemToCloud(item.id, localPath),
          ),
        if (c.canCreateShares)
          _secondaryButton(
            icon: CupertinoIcons.link,
            label: l10n.shareLink,
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
    return AppLocale.dateTime(dt.toLocal());
  }
}
