part of 'drawer_screen.dart';

class _DrawerItemTile extends StatefulWidget {
  final DropDrawerController controller;
  final DrawerItem item;
  final String? localPath;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onOpenPreview;
  final VoidCallback onShare;
  final VoidCallback onToggleSelect;
  final VoidCallback? onLongPress;

  const _DrawerItemTile({
    required this.controller,
    required this.item,
    this.localPath,
    required this.selectionMode,
    required this.selected,
    required this.onOpenPreview,
    required this.onShare,
    required this.onToggleSelect,
    this.onLongPress,
  });

  @override
  State<_DrawerItemTile> createState() => _DrawerItemTileState();
}

class _DrawerItemTileState extends State<_DrawerItemTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final item = widget.item;
    final localPath = widget.localPath;
    final isMine = item.ownerDeviceId == c.deviceId;
    final cleanDeviceName = item.ownerDeviceName?.replaceAll(
      RegExp(r'\.local$', caseSensitive: false),
      '',
    );
    final isMobile = c.windowService.isMobile;
    final hasDevice = cleanDeviceName != null && cleanDeviceName.isNotEmpty;
    // Phones show when and where an item came from; the status dot already
    // shows availability, so only an unreachable item gets a label.
    final metaParts = isMobile
        ? <String>[
            // Size and time first: a long device name is what gets truncated.
            formatBytes(item.size),
            relativeTimeLabel(item.createdAt),
            if (hasDevice) l10n.fromDevice(cleanDeviceName),
            // Text lives on the server, so it never depends on the source device.
            if (item.kind == 'file' && !c.canDownloadP2p(item) && !item.cloudReady)
              l10n.sourceOffline,
          ]
        : <String>[
            formatBytes(item.size),
            if (c.canDownloadP2p(item) && item.cloudReady)
              l10n.p2pCloud
            else if (c.canDownloadP2p(item))
              l10n.p2pDirect
            else if (item.cloudReady)
              item.storageBackendName ?? l10n.savedToCloud
            else
              l10n.sourceOffline,
            if (hasDevice) cleanDeviceName,
          ];
    final textPreview = isMobile && item.kind == 'text'
        ? (item.textContent ?? '').trim()
        : '';
    final actionBox = isMobile ? 34.0 : 26.0;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap:
            widget.selectionMode ? widget.onToggleSelect : widget.onOpenPreview,
        onLongPress: widget.onLongPress,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 12 : 10,
            vertical: isMobile ? 11 : 9,
          ),
          decoration: BoxDecoration(
            color: widget.selected
                ? MacPalette.accent.withValues(alpha: 0.16)
                : (_hovered ? MacPalette.cardHoverBg : MacPalette.cardBg),
            borderRadius: BorderRadius.circular(isMobile ? 12 : 10),
            border: Border.all(
              color: widget.selected
                  ? MacPalette.accent.withValues(alpha: 0.65)
                  : (_hovered ? MacPalette.strongHairline : Colors.transparent),
              width: 0.7,
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  if (widget.selectionMode) ...[
                    Icon(
                      widget.selected
                          ? CupertinoIcons.checkmark_circle_fill
                          : CupertinoIcons.circle,
                      size: isMobile ? 20 : 17,
                      color: widget.selected
                          ? MacPalette.accent
                          : MacPalette.textTertiary,
                    ),
                    const SizedBox(width: 8),
                  ],
                  _FileIconBox(
                    item: item,
                    localPath: localPath,
                    draggable: localPath != null,
                    size: isMobile ? 44 : 34,
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: TextStyle(
                          fontSize: isMobile ? 15 : 12.5,
                          fontWeight: FontWeight.w500,
                          color: MacPalette.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: isMobile ? 3 : 2),
                      Row(
                        children: [
                          Container(
                            width: isMobile ? 7 : 5,
                            height: isMobile ? 7 : 5,
                            margin: EdgeInsets.only(right: isMobile ? 6 : 5),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: c.canDownloadP2p(item)
                                  ? MacPalette.green
                                  : (item.cloudReady
                                      ? MacPalette.accent
                                      : MacPalette.textTertiary),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              metaParts.join(' · '),
                              style: TextStyle(
                                fontSize: isMobile ? 12.5 : 10.5,
                                color: MacPalette.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      if (textPreview.isNotEmpty && textPreview != item.name) ...[
                        const SizedBox(height: 4),
                        Text(
                          textPreview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            height: 1.35,
                            color: MacPalette.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                if (!widget.selectionMode) ...[
                  if (item.kind == 'text') ...[
                    if (c.canCreateShares)
                    MacIconButton(
                      icon: CupertinoIcons.link,
                      tooltip: l10n.createShareLink,
                      size: isMobile ? 16 : 13.5,
                      boxSize: actionBox,
                      onPressed: widget.onShare,
                    ),
                    MacIconButton(
                      icon: CupertinoIcons.doc_on_doc,
                      tooltip: l10n.copyText,
                      size: isMobile ? 16.5 : 14,
                      boxSize: actionBox,
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(text: item.textContent ?? item.name),
                        );
                        c.setBanner(l10n.copiedToClipboard);
                      },
                    ),
                  ] else ...[
                    if (c.canCreateShares)
                    MacIconButton(
                      icon: CupertinoIcons.link,
                      tooltip: l10n.createShareLink,
                      size: isMobile ? 16 : 13.5,
                      boxSize: actionBox,
                      onPressed: widget.onShare,
                    ),
                    if (isMine && !item.cloudReady && localPath != null && c.canUploadToCloud)
                      MacIconButton(
                        icon: CupertinoIcons.cloud_upload,
                        tooltip: l10n.saveToCloudAvailableOffline,
                        size: isMobile ? 17 : 14.5,
                        boxSize: actionBox,
                        onPressed: () => c.cacheItemToCloud(item.id, localPath),
                      ),
                    if (localPath != null && c.windowService.supportsEdgeDrawer) ...[
                      MacIconButton(
                        icon: CupertinoIcons.doc_on_doc,
                        tooltip: c.windowService.isWindows
                            ? l10n.copyFilePasteIntoFileExplorer
                            : l10n.copyFilePasteIntoFinderOr,
                        size: 14,
                        onPressed: () async {
                          final ok = await c.windowService
                              .copyFileToClipboard(localPath);
                          c.setBanner(ok ? l10n.fileCopiedPasteItWith(c.windowService.pasteShortcutLabel) : l10n.couldnTCopyTheFile);
                        },
                      ),
                      MacIconButton(
                        icon: CupertinoIcons.folder,
                        tooltip: c.windowService.isWindows
                            ? l10n.showInFileExplorerOrDrag
                            : l10n.showInFinderOrDragThe,
                        size: 14.5,
                        onPressed: () => c.windowService.revealInFinder(localPath),
                      ),
                    ] else if (localPath != null && isMobile) ...[
                      MacIconButton(
                        icon: CupertinoIcons.share,
                        tooltip: l10n.shareOpenInAnotherApp,
                        size: 17.5,
                        boxSize: actionBox,
                        onPressed: () async {
                          final ok = await c.windowService
                              .shareFilesNative([localPath]);
                          if (!ok) c.setBanner(l10n.couldnTOpenTheShareSheet);
                        },
                      ),
                    ] else
                      MacIconButton(
                        icon: CupertinoIcons.arrow_down_circle,
                        tooltip: c.canDownloadP2p(item) ? l10n.downloadP2pFirst : l10n.downloadFromCloud,
                        color: MacPalette.textPrimary,
                        size: isMobile ? 19 : 16,
                        boxSize: actionBox,
                        onPressed: () => c.downloadItem(item),
                      ),
                  ],
                  if (_hovered)
                    MacIconButton(
                      icon: CupertinoIcons.xmark,
                      tooltip: l10n.removeFromDrawer,
                      size: 13,
                      onPressed: () async {
                        try {
                          await c.deleteItem(item.id);
                        } catch (e) {
                          c.setBanner(l10n.removeFailedError(e));
                        }
                      },
                    ),
                ],
              ],
            ),
            // Progress changes arrive on their own notifier; only this part of
            // the tile rebuilds for them.
            ListenableBuilder(
              listenable: c.transferTicks,
              builder: (context, _) => _transferSection(c, item, isMobile),
            ),
            ],
          ),
        ),
      ),
    );
  }

}

