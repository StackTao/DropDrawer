import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../models/models.dart';
import '../services/drawer_window_service.dart';
import '../state/drawer_controller.dart';
import 'item_preview_view.dart';
import 'preferences_view.dart';
import 'share_view.dart';
import 'storage_settings_view.dart';
import 'theme.dart';
import 'update_banner.dart';

enum _DrawerPage { drawer, storage, devices, share, preview, preferences }

class DrawerScreen extends StatefulWidget {
  final DropDrawerController controller;

  const DrawerScreen({super.key, required this.controller});

  @override
  State<DrawerScreen> createState() => _DrawerScreenState();
}

class _DrawerScreenState extends State<DrawerScreen> {
  bool _isDragHovering = false;
  bool _handleHovered = false;
  bool _selectionMode = false;
  bool _confirmingClear = false;
  bool _searchOpen = false;
  String _filterKind = 'all'; // 'all' | 'file' | 'text'
  final Set<String> _selectedIds = {};
  _DrawerPage _page = _DrawerPage.drawer;
  List<DrawerItem> _shareTargetItems = const [];
  String? _previewItemId;
  final GlobalKey _moreMenuBtnKey = GlobalKey();
  final FocusNode _shortcutFocusNode = FocusNode();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  AppLifecycleListener? _windowsMenuLifecycle;
  AppLifecycleListener? _mobileLifecycle;
  int _shownBannerSerial = 0;
  // Swiped-away items waiting out their undo window before being deleted.
  final Map<String, Timer> _pendingDeletes = {};

  @override
  void initState() {
    super.initState();
    widget.controller.windowService.onPasteShortcut = _pasteFromClipboard;
    widget.controller.windowService.setMainDrawerActive(true);
    _shownBannerSerial = widget.controller.bannerSerial;
    _searchFocusNode.addListener(_syncMainDrawerShortcutState);
    if (widget.controller.windowService.isMobile) {
      _mobileLifecycle = AppLifecycleListener(
        onResume: () => unawaited(widget.controller.refreshOnResume()),
      );
      unawaited(widget.controller.checkPendingMobileShares());
    }
  }

  @override
  void dispose() {
    _searchFocusNode.removeListener(_syncMainDrawerShortcutState);
    _closeWindowsMoreMenu(widget.controller);
    _mobileLifecycle?.dispose();
    _mobileLifecycle = null;
    widget.controller.windowService.onPasteShortcut = null;
    widget.controller.windowService.setMainDrawerActive(false);
    _shortcutFocusNode.dispose();
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
    // Leaving the screen ends the undo window: carry out pending deletions.
    final controller = widget.controller;
    for (final id in _pendingDeletes.keys.toList()) {
      _pendingDeletes.remove(id)?.cancel();
      unawaited(() async {
        try {
          await controller.deleteItem(id);
        } catch (_) {}
      }());
    }
    super.dispose();
  }

  /// Windows surface: translucent over Mica/Acrylic when DWM applied it,
  /// otherwise the opaque Windows 11 dark base.
  static Color _windowsSurface(DrawerWindowService window) =>
      window.windowsBackdrop ? const Color(0x99202020) : const Color(0xFF202020);

  void _handleBack() {
    if (_page != _DrawerPage.drawer) {
      _switchPage(_DrawerPage.drawer);
    } else if (_selectionMode) {
      setState(() {
        _selectionMode = false;
        _selectedIds.clear();
      });
    } else if (_searchOpen) {
      setState(() {
        _searchOpen = false;
        _searchCtrl.clear();
        _filterKind = 'all';
        _searchFocusNode.unfocus();
      });
      _syncMainDrawerShortcutState();
    }
  }

  void _syncMainDrawerShortcutState() {
    final allowDrawerPaste =
        _page == _DrawerPage.drawer && !_searchFocusNode.hasFocus;
    widget.controller.windowService.setMainDrawerActive(allowDrawerPaste);
  }

  void _switchPage(
    _DrawerPage target, {
    List<DrawerItem>? shareItems,
    String? previewItemId,
  }) {
    setState(() {
      _page = target;
      _shareTargetItems =
          target == _DrawerPage.share ? (shareItems ?? const []) : const [];
      _previewItemId = target == _DrawerPage.preview ? previewItemId : null;
    });
    _syncMainDrawerShortcutState();
  }

  List<DrawerItem> _filteredItems(DropDrawerController c) {
    final q = _searchCtrl.text.trim().toLowerCase();
    return c.items.where((it) {
      if (_pendingDeletes.containsKey(it.id)) return false;
      if (_filterKind != 'all' && it.kind != _filterKind) return false;
      if (q.isEmpty) return true;
      if (it.name.toLowerCase().contains(q)) return true;
      if ((it.textContent ?? '').toLowerCase().contains(q)) return true;
      if ((it.ownerDeviceName ?? '').toLowerCase().contains(q)) return true;
      return false;
    }).toList();
  }

  void _handleMoreMenuAction(DropDrawerController c, String? val) {
    if (val == null) return;
    if (val == 'toggle_dock_side') {
      final next = c.windowService.dockSide == 'left' ? 'right' : 'left';
      c.windowService.setDockSide(next);
      c.setBanner(next == 'left' ? '已停靠到屏幕左侧' : '已停靠到屏幕右侧');
    } else if (val == 'devices') {
      _switchPage(_DrawerPage.devices);
    } else if (val == 'shares') {
      _switchPage(_DrawerPage.share);
    } else if (val == 'preferences') {
      _switchPage(_DrawerPage.preferences);
    } else if (val == 'clear_drawer') {
      _confirmAndClearDrawer(c);
    } else if (val == 'logout') {
      c.logout();
    } else if (val == 'quit') {
      c.windowService.quitApp();
    }
  }

  Future<void> _confirmAndClearDrawer(DropDrawerController c) async {
    if (c.items.isEmpty) return;
    final confirmed = await showAdaptiveConfirm(
      context,
      title: '清空抽屉',
      message: '将清理抽屉中的 ${c.items.length} 项内容及其在服务器或网盘的副本。本机原文件会保留。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (confirmed) {
      await c.clearDrawer();
    }
  }