/// Transfer progress, outgoing sends and errors under an item.
Widget _transferSection(
  DropDrawerController c,
  DrawerItem item,
  bool isMobile,
) {
  final progress = c.activeTransfers[item.id];
  final isTransferring = progress != null && !progress.finished;
  final hasTransferError =
      progress != null && progress.finished && progress.error != null;
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (isTransferring) ...[
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: progress.indicatorValue,
            minHeight: 2.5,
            backgroundColor: MacPalette.fill(0.1),
            valueColor: AlwaysStoppedAnimation<Color>(
              MacPalette.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: 3),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
              switch (progress.channel) {
                'preparing' => l10n.preparingDownload,
                'upload' => progress.uploadLabel,
                'p2p_connecting' => l10n.connectingOverP2p,
                'p2p_replica' => l10n.p2pLanCopy,
                'p2p_direct' => l10n.p2pDirectConnection,
                'p2p_relay' => l10n.p2pEncryptedRelay,
                _ => l10n.cloudDownload,
              },
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isMobile ? 12 : 10,
                color: MacPalette.textTertiary,
              ),
            ),
            ),
            const SizedBox(width: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (progress.progressText case final text?)
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: isMobile ? 12 : 10,
                      color: MacPalette.textSecondary,
                    ),
                  ),
                const SizedBox(width: 6),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(0, 24),
                  onPressed: c.isCancelling(item.id) ? null : () => c.cancelTransfer(item.id),
                  child: Text(
                    c.isCancelling(item.id) ? l10n.canceling : (progress.channel == 'upload' ? l10n.cancelUpload : l10n.cancelDownload),
                    style: TextStyle(fontSize: isMobile ? 12 : 10, color: MacPalette.red),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
      for (final entry in c.outgoingTransfers.entries.where((e) => e.value.itemId == item.id))
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.sendingToProgress(c.recipientName(entry.value.sendingTo!), (entry.value.fraction * 100).floor()),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: isMobile ? 12 : 10, color: MacPalette.textSecondary),
              ),
            ),
            CupertinoButton(
              minimumSize: const Size(0, 24),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              onPressed: c.isCancellingSend(entry.key) ? null : () => c.cancelOutgoingTransfer(entry.key),
              child: Text(c.isCancellingSend(entry.key) ? l10n.canceling : l10n.cancelSending, style: TextStyle(fontSize: isMobile ? 12 : 10, color: MacPalette.red)),
            ),
          ],
        ),
      if (hasTransferError) ...[
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.transferFailedError(progress.error ?? ''),
                style: TextStyle(
                  fontSize: isMobile ? 12 : 10,
                  color: MacPalette.red,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => c.retryTransfer(item),
              child: Text(
                l10n.retry,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                  color: MacPalette.accent,
                ),
              ),
            ),
          ],
        ),
      ],
    ],
  );
}

class _FileIconBox extends StatelessWidget {
  final DrawerItem item;
  final String? localPath;
  final bool draggable;
  final double size;

  const _FileIconBox({
    required this.item,
    this.localPath,
    required this.draggable,
    this.size = 34,
  });

  /// Decoded thumbnails, reused across rebuilds. Building a new MemoryImage from
  /// fresh bytes on every rebuild defeats Flutter's image cache and re-decodes
  /// every thumbnail each time the drawer rebuilds (several times per drop).
  static final Map<String, MemoryImage> _thumbnails = {};
  static const _maxCachedThumbnails = 256;

  static MemoryImage? _thumbnailFor(DrawerItem item) {
    final data = item.thumbnailBase64;
    if (data == null || data.isEmpty) return null;
    final key = '${item.id}:${data.length}:${data.hashCode}';
    final cached = _thumbnails.remove(key);
    if (cached != null) {
      _thumbnails[key] = cached; // Most recently used goes last.
      return cached;
    }
    try {
      final image = MemoryImage(base64Decode(data));
      _thumbnails[key] = image;
      if (_thumbnails.length > _maxCachedThumbnails) {
        _thumbnails.remove(_thumbnails.keys.first);
      }
      return image;
    } catch (_) {
      return null;
    }
  }

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

  Widget _buildContent(bool material) {
    final radius = BorderRadius.circular(size * (material ? 0.25 : 0.22));
    final icon = Icon(
      material ? _resolveMaterialIcon() : _resolveIcon(),
      size: material ? size * 0.5 : 17,
      color: material ? MacPalette.onTonal : MacPalette.textPrimary,
    );
    final thumbnail = _thumbnailFor(item);
    if (thumbnail != null) {
      return ClipRRect(
        borderRadius: radius,
        child: Image(
          image: thumbnail,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }
    if (_isImage && localPath != null && File(localPath!).existsSync()) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.file(
          File(localPath!),
          width: size,
          height: size,
          cacheWidth: 128,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => icon,
        ),
      );
    }
    return icon;
  }