  Future<void> _openNativeMoreMenu(DropDrawerController c) async {
    double anchorRightX = 356;
    double anchorBottomY = 40;
    final ctx = _moreMenuBtnKey.currentContext;
    if (ctx != null) {
      final box = ctx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final topLeft = box.localToGlobal(Offset.zero);
        anchorRightX = topLeft.dx + box.size.width;
        anchorBottomY = topLeft.dy + box.size.height + 4;
      }
    }
    final selected = await c.windowService.showNativeMoreMenu(
      anchorRightX: anchorRightX,
      anchorBottomY: anchorBottomY,
      username: c.user?.username ?? '',
    );
    _handleMoreMenuAction(c, selected);
  }

  Future<void> _pickFiles() async {
    await widget.controller.windowService.setModalOpen(true);
    try {
      List<String> paths;
      if (widget.controller.windowService.supportsEdgeDrawer) {
        paths = await widget.controller.windowService.pickFilesNative();
      } else {
        final result = await FilePicker.platform.pickFiles(allowMultiple: true);
        paths = result?.paths.whereType<String>().toList() ?? const [];
      }
      if (paths.isNotEmpty) {
        await widget.controller.addFilesToDrawer(paths);
      }
    } catch (e) {
      widget.controller.setBanner('打开文件选择器失败: $e');
    } finally {
      await widget.controller.windowService.setModalOpen(false);
    }
  }

  Future<void> _pickMedia() async {
    try {
      final paths = await widget.controller.windowService.pickMediaNative();
      if (paths.isNotEmpty) {
        await widget.controller.addFilesToDrawer(paths);
      }
    } catch (e) {
      widget.controller.setBanner('打开相册失败: $e');
    }
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await widget.controller.windowService.readClipboardSmart();
      final kind = data['kind'] as String? ?? 'empty';

      if (kind == 'files' || kind == 'image') {
        final paths = (data['paths'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList();
        if (paths.isNotEmpty) {
          await widget.controller.addFilesToDrawer(paths);
          widget.controller.setBanner(
            kind == 'image'
                ? '已粘贴截图并同步到抽屉'
                : '已粘贴 ${paths.length} 个文件到抽屉',
          );
          return;
        }
      } else if (kind == 'text') {
        final text = data['text'] as String? ?? '';
        if (text.trim().isNotEmpty) {
          await widget.controller.addTextToDrawer(text);
          return;
        }
      } else if (kind == 'unsupported_dir') {
        widget.controller.setBanner('暂不支持直接粘贴文件夹，请先压缩或选择具体文件');
        return;
      }

      widget.controller.setBanner('剪贴板为空（支持粘贴文件、截图或文本）');
    } catch (e) {
      widget.controller.setBanner('读取剪贴板失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return LayoutBuilder(
      builder: (context, constraints) {
        final mode = c.windowService.drawerMode;

        // 1. Compact right-center guide pill while dragging files/folders/text (never blocks bottom-right apps).
        if (c.windowService.edgeMode && mode == 'drag_pill') {
          return _buildDragGuidePill(c);
        }

        // 2. Quiet minimal right-center edge handle (click-only to open, zero hover misfires).
        if (c.windowService.supportsEdgeDrawer &&
            ((c.windowService.edgeMode && mode == 'collapsed') ||
                constraints.maxWidth < 180)) {
          return _buildCollapsedHandle(c);
        }

        final isMobile = c.windowService.isMobile;
        final isWindows = c.windowService.isWindows;
        // Windows 11 rounds edge windows by 8px; macOS uses its own 16px panel.
        final radius =
            c.windowService.edgeMode ? (isWindows ? 8.0 : 16.0) : 0.0;
        if (isMobile) _showNewBannerAsToast(c);
        // Android's back button/gesture steps out of secondary pages, multi-
        // select and search before leaving the app.
        final canPop = _page == _DrawerPage.drawer &&
            !_selectionMode &&
            !_searchOpen;
        return PopScope(
          canPop: canPop,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _handleBack();
          },
          child: UiDensity(
            touch: isMobile,
            child: Scaffold(
              backgroundColor: isMobile ? MacPalette.background : Colors.transparent,
              body: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                decoration: BoxDecoration(
                  // macOS draws a vibrancy view behind this tint. Windows only
                  // has a backdrop when Mica/Acrylic is on; otherwise use an
                  // opaque surface rather than a tint over black.
                  color: isMobile
                      ? MacPalette.background
                      : (isWindows
                          ? _windowsSurface(c.windowService)
                          : MacPalette.surfaceTint),
                  borderRadius: BorderRadius.circular(radius),
                  // A constant width keeps the content from shifting when a drag
                  // hovers; only the color changes.
                  border: isMobile
                      ? null
                      : Border.all(
                          color: _isDragHovering
                              ? MacPalette.accent
                              : MacPalette.hairline,
                          width: 1.0,
                        ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  child: SafeArea(
                    top: isMobile,
                    bottom: isMobile,
                    child: Stack(
                      alignment: Alignment.topCenter,
                      fit: StackFit.expand,
                      children: [
                        _buildActivePage(context, c),
                        if (c.windowService.edgeMode &&
                            c.windowService.supportsEdgeDrawer)
                          Positioned(
                            top: 0,
                            child: _buildDrawerDragGrip(c.windowService),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDrawerDragGrip(DrawerWindowService window) {
    return SizedBox(
      width: 64,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) =>
              unawaited(window.dragExpandedDrawer(DrawerDragPhase.start)),
          onPanUpdate: (_) =>
              unawaited(window.dragExpandedDrawer(DrawerDragPhase.update)),
          onPanEnd: (_) =>
              unawaited(window.dragExpandedDrawer(DrawerDragPhase.end)),
          child: Tooltip(
            message: '拖动抽屉',
            child: SizedBox(
              height: 10,
              child: Center(
                child: Container(
                  width: 22,
                  height: 2,
                  decoration: BoxDecoration(
                    color: MacPalette.textTertiary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Stage 1 drag guide pill docked at the drawer's exact right-center position.
  Widget _buildDragGuidePill(DropDrawerController c) {
    final isWindows = c.windowService.isWindows;
    return DropRegion(
      formats: const [Formats.fileUri, Formats.plainText],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (_) => DropOperation.copy,
      onPerformDrop: (event) => _handleDropSession(c, event, expandAfterDrop: true),
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: isWindows
                ? (c.windowService.windowsBackdrop
                    ? const Color(0xB32B2B2B)
                    : const Color(0xFF2B2B2B))
                : const Color(0xEC1C1C20),
            borderRadius: BorderRadius.circular(isWindows ? 8 : 13),
            border: Border.all(
              color: Colors.white.withValues(alpha: isWindows ? 0.12 : 0.2),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF38BDF8), Color(0xFF2563EB)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(
                  CupertinoIcons.tray_arrow_down_fill,
                  size: 12,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 9),
              // Shrink rather than truncate when the system font or text
              // scaling is wider than expected.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '拖到这儿，放入跨端抽屉',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: MacPalette.textPrimary,
                      decoration: TextDecoration.none,
                    ),
                    maxLines: 1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleDropSession(
    DropDrawerController c,
    PerformDropEvent event, {
    bool expandAfterDrop = false,
  }) async {
    setState(() => _isDragHovering = false);
    // Open the drawer right away instead of after reading the dropped data.
    final expanding = expandAfterDrop ? c.windowService.expandDrawer() : null;
    final filePaths = <String>[];
    final texts = <String>[];

    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null) continue;
      if (reader.canProvide(Formats.fileUri)) {
        final completer = Completer<Uri?>();
        reader.getValue(
          Formats.fileUri,
          (value) {
            if (!completer.isCompleted) completer.complete(value);
          },
          onError: (_) {
            if (!completer.isCompleted) completer.complete(null);
          },
        );
        final uri = await completer.future
            .timeout(const Duration(seconds: 3), onTimeout: () => null);
        if (uri != null && uri.scheme == 'file') {
          filePaths.add(uri.toFilePath());
        }
      } else if (reader.canProvide(Formats.plainText)) {
        final completer = Completer<String?>();
        reader.getValue(
          Formats.plainText,
          (value) {
            if (!completer.isCompleted) completer.complete(value);
          },
          onError: (_) {
            if (!completer.isCompleted) completer.complete(null);
          },
        );
        final txt = await completer.future
            .timeout(const Duration(seconds: 3), onTimeout: () => null);
        if (txt != null && txt.trim().isNotEmpty) {
          texts.add(txt);
        }
      }
    }

    if (expanding != null) await expanding;
    if (filePaths.isNotEmpty) {
      await c.addFilesToDrawer(filePaths);
    }
    for (final t in texts) {
      await c.addTextToDrawer(t);
    }
  }

  Widget _buildCollapsedHandle(DropDrawerController c) {
    final isLeft = c.windowService.dockSide == 'left';
    final edgeBorderSide = BorderSide(
      color: Colors.white.withValues(alpha: _handleHovered ? 0.48 : 0.18),
      width: 0.7,
    );

    final handle = MouseRegion(
      onEnter: (_) => setState(() => _handleHovered = true),
      onExit: (_) => setState(() => _handleHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => c.windowService.expandDrawer(),
        onPanUpdate: c.windowService.isWindows
            ? (_) => unawaited(c.windowService.moveDrawerHandle())
            : null,
        onPanEnd: c.windowService.isWindows
            ? (_) => unawaited(c.windowService.moveDrawerHandle(save: true))
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: _handleHovered ? 0.65 : 0.42),
            borderRadius: isLeft
                ? const BorderRadius.horizontal(right: Radius.circular(6))
                : const BorderRadius.horizontal(left: Radius.circular(6)),
            border: isLeft
                ? Border(right: edgeBorderSide)
                : Border(left: edgeBorderSide),
          ),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 3,
              height: _handleHovered ? 40 : 28,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: _handleHovered ? 0.95 : 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
    if (!c.windowService.isWindows) return handle;
    return DropRegion(
      formats: const [Formats.fileUri, Formats.plainText],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) {
        if (event.session.items.any((item) =>
            item.canProvide(Formats.fileUri) ||
            item.canProvide(Formats.plainText))) {
          unawaited(c.windowService.showDragGuide());
        }
        return DropOperation.copy;
      },
      onPerformDrop: (event) => _handleDropSession(c, event, expandAfterDrop: true),
      child: handle,
    );
  }

  /// Secondary pages were laid out for the compact desktop drawer. On phones
  /// their text is scaled up on top of the system text size.
  Widget _touchPage(DropDrawerController c, Widget page) {
    if (!c.windowService.isMobile) return page;
    final media = MediaQuery.of(context);
    final systemScale = media.textScaler.scale(14) / 14;
    return MediaQuery(
      data: media.copyWith(textScaler: TextScaler.linear(systemScale * 1.15)),
      child: page,
    );
  }

  Widget _buildActivePage(BuildContext context, DropDrawerController c) {
    if (_page == _DrawerPage.storage) {
      return _touchPage(
        c,
        StorageSettingsView(
          controller: c,
          onBack: () => _switchPage(_DrawerPage.drawer),
        ),
      );
    }
    if (_page == _DrawerPage.devices) {
      return _touchPage(c, _buildDevicesView(c));
    }
    if (_page == _DrawerPage.share) {
      return _touchPage(
        c,
        ShareView(
          controller: c,
          targetItems: _shareTargetItems,
          onBack: () => _switchPage(_DrawerPage.drawer),
        ),
      );
    }
    if (_page == _DrawerPage.preferences) {
      return _touchPage(
        c,
        PreferencesView(
          controller: c,
          onBack: () => _switchPage(_DrawerPage.drawer),
        ),
      );
    }
    if (_page == _DrawerPage.preview && _previewItemId != null) {
      final found = c.items.where((e) => e.id == _previewItemId).toList();
      if (found.isNotEmpty) {
        final item = found.first;
        return _touchPage(
          c,
          ItemPreviewView(
            controller: c,
            item: item,
            onBack: () => _switchPage(_DrawerPage.drawer),
            onShare: () => _switchPage(_DrawerPage.share, shareItems: [item]),
          ),
        );
      }
    }
    final isMobile = c.windowService.isMobile;

    final visibleItems = _filteredItems(c);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            _pasteFromClipboard,
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            _pasteFromClipboard,
      },
      child: Focus(
        focusNode: _shortcutFocusNode,
        autofocus: true,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => _shortcutFocusNode.requestFocus(),
          child: DropRegion(
            formats: const [Formats.fileUri, Formats.plainText],
            hitTestBehavior: HitTestBehavior.opaque,
            onDropOver: (_) {
              if (!_isDragHovering) setState(() => _isDragHovering = true);
              return DropOperation.copy;
            },
            onDropLeave: (_) {
              if (_isDragHovering) setState(() => _isDragHovering = false);
            },
            onPerformDrop: (event) => _handleDropSession(c, event),
            child: Column(
              children: [
                _buildToolbar(context, c),
                const Divider(height: 0.5, thickness: 0.5),
                // Phones put the add actions in a bottom bar within thumb reach.
                if (!isMobile) _buildDropHeader(c),
                if (c.items.isNotEmpty) _buildBatchActionStrip(c, visibleItems),
                if (c.items.isNotEmpty && _searchOpen)
                  _buildSearchFilterBar(isMobile),
                Expanded(child: _buildItemList(context, c, visibleItems)),
                if (!_selectionMode)
                  UpdateBanner(updates: c.updates, mobile: isMobile),
                if (_selectionMode)
                  _buildBatchFooter(c)
                // Phones show status messages as toasts instead of a footer.
                else if (isMobile)
                  _buildMobileActionBar()
                else
                  _buildFooter(c),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context, DropDrawerController c) {
    final isEdge = c.windowService.edgeMode;
    final isMobile = c.windowService.isMobile;
    return Padding(
      padding: c.windowService.needsMacTrafficLightPadding
          ? const EdgeInsets.fromLTRB(78, 1, 10, 3)
          : isMobile
              ? const EdgeInsets.fromLTRB(16, 10, 10, 10)
              : const EdgeInsets.fromLTRB(14, 10, 10, 9),
      child: SizedBox(
        height: isMobile ? 36 : 26,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: isMobile ? 8 : 7,
              height: isMobile ? 8 : 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.wsConnected
                    ? (c.p2pReady ? MacPalette.green : MacPalette.accent)
                    : MacPalette.red,
              ),
            ),
            const SizedBox(width: 8),
            // Title and device badge give way (ellipsis) before the buttons do,
            // e.g. with a large system text size on a phone.
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      'DropDrawer',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: isMobile ? 16 : 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: GestureDetector(
                      onTap: () => _switchPage(_DrawerPage.devices),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: isMobile ? 8 : 6,
                            vertical: isMobile ? 3.5 : 2,
                          ),
                          decoration: BoxDecoration(
                            color: MacPalette.fill(0.08),
                            borderRadius: BorderRadius.circular(isMobile ? 6 : 5),
                          ),
                          child: Text(
                            '${c.onlineDeviceCount} 设备在线',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: isMobile ? 11.5 : 10.5,
                              color: MacPalette.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (isEdge) ...[
              MacIconButton(
                icon: c.windowService.pinned
                    ? CupertinoIcons.pin_fill
                    : CupertinoIcons.pin,
                tooltip: c.windowService.pinned
                    ? '已固定展开（点击开启离开自动隐藏）'
                    : '离开自动隐藏（点击固定展开）',
                active: c.windowService.pinned,
                size: 13.5,
                onPressed: () =>
                    c.windowService.setPinned(!c.windowService.pinned),
              ),
              const SizedBox(width: 2),
              MacIconButton(
                icon: c.windowService.dockSide == 'left'
                    ? CupertinoIcons.arrow_left_to_line
                    : CupertinoIcons.arrow_right_to_line,
                tooltip: '收起到边缘 (Esc)',
                size: 13.5,
                onPressed: () => c.windowService.collapseDrawer(),
              ),
              const SizedBox(width: 2),
            ],
            if (c.windowService.supportsEdgeDrawer) ...[
              MacIconButton(
                icon: isEdge
                    ? CupertinoIcons.macwindow
                    : (c.windowService.dockSide == 'left'
                        ? CupertinoIcons.sidebar_left
                        : CupertinoIcons.sidebar_right),
                tooltip: isEdge ? '切换为常规窗口' : '切换为边缘抽屉',
                size: 14,
                onPressed: () => c.windowService.setEdgeDrawerMode(!isEdge),
              ),
              const SizedBox(width: 2),
            ],
            MacIconButton(
              icon: CupertinoIcons.cloud,
              tooltip: '多云盘与中转存储',
              size: isMobile ? 19 : 14.5,
              boxSize: isMobile ? 36 : 26,
              onPressed: () => _switchPage(_DrawerPage.storage),
            ),
            SizedBox(width: isMobile ? 4 : 2),
            if (c.windowService.isWindows)
              _buildWindowsMoreMenu(c)
            else if (c.windowService.supportsEdgeDrawer)
              KeyedSubtree(
                key: _moreMenuBtnKey,
                child: MacIconButton(
                  icon: CupertinoIcons.ellipsis,
                  tooltip: '更多',
                  size: 15,
                  onPressed: () => _openNativeMoreMenu(c),
                ),
              )
            else
              PopupMenuButton<String>(
                tooltip: '更多',
                padding: EdgeInsets.zero,
                offset: Offset(0, isMobile ? 40 : 30),
                color: MacPalette.elevatedBg,
                elevation: 10,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: MacPalette.strongHairline, width: 0.8),
                ),
                onSelected: (val) => _handleMoreMenuAction(c, val),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'shares',
                    height: isMobile ? 40 : 30,
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.link, size: isMobile ? 16 : 13.5, color: MacPalette.textSecondary),
                        const SizedBox(width: 10),
                        Text('外链管理', style: TextStyle(fontSize: isMobile ? 14 : 12)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'devices',
                    height: isMobile ? 40 : 30,
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.device_laptop, size: isMobile ? 16 : 13.5, color: MacPalette.textSecondary),
                        const SizedBox(width: 10),
                        Text('设备状态', style: TextStyle(fontSize: isMobile ? 14 : 12)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'preferences',
                    height: isMobile ? 40 : 30,
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.gear_alt, size: isMobile ? 16 : 13.5, color: MacPalette.textSecondary),
                        const SizedBox(width: 10),
                        Text('偏好设置', style: TextStyle(fontSize: isMobile ? 14 : 12)),
                      ],
                    ),
                  ),
                  if (isMobile && c.items.isNotEmpty) ...[
                    const PopupMenuDivider(height: 8),
                    PopupMenuItem(
                      value: 'clear_drawer',
                      height: 40,
                      child: Row(
                        children: [
                          Icon(CupertinoIcons.trash, size: 16, color: MacPalette.red),
                          SizedBox(width: 10),
                          Text('清空抽屉', style: TextStyle(fontSize: 14, color: MacPalette.red)),
                        ],
                      ),
                    ),
                  ],
                  const PopupMenuDivider(height: 8),
                  PopupMenuItem(
                    value: 'logout',
                    height: isMobile ? 40 : 30,
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.square_arrow_right, size: isMobile ? 16 : 13.5, color: MacPalette.red),
                        const SizedBox(width: 10),
                        Text(
                          '退出登录',
                          style: TextStyle(
                            fontSize: isMobile ? 14 : 12,
                            color: MacPalette.red,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                child: SizedBox(
                  width: isMobile ? 36 : 26,
                  height: isMobile ? 36 : 26,
                  child: Icon(
                    CupertinoIcons.ellipsis,
                    size: isMobile ? 19 : 15,
                    color: MacPalette.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWindowsMoreMenu(DropDrawerController c) {
    final dockLeft = c.windowService.dockSide == 'left';

    PopupMenuItem<String> entry(
      String action,
      String title,
      IconData icon, {
      bool destructive = false,
    }) {
      return PopupMenuItem(
        value: action,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(icon, size: 14, color: MacPalette.textSecondary),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                color: destructive ? MacPalette.red : MacPalette.textPrimary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }

    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: const Icon(CupertinoIcons.ellipsis),
      iconSize: 16,
      iconColor: MacPalette.textPrimary,
      style: IconButton.styleFrom(
        backgroundColor: MacPalette.cardBg,
        minimumSize: const Size.square(26),
        maximumSize: const Size.square(26),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      color: MacPalette.elevatedBg,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      constraints: const BoxConstraints.tightFor(width: 168),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: MacPalette.strongHairline, width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
      onOpened: () {
        final navigator = Navigator.of(context);
        _windowsMenuLifecycle = AppLifecycleListener(
          onInactive: () => unawaited(navigator.maybePop()),
        );
        unawaited(c.windowService.setModalOpen(true));
      },
      onCanceled: () => _closeWindowsMoreMenu(c),
      onSelected: (action) {
        _closeWindowsMoreMenu(c);
        _handleMoreMenuAction(c, action);
      },
      itemBuilder: (_) => [
        entry('shares', '外链管理', CupertinoIcons.link),
        entry('devices', '设备状态', CupertinoIcons.device_laptop),
        entry('preferences', '偏好设置', CupertinoIcons.gear_alt),
        entry(
          'toggle_dock_side',
          dockLeft ? '停靠右侧' : '停靠左侧',
          dockLeft ? CupertinoIcons.sidebar_right : CupertinoIcons.sidebar_left,
        ),
        PopupMenuDivider(
          height: 8,
          indent: 12,
          endIndent: 12,
          color: MacPalette.hairline,
        ),
        entry('logout', '退出登录', CupertinoIcons.square_arrow_right),
        entry('quit', '退出应用', CupertinoIcons.power, destructive: true),
      ],
    );
  }

  void _closeWindowsMoreMenu(DropDrawerController c) {
    final listener = _windowsMenuLifecycle;
    if (listener == null) return;
    listener.dispose();
    _windowsMenuLifecycle = null;
    unawaited(c.windowService.setModalOpen(false));
  }

  Widget _buildDropHeader(DropDrawerController c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        children: [
          GestureDetector(
            onTap: _pickFiles,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                decoration: BoxDecoration(
                  color: _isDragHovering
                      ? MacPalette.fill(0.14)
                      : MacPalette.fill(0.05),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color: _isDragHovering
                        ? MacPalette.fill(0.45)
                        : MacPalette.hairline,
                    width: 1.0,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: MacPalette.fill(0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        _isDragHovering
                            ? CupertinoIcons.arrow_down_doc_fill
                            : CupertinoIcons.plus,
                        size: 16,
                        color: MacPalette.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isDragHovering ? '松开以放进抽屉' : '拖入、选取或 ${c.windowService.pasteShortcutLabel} 粘贴',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: MacPalette.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            c.defaultDropPolicy == 'p2p_only'
                                ? '仅本机 P2P 端到端直连 · 不占服务器与云盘'
                                : (c.defaultDropPolicy == 'cloud_cached'
                                    ? '直接上传至「${c.defaultStorageBackendName}」· 离线可下'
                                    : '小于 ${c.autoCloudThresholdBytes ~/ (1024 * 1024)}MB 自动云存 · 大文件纯 P2P 直连'),
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
                    MacIconButton(
                      icon: CupertinoIcons.doc_on_clipboard,
                      tooltip: '智能粘贴文件 / 截图 / 文本 (${c.windowService.pasteShortcutLabel})',
                      size: 14.5,
                      onPressed: _pasteFromClipboard,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          MacSegmentedControl<String>(
            selected: c.defaultDropPolicy,
            items: [
              ('smart', '智能(<${c.autoCloudThresholdBytes ~/ (1024 * 1024)}M上云)'),
              ('p2p_only', '纯 P2P 直连'),
              ('cloud_cached', '强制存云盘'),
            ],
            onChanged: c.setDropPolicy,
          ),
        ],
      ),
    );
  }

  /// Compact inline bar above the list for quick search & batch actions.
  Widget _buildBatchActionStrip(
    DropDrawerController c,
    List<DrawerItem> visibleItems,
  ) {
    final allIds = visibleItems.map((e) => e.id).toSet();
    final existingIds = c.items.map((e) => e.id).toSet();
    _selectedIds.removeWhere((id) => !existingIds.contains(id));
    final allSelected =
        visibleItems.isNotEmpty && allIds.every(_selectedIds.contains);
    final isFiltering =
        _filterKind != 'all' || _searchCtrl.text.trim().isNotEmpty;

    final isMobile = c.windowService.isMobile;
    return Padding(
      padding: isMobile
          ? const EdgeInsets.fromLTRB(16, 4, 14, 6)
          : const EdgeInsets.fromLTRB(14, 2, 12, 4),
      child: Row(
        children: [
          if (_selectionMode) ...[
            _miniTextAction(
              label: allSelected ? '取消全选' : '全选 (${visibleItems.length})',
              isMobile: isMobile,
              onTap: () {
                setState(() {
                  if (allSelected) {
                    _selectedIds.removeAll(allIds);
                  } else {
                    _selectedIds.addAll(allIds);
                  }
                });
              },
            ),
            const SizedBox(width: 8),
            Text(
              '已选 ${_selectedIds.length} 项',
              style: TextStyle(
                fontSize: isMobile ? 12 : 10.5,
                color: MacPalette.textTertiary,
              ),
            ),
            const Spacer(),
            _miniTextAction(
              label: '完成',
              color: MacPalette.textPrimary,
              isMobile: isMobile,
              onTap: () => setState(() {
                _selectionMode = false;
                _selectedIds.clear();
              }),
            ),
          ] else ...[
            Text(
              isFiltering
                  ? '筛选结果 · ${visibleItems.length}/${c.items.length}'
                  : '抽屉内容 · ${c.items.length} 项',
              style: TextStyle(
                fontSize: isMobile ? 13.5 : 10.5,
                color: MacPalette.textTertiary,
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: () {
                setState(() {
                  _searchOpen = !_searchOpen;
                  if (!_searchOpen) {
                    _searchCtrl.clear();
                    _filterKind = 'all';
                    _searchFocusNode.unfocus();
                  }
                });
                if (_searchOpen) {
                  Future.microtask(() => _searchFocusNode.requestFocus());
                } else {
                  _syncMainDrawerShortcutState();
                }
              },
              behavior: HitTestBehavior.opaque,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isMobile ? 10 : 4,
                    vertical: isMobile ? 10 : 2,
                  ),
                  child: Icon(
                    CupertinoIcons.search,
                    size: isMobile ? 19 : 12.5,
                    color: (_searchOpen || isFiltering)
                        ? MacPalette.textPrimary
                        : MacPalette.textSecondary,
                  ),
                ),
              ),
            ),
            if (isMobile)
              // Long-press an item also starts selecting; less frequent list
              // actions sit in a menu rather than a row of small text buttons.
              _buildMobileListMenu(c, visibleItems)
            else ...[
              const SizedBox(width: 8),
              _miniTextAction(
                label: '多选',
                onTap: () => _enterSelectionMode(),
              ),
              const SizedBox(width: 10),
              _miniTextAction(
                label: '全部下载',
                onTap: () => c.batchDownloadItems(visibleItems),
              ),
            ],
            if (!isMobile) ...[
              const SizedBox(width: 10),
              if (_confirmingClear) ...[
                _miniTextAction(
                  label: '确认清空',
                  color: MacPalette.red,
                  onTap: () async {
                    setState(() => _confirmingClear = false);
                    await c.clearDrawer();
                  },
                ),
                const SizedBox(width: 6),
                _miniTextAction(
                  label: '取消',
                  onTap: () => setState(() => _confirmingClear = false),
                ),
              ] else
                _miniTextAction(
                  label: '清空',
                  color: MacPalette.textSecondary,
                  onTap: () {
                    setState(() => _confirmingClear = true);
                    Future.delayed(const Duration(seconds: 4), () {
                      if (mounted && _confirmingClear) {
                        setState(() => _confirmingClear = false);
                      }
                    });
                  },
                ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildSearchFilterBar(bool isMobile) {
    final fontSize = isMobile ? 15.0 : 11.5;
    return Padding(
      padding: isMobile
          ? const EdgeInsets.fromLTRB(14, 2, 14, 8)
          : const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: isMobile ? 38 : 28,
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 10 : 8),
              decoration: BoxDecoration(
                color: MacPalette.shade(0.28),
                borderRadius: BorderRadius.circular(isMobile ? 10 : 7),
                border: Border.all(color: MacPalette.hairline, width: 0.6),
              ),
              child: Row(
                children: [
                  Icon(
                    CupertinoIcons.search,
                    size: isMobile ? 16 : 12.5,
                    color: MacPalette.textTertiary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      focusNode: _searchFocusNode,
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(
                        fontSize: fontSize,
                        color: MacPalette.textPrimary,
                      ),
                      cursorColor: MacPalette.textPrimary,
                      cursorWidth: 1.4,
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        hintText: '搜索文件名或文本...',
                        hintStyle: TextStyle(
                          fontSize: fontSize,
                          color: MacPalette.textTertiary,
                        ),
                      ),
                    ),
                  ),
                  if (_searchCtrl.text.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _searchCtrl.clear();
                        setState(() {});
                      },
                      child: Icon(
                        CupertinoIcons.xmark_circle_fill,
                        size: 13,
                        color: MacPalette.textTertiary,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          _filterPill('all', '全部'),
          const SizedBox(width: 4),
          _filterPill('file', '文件'),
          const SizedBox(width: 4),
          _filterPill('text', '文本'),
        ],
      ),
    );
  }

  Widget _filterPill(String kind, String label) {
    final active = _filterKind == kind;
    return GestureDetector(
      onTap: () => setState(() => _filterKind = kind),
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? MacPalette.fill(0.16)
                : MacPalette.group(0.22),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: active ? MacPalette.strongHairline : MacPalette.hairline,
              width: 0.6,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: active ? FontWeight.w500 : FontWeight.w400,
              color: active ? MacPalette.textPrimary : MacPalette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _mobileQuickActionBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: MacPalette.fill(0.07),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(12),
        // The app theme turns splashes off for the desktop look; phones need
        // visible press feedback.
        splashFactory: InkRipple.splashFactory,
        splashColor: MacPalette.fill(0.08),
        highlightColor: MacPalette.fill(0.10),
        child: Container(
          height: 50,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: MacPalette.hairline, width: 0.7),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: MacPalette.textPrimary),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: MacPalette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileActionBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: MacPalette.hairline, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _mobileQuickActionBtn(
              icon: CupertinoIcons.doc_fill,
              label: '选文件',
              onTap: _pickFiles,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _mobileQuickActionBtn(
              icon: CupertinoIcons.photo_fill,
              label: '选相册',
              onTap: _pickMedia,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _mobileQuickActionBtn(
              icon: CupertinoIcons.doc_on_clipboard_fill,
              label: '粘贴',
              onTap: _pasteFromClipboard,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileListMenu(
    DropDrawerController c,
    List<DrawerItem> visibleItems,
  ) {
    PopupMenuItem<String> entry(String value, IconData icon, String label) =>
        PopupMenuItem(
          value: value,
          height: 46,
          child: Row(
            children: [
              Icon(icon, size: 18, color: MacPalette.textSecondary),
              const SizedBox(width: 12),
              Text(label, style: const TextStyle(fontSize: 15)),
            ],
          ),
        );
    return PopupMenuButton<String>(
      tooltip: '更多操作',
      padding: EdgeInsets.zero,
      offset: const Offset(0, 44),
      color: MacPalette.elevatedBg,
      elevation: 10,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: MacPalette.strongHairline, width: 0.8),
      ),
      onSelected: (value) {
        if (value == 'select') _enterSelectionMode();
        if (value == 'download_all') c.batchDownloadItems(visibleItems);
      },
      itemBuilder: (_) => [
        entry('select', CupertinoIcons.checkmark_circle, '多选'),
        entry('download_all', CupertinoIcons.arrow_down_circle, '全部下载'),
      ],
      child: SizedBox(
        width: 44,
        height: 40,
        child: Icon(
          CupertinoIcons.ellipsis_circle,
          size: 21,
          color: MacPalette.textSecondary,
        ),
      ),
    );
  }

  void _enterSelectionMode([String? firstId]) {
    setState(() {
      _selectionMode = true;
      _confirmingClear = false;
      _selectedIds.clear();
      if (firstId != null) _selectedIds.add(firstId);
    });
  }

  void _showNewBannerAsToast(DropDrawerController c) {
    final serial = c.bannerSerial;
    final message = c.statusBanner;
    if (serial == _shownBannerSerial || message == null) return;
    _shownBannerSerial = serial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showToast(message);
    });
  }

  void _showToast(
    String message, {
    SnackBarAction? action,
    Duration duration = const Duration(milliseconds: 2600),
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, color: MacPalette.toastText),
        ),
        action: action,
        duration: duration,
        behavior: SnackBarBehavior.floating,
        backgroundColor: MacPalette.toastBackground,
        // Sit above the bottom action bar.
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 78),
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  /// Hides a swiped item at once and deletes it after the undo window.
  void _deleteWithUndo(DropDrawerController c, DrawerItem item) {
    HapticFeedback.lightImpact();
    setState(() {
      _pendingDeletes[item.id] = Timer(
        const Duration(seconds: 4),
        () => unawaited(_commitDelete(c, item.id)),
      );
    });
    _showToast(
      '已移出「${item.name}」',
      duration: const Duration(seconds: 4),
      action: SnackBarAction(
        label: '撤销',
        textColor: MacPalette.accent,
        onPressed: () {
          _pendingDeletes.remove(item.id)?.cancel();
          if (mounted) setState(() {});
        },
      ),
    );
  }

  Future<void> _commitDelete(DropDrawerController c, String id) async {
    if (_pendingDeletes.remove(id) == null) return;
    try {
      await c.deleteItem(id);
    } catch (e) {
      c.setBanner('移出失败：$e');
    }
    if (mounted) setState(() {});
  }

  Widget _miniTextAction({
    required String label,
    required VoidCallback onTap,
    Color? color,
    bool isMobile = false,
  }) {
    final textColor = color ?? MacPalette.textSecondary;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isMobile ? 6 : 2,
            vertical: isMobile ? 6 : 2,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: isMobile ? 12.5 : 11,
              fontWeight: FontWeight.w500,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }

  /// Bottom action bar shown in multi-select mode.
  Widget _buildBatchFooter(DropDrawerController c) {
    final selectedItems =
        c.items.where((it) => _selectedIds.contains(it.id)).toList();
    final hasSelection = selectedItems.isNotEmpty;
    final localSelectedPaths = selectedItems
        .map((it) => c.localFilePaths[it.id])
        .whereType<String>()
        .toList();

    final isMobile = c.windowService.isMobile;
    return Container(
      height: isMobile ? 62 : 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: MacPalette.shade(0.28),
        border: Border(
          top: BorderSide(color: MacPalette.hairline, width: 0.6),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _batchFooterBtn(
            isMobile: isMobile,
            icon: CupertinoIcons.arrow_down_circle,
            label: '下载',
            enabled: hasSelection,
            onTap: () async {
              await c.batchDownloadItems(selectedItems);
              if (mounted) {
                setState(() {
                  _selectionMode = false;
                  _selectedIds.clear();
                });
              }
            },
          ),
          _batchFooterBtn(
            isMobile: isMobile,
            icon: c.windowService.isMobile
                ? CupertinoIcons.share
                : CupertinoIcons.doc_on_doc,
            label: c.windowService.isMobile ? '分享' : '复制',
            enabled: localSelectedPaths.isNotEmpty,
            onTap: () async {
              if (c.windowService.isMobile) {
                final ok = await c.windowService
                    .shareFilesNative(localSelectedPaths);
                if (!ok) c.setBanner('打开系统分享失败');
                return;
              }
              final ok = await c.windowService
                  .copyFilesToClipboard(localSelectedPaths);
              c.setBanner(
                ok
                    ? '已复制 ${localSelectedPaths.length} 个文件，可直接 ${c.windowService.pasteShortcutLabel} 粘贴'
                    : '复制文件失败',
              );
            },
          ),
          _batchFooterBtn(
            isMobile: isMobile,
            icon: CupertinoIcons.link,
            label: '外链',
            enabled: hasSelection,
            onTap: () {
              final targets = List<DrawerItem>.from(selectedItems);
              setState(() {
                _selectionMode = false;
                _selectedIds.clear();
              });
              _switchPage(_DrawerPage.share, shareItems: targets);
            },
          ),
          _batchFooterBtn(
            isMobile: isMobile,
            icon: CupertinoIcons.cloud_upload,
            label: '存云盘',
            enabled: hasSelection,
            onTap: () async {
              await c.batchCacheToCloud(selectedItems);
            },
          ),
          _batchFooterBtn(
            isMobile: isMobile,
            icon: CupertinoIcons.trash,
            label: hasSelection ? '删除(${selectedItems.length})' : '删除',
            enabled: hasSelection,
            color: MacPalette.red,
            onTap: () async {
              final ids = selectedItems.map((e) => e.id).toList();
              await c.batchDeleteItems(ids);
              if (mounted) {
                setState(() {
                  _selectedIds.clear();
                  if (c.items.isEmpty) _selectionMode = false;
                });
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _batchFooterBtn({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
    bool isMobile = false,
    Color? color,
  }) {
    final effectiveColor =
        enabled ? (color ?? MacPalette.textPrimary) : MacPalette.textTertiary;
    if (isMobile) {
      // Icon over label, like an iOS toolbar, with a full-height tap target.
      return Expanded(
        child: GestureDetector(
          onTap: enabled
              ? () {
                  HapticFeedback.selectionClick();
                  onTap();
                }
              : null,
          behavior: HitTestBehavior.opaque,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 21, color: effectiveColor),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: effectiveColor,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13.5, color: effectiveColor),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: effectiveColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItemList(
    BuildContext context,
    DropDrawerController c,
    List<DrawerItem> visibleItems,
  ) {
    final isMobile = c.windowService.isMobile;
    final pending = c.pendingDrops;
    if (c.items.isEmpty && pending.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.tray,
                size: isMobile ? 44 : 30,
                color: MacPalette.fill(0.16),
              ),
              SizedBox(height: isMobile ? 14 : 10),
              Text(
                '抽屉是空的',
                style: TextStyle(
                  fontSize: isMobile ? 17 : 13,
                  fontWeight: FontWeight.w500,
                  color: MacPalette.textSecondary,
                ),
              ),
              SizedBox(height: isMobile ? 8 : 5),
              Text(
                isMobile
                    ? '点击下方「选文件」「选相册」或「粘贴」\n也可在其他 App 中点「分享 → DropDrawer」直接发送'
                    : '拖起文件或文本靠近悬浮引导条\n点击边缘手柄展开 · 拖动可调整上下或左右停靠',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isMobile ? 14 : 11,
                  height: 1.5,
                  color: MacPalette.textTertiary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (visibleItems.isEmpty && pending.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的抽屉条目',
          style: TextStyle(
            fontSize: isMobile ? 15 : 12,
            color: MacPalette.textTertiary,
          ),
        ),
      );
    }

    final listView = ListView.separated(
      physics: isMobile ? const AlwaysScrollableScrollPhysics() : null,
      padding: EdgeInsets.fromLTRB(
        isMobile ? 14 : 12,
        isMobile ? 6 : 4,
        isMobile ? 14 : 12,
        isMobile ? 12 : 8,
      ),
      itemCount: pending.length + visibleItems.length,
      separatorBuilder: (_, _) => SizedBox(height: isMobile ? 8 : 6),
      itemBuilder: (context, index) {
        if (index < pending.length) {
          return _PendingDropTile(drop: pending[index], isMobile: isMobile);
        }
        final item = visibleItems[index - pending.length];
        final localPath = c.localFilePaths[item.id];
        final isSelected = _selectedIds.contains(item.id);
        final tile = _DrawerItemTile(
          controller: c,
          item: item,
          localPath: localPath,
          selectionMode: _selectionMode,
          selected: isSelected,
          onOpenPreview: () =>
              _switchPage(_DrawerPage.preview, previewItemId: item.id),
          onShare: () => _switchPage(_DrawerPage.share, shareItems: [item]),
          onLongPress: isMobile && !_selectionMode
              ? () {
                  HapticFeedback.mediumImpact();
                  _enterSelectionMode(item.id);
                }
              : null,
          onToggleSelect: () {
            setState(() {
              if (isSelected) {
                _selectedIds.remove(item.id);
              } else {
                _selectedIds.add(item.id);
              }
            });
          },
        );

        if (isMobile && !_selectionMode) {
          return Dismissible(
            key: ValueKey('mobile_item_${item.id}'),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                color: MacPalette.red.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.trash, size: 16, color: Colors.white),
                  SizedBox(width: 6),
                  Text(
                    '移出抽屉',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            onDismissed: (_) => _deleteWithUndo(c, item),
            child: tile,
          );
        }

        if (!isMobile &&
            !_selectionMode &&
            localPath != null &&
            item.kind == 'file') {
          return DragItemWidget(
            dragItemProvider: (_) async {
              final dragItem = DragItem(suggestedName: item.name);
              dragItem.add(Formats.fileUri(Uri.file(localPath)));
              return dragItem;
            },
            allowedOperations: () => [DropOperation.copy],
            child: DraggableWidget(child: tile),
          );
        }
        return tile;
      },
    );
    if (c.windowService.isMobile) {
      return RefreshIndicator(
        onRefresh: c.manualRefresh,
        color: MacPalette.textPrimary,
        backgroundColor: MacPalette.elevatedBg,
        child: listView,
      );
    }
    return listView;
  }

  Widget _buildDevicesView(DropDrawerController c) {
    final devices = c.displayedDevices;
    (String, String) nameKey(DeviceInfo device) =>
        (device.platform, device.name.trim().toLowerCase().replaceFirst(
          RegExp(r'\.local$'), '',
        ));
    final onlineNames =
        devices.where((device) => device.online).map(nameKey).toSet();
    final primary = <DeviceInfo>[];
    final sameNameOffline = <DeviceInfo>[];
    for (final device in devices) {
      if (!device.online &&
          device.id != c.deviceId &&
          onlineNames.contains(nameKey(device))) {
        sameNameOffline.add(device);
      } else {
        primary.add(device);
      }
    }
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
                  onPressed: () => _switchPage(_DrawerPage.drawer),
                ),
                const SizedBox(width: 4),
                const Text(
                  '已登录设备与 P2P 节点',
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
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: MacPalette.group(0.22),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: MacPalette.hairline, width: 0.7),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: c.p2pReady ? MacPalette.green : MacPalette.amber,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          c.p2pReady ? '本机 iroh QUIC P2P 节点运行中' : 'P2P 引擎未加载',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    if (c.localNodeInfo != null) ...[
                      const SizedBox(height: 6),
                      SelectableText(
                        'Node ID: ${c.localNodeInfo!.nodeId}',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: MacPalette.textTertiary,
                          fontFamily: 'Menlo',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '同账号设备',
                style: TextStyle(fontSize: 11.5, color: MacPalette.textSecondary),
              ),
              const SizedBox(height: 6),
              _buildDeviceRows(primary, c.deviceId),
              if (sameNameOffline.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    '同名离线设备（${sameNameOffline.length}）',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  children: [_buildDeviceRows(sameNameOffline, c.deviceId)],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceRows(List<DeviceInfo> devices, String? localDeviceId) =>
      Container(
        decoration: BoxDecoration(
          color: MacPalette.group(0.22),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: MacPalette.hairline, width: 0.7),
        ),
        child: Column(
          children: [
            for (final (i, device) in devices.indexed) ...[
              if (i > 0)
                const Divider(height: 0.5, thickness: 0.5, indent: 12),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: device.online
                            ? MacPalette.green
                            : MacPalette.textTertiary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${device.name}${device.id == localDeviceId ? ' (本机)' : ''}',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${device.platform} · ${device.online ? '在线' : '离线'}',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: MacPalette.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );

  Widget _buildFooter(DropDrawerController c) {
    final text = c.statusBanner ??
        (c.p2pReady
            ? 'iroh P2P 就绪 · 局域网与公网直连优先'
            : '当前运行在云端中转模式');

    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: MacPalette.hairline, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 10.5,
                color: MacPalette.textTertiary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${c.items.length} 项',
            style: TextStyle(
              fontSize: 10.5,
              color: MacPalette.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

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
            if (hasDevice) '来自 $cleanDeviceName',
            // Text lives on the server, so it never depends on the source device.
            if (item.kind == 'file' && !c.canDownloadP2p(item) && !item.cloudReady)
              '来源离线',
          ]
        : <String>[
            formatBytes(item.size),
            if (c.canDownloadP2p(item) && item.cloudReady)
              'P2P · 云端'
            else if (c.canDownloadP2p(item))
              'P2P 直连'
            else if (item.cloudReady)
              item.storageBackendName ?? '已存云盘'
            else
              '来源离线',
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
                    MacIconButton(
                      icon: CupertinoIcons.link,
                      tooltip: '创建外链分享',
                      size: isMobile ? 16 : 13.5,
                      boxSize: actionBox,
                      onPressed: widget.onShare,
                    ),
                    MacIconButton(
                      icon: CupertinoIcons.doc_on_doc,
                      tooltip: '复制文本',
                      size: isMobile ? 16.5 : 14,
                      boxSize: actionBox,
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(text: item.textContent ?? item.name),
                        );
                        c.setBanner('已复制到剪贴板');
                      },
                    ),
                  ] else ...[
                    MacIconButton(
                      icon: CupertinoIcons.link,
                      tooltip: '创建外链分享',
                      size: isMobile ? 16 : 13.5,
                      boxSize: actionBox,
                      onPressed: widget.onShare,
                    ),
                    if (isMine && !item.cloudReady && localPath != null)
                      MacIconButton(
                        icon: CupertinoIcons.cloud_upload,
                        tooltip: '转存到云盘 (离线可下)',
                        size: isMobile ? 17 : 14.5,
                        boxSize: actionBox,
                        onPressed: () => c.cacheItemToCloud(item.id, localPath),
                      ),
                    if (localPath != null && c.windowService.supportsEdgeDrawer) ...[
                      MacIconButton(
                        icon: CupertinoIcons.doc_on_doc,
                        tooltip: c.windowService.isWindows
                            ? '复制文件 (可直接 Ctrl+V 粘贴到资源管理器)'
                            : '复制文件 (可直接 ⌘V 粘贴到微信/访达)',
                        size: 14,
                        onPressed: () async {
                          final ok = await c.windowService
                              .copyFileToClipboard(localPath);
                          c.setBanner(ok ? '已复制文件，可直接 ${c.windowService.pasteShortcutLabel} 粘贴' : '复制文件失败');
                        },
                      ),
                      MacIconButton(
                        icon: CupertinoIcons.folder,
                        tooltip: c.windowService.isWindows
                            ? '在资源管理器中显示 (也可直接按住卡片拖出)'
                            : '在访达中显示 (也可直接按住卡片拖出)',
                        size: 14.5,
                        onPressed: () => c.windowService.revealInFinder(localPath),
                      ),
                    ] else if (localPath != null && isMobile) ...[
                      MacIconButton(
                        icon: CupertinoIcons.share,
                        tooltip: '系统分享 / 其他应用打开',
                        size: 17.5,
                        boxSize: actionBox,
                        onPressed: () async {
                          final ok = await c.windowService
                              .shareFilesNative([localPath]);
                          if (!ok) c.setBanner('打开系统分享失败');
                        },
                      ),
                    ] else
                      MacIconButton(
                        icon: CupertinoIcons.arrow_down_circle,
                        tooltip: c.canDownloadP2p(item) ? 'P2P 优先下载' : '从云端下载',
                        color: MacPalette.textPrimary,
                        size: isMobile ? 19 : 16,
                        boxSize: actionBox,
                        onPressed: () => c.downloadItem(item),
                      ),
                  ],
                  if (_hovered)
                    MacIconButton(
                      icon: CupertinoIcons.xmark,
                      tooltip: '移出抽屉',
                      size: 13,
                      onPressed: () async {
                        try {
                          await c.deleteItem(item.id);
                        } catch (e) {
                          c.setBanner('移出失败：$e');
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
              builder: (context, _) => _buildTransferSection(c, item, isMobile),
            ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTransferSection(
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
              value: progress.fraction > 0 ? progress.fraction : null,
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
              Text(
                switch (progress.channel) {
                  'preparing' => '正在准备下载',
                  'upload' => '正在上传到云盘',
                  'p2p_connecting' => '正在建立 P2P 连接',
                  'p2p_replica' => 'P2P 局域网副本',
                  'p2p_direct' => 'P2P 端到端直连',
                  'p2p_relay' => 'P2P 加密中继',
                  _ => '云端高速下载',
                },
                style: TextStyle(
                  fontSize: isMobile ? 12 : 10,
                  color: MacPalette.textTertiary,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${(progress.fraction * 100).toStringAsFixed(0)}%'
                    '${progress.speedBps > 0 ? ' · ${formatBytes(progress.speedBps)}/s' : ''}',
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
                      c.isCancelling(item.id) ? '正在取消' : (progress.channel == 'upload' ? '取消上传' : '取消下载'),
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
                  '正在发送给 ${c.recipientName(entry.value.sendingTo!)} · ${(entry.value.fraction * 100).floor()}%',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: isMobile ? 12 : 10, color: MacPalette.textSecondary),
                ),
              ),
              CupertinoButton(
                minimumSize: const Size(0, 24),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                onPressed: c.isCancellingSend(entry.key) ? null : () => c.cancelOutgoingTransfer(entry.key),
                child: Text(c.isCancellingSend(entry.key) ? '正在取消' : '取消发送', style: TextStyle(fontSize: isMobile ? 12 : 10, color: MacPalette.red)),
              ),
            ],
          ),
        if (hasTransferError) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  '传输失败：${progress.error}',
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
                  '重试',
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

  Widget _buildContent() {
    final radius = BorderRadius.circular(size * 0.22);
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
          errorBuilder: (_, _, _) =>
              Icon(_resolveIcon(), size: 17, color: MacPalette.textPrimary),
        ),
      );
    }
    return Icon(_resolveIcon(), size: 17, color: MacPalette.textPrimary);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: MacPalette.fill(0.08),
            borderRadius: BorderRadius.circular(size * 0.235),
            border: Border.all(
              color: MacPalette.fill(0.1),
              width: 0.5,
            ),
          ),
          child: _buildContent(),
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
}


/// Placeholder for a dropped file that is still being added to the drawer.
class _PendingDropTile extends StatelessWidget {
  final PendingDrop drop;
  final bool isMobile;

  const _PendingDropTile({required this.drop, required this.isMobile});

  @override
  Widget build(BuildContext context) {
    final box = isMobile ? 44.0 : 34.0;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 10,
        vertical: isMobile ? 11 : 9,
      ),
      decoration: BoxDecoration(
        color: MacPalette.cardBg,
        borderRadius: BorderRadius.circular(isMobile ? 12 : 10),
      ),
      child: Row(
        children: [
          Container(
            width: box,
            height: box,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: MacPalette.fill(0.08),
              borderRadius: BorderRadius.circular(box * 0.235),
            ),
            child: const AdaptiveSpinner(radius: 7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  drop.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isMobile ? 15 : 12.5,
                    fontWeight: FontWeight.w500,
                    color: MacPalette.textSecondary,
                  ),
                ),
                SizedBox(height: isMobile ? 3 : 2),
                Text(
                  '正在加入抽屉…',
                  style: TextStyle(
                    fontSize: isMobile ? 12.5 : 10.5,
                    color: MacPalette.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Short Chinese relative time, e.g. 刚刚 / 5 分钟前 / 昨天 / 3月2日.
@visibleForTesting
String relativeTimeLabel(DateTime time, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final local = time.toLocal();
  final diff = current.difference(local);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(local.year, local.month, local.day);
  final days = today.difference(day).inDays;
  if (days == 0) return '${diff.inHours} 小时前';
  if (days == 1) return '昨天';
  if (local.year == current.year) return '${local.month}月${local.day}日';
  return '${local.year}年${local.month}月${local.day}日';
}