  @override
  Widget build(BuildContext context) {
    // Android: a borderless tonal plate (secondary container), like Material 3
    // list item avatars.
    final material = usesMaterialChrome(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: MacPalette.tonal,
            borderRadius:
                BorderRadius.circular(size * (material ? 0.25 : 0.235)),
            border: material
                ? null
                : Border.all(
                    color: MacPalette.fill(0.1),
                    width: 0.5,
                  ),
          ),
          child: _buildContent(material),
        ),
        if (draggable)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2E),
                shape: BoxShape.circle,
                border: Border.all(color: MacPalette.hairline, width: 0.8),
              ),
              child: Icon(
                CupertinoIcons.arrow_up_right,
                size: 7,
                color: MacPalette.textSecondary,
              ),
            ),
          ),
      ],
    );
  }

  IconData _resolveIcon() {
    if (item.kind == 'text') return CupertinoIcons.text_quote;
    final mime = (item.mimeType ?? '').toLowerCase();
    final lower = item.name.toLowerCase();
    if (mime.startsWith('image/') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp')) {
      return CupertinoIcons.photo;
    }
    if (mime.startsWith('video/') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.mov')) {
      return CupertinoIcons.film;
    }
    if (mime.startsWith('audio/') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.wav')) {
      return CupertinoIcons.music_note;
    }
    if (lower.endsWith('.zip') ||
        lower.endsWith('.tar') ||
        lower.endsWith('.gz') ||
        lower.endsWith('.rar') ||
        lower.endsWith('.7z')) {
      return CupertinoIcons.archivebox;
    }
    if (lower.endsWith('.pdf') ||
        lower.endsWith('.doc') ||
        lower.endsWith('.docx') ||
        lower.endsWith('.md')) {
      return CupertinoIcons.doc_text;
    }
    return CupertinoIcons.doc;
  }

  IconData _resolveMaterialIcon() {
    if (item.kind == 'text') return Icons.notes;
    final mime = (item.mimeType ?? '').toLowerCase();
    final lower = item.name.toLowerCase();
    bool ends(List<String> exts) => exts.any(lower.endsWith);
    if (mime.startsWith('image/') ||
        ends(['.png', '.jpg', '.jpeg', '.webp', '.heic', '.gif'])) {
      return Icons.image_outlined;
    }
    if (mime.startsWith('video/') || ends(['.mp4', '.mov', '.mkv'])) {
      return Icons.movie_outlined;
    }
    if (mime.startsWith('audio/') || ends(['.mp3', '.wav', '.m4a', '.flac'])) {
      return Icons.audio_file_outlined;
    }
    if (ends(['.zip', '.tar', '.gz', '.rar', '.7z'])) {
      return Icons.folder_zip_outlined;
    }
    if (ends(['.pdf'])) return Icons.picture_as_pdf_outlined;
    if (ends(['.apk'])) return Icons.android;
    if (ends(['.exe', '.msi', '.dmg', '.pkg', '.app'])) {
      return Icons.install_desktop_outlined;
    }
    if (ends(['.doc', '.docx', '.md', '.txt', '.rtf'])) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}


/// Placeholder for a dropped file that is still being added to the drawer.
/// Background, corners and separator of a phone list row. Opaque, so swipe
/// actions behind it stay hidden until revealed.
class _PhoneRowFrame extends StatelessWidget {
  final bool material;
  final BorderRadius radius;
  final bool separator;
  final bool selected;
  final Widget child;

  const _PhoneRowFrame({
    required this.material,
    required this.radius,
    required this.separator,
    required this.selected,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final base = material ? MacPalette.background : MacPalette.cardBg;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected
            ? (material
                ? MacPalette.tonal
                : Color.alphaBlend(MacPalette.accent.withValues(alpha: 0.14), base))
            : base,
        borderRadius: radius,
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: radius,
        clipBehavior: radius == BorderRadius.zero ? Clip.none : Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            child,
            // iOS separators start under the text, after the thumbnail.
            if (separator)
              Padding(
                padding: const EdgeInsets.only(left: 72),
                child: Divider(
                  height: 0.5,
                  thickness: 0.5,
                  color: MacPalette.hairline,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A drawer item as a phone list row: thumbnail, name, where and when it came
/// from, a text preview, and one trailing action (copy, share or download).
/// Other actions live in the long-press menu (iOS) or the item page.
class _PhoneItemRow extends StatelessWidget {
  final DropDrawerController controller;
  final DrawerItem item;
  final String? localPath;
  final bool material;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _PhoneItemRow({
    required this.controller,
    required this.item,
    required this.localPath,
    required this.material,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  Widget? _trailingAction() {
    final c = controller;
    final path = localPath;
    final (IconData icon, IconData materialIcon, String tooltip, VoidCallback onPressed) =
        item.kind == 'text'
            ? (
                CupertinoIcons.doc_on_doc,
                Icons.content_copy,
                l10n.copyText,
                () {
                  Clipboard.setData(
                    ClipboardData(text: item.textContent ?? item.name),
                  );
                  c.setBanner(l10n.copiedToClipboard);
                },
              )
            : path != null
                ? (
                    CupertinoIcons.share,
                    Icons.share_outlined,
                    l10n.shareOpenInAnotherApp,
                    () async {
                      final ok = await c.windowService.shareFilesNative([path]);
                      if (!ok) c.setBanner(l10n.couldnTOpenTheShareSheet);
                    },
                  )
                : (
                    CupertinoIcons.arrow_down_circle,
                    Icons.download_outlined,
                    c.canDownloadP2p(item) ? l10n.downloadP2pFirst : l10n.downloadFromCloud,
                    () => c.downloadItem(item),
                  );
    return PhoneBarButton(
      glass: false,
      action: PageAction(
        icon: material ? materialIcon : icon,
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final device = item.ownerDeviceName
        ?.replaceAll(RegExp(r'\.local$', caseSensitive: false), '')
        .trim();
    final meta = <String>[
      formatBytes(item.size),
      relativeTimeLabel(item.createdAt),
      if (device != null && device.isNotEmpty) l10n.fromDeviceName(device),
      // Text lives on the server, so it never depends on the source device.
      if (item.kind == 'file' && !c.canDownloadP2p(item) && !item.cloudReady)
        l10n.sourceOffline,
    ];
    final textPreview =
        item.kind == 'text' ? (item.textContent ?? '').trim() : '';
    final action = selectionMode ? null : _trailingAction();
    final leadInset = selectionMode ? 34.0 : 0.0;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      splashFactory:
          material ? InkRipple.splashFactory : NoSplash.splashFactory,
      highlightColor: MacPalette.fill(0.10),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          action == null ? 16 : (material ? 4 : 10),
          12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (selectionMode) ...[
                  Icon(
                    selected
                        ? (material
                            ? Icons.check_circle
                            : CupertinoIcons.checkmark_circle_fill)
                        : (material
                            ? Icons.radio_button_unchecked
                            : CupertinoIcons.circle),
                    size: 24,
                    color: selected ? MacPalette.accent : MacPalette.textTertiary,
                  ),
                  const SizedBox(width: 10),
                ],
                _FileIconBox(
                  item: item,
                  localPath: localPath,
                  draggable: false,
                  size: 48,
                ),
                SizedBox(width: material ? 16 : 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: material ? 16 : 17,
                          letterSpacing: material ? null : -0.41,
                          color: MacPalette.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Container(
                            width: material ? 6 : 7,
                            height: material ? 6 : 7,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: c.canDownloadP2p(item)
                                  ? MacPalette.green
                                  : (item.cloudReady
                                      ? MacPalette.accent
                                      : MacPalette.textTertiary),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              meta.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: material ? 14 : 13,
                                color: MacPalette.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (textPreview.isNotEmpty && textPreview != item.name)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            textPreview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: material ? 14 : 15,
                              height: 1.3,
                              color: MacPalette.textSecondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (action != null) ...[const SizedBox(width: 4), action],
              ],
            ),
            // Progress changes arrive on their own notifier; only this part
            // of the row rebuilds for them.
            Padding(
              padding: EdgeInsets.only(left: (material ? 64 : 56) + leadInset),
              child: ListenableBuilder(
                listenable: c.transferTicks,
                builder: (context, _) => _transferSection(c, item, true),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// iOS status message: a capsule that drops in under the status bar.
