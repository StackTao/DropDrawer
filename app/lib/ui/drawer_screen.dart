import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../models/models.dart';
import '../services/drawer_window_service.dart';
import '../state/drawer_controller.dart';
import 'item_preview_view.dart';
import 'phone_page.dart';
import 'preferences_view.dart';
import 'share_view.dart';
import 'storage_settings_view.dart';
import 'theme.dart';
import 'announcement_banner.dart';
import 'update_banner.dart';
import '../l10n/l10n.dart';

part 'drawer_item_tiles.dart';

enum _DrawerPage { drawer, storage, devices, share, preview, preferences }

class DrawerScreen extends StatefulWidget {
  final DropDrawerController controller;

  const DrawerScreen({super.key, required this.controller});

  @override
  State<DrawerScreen> createState() => _DrawerScreenState();
}

class _DrawerScreenState extends State<DrawerScreen>
    with SingleTickerProviderStateMixin {
  bool _isDragHovering = false;
  Timer? _dragLeaveTimer;
  late final AnimationController _glowPulseCtrl;
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
  // Phones push secondary pages as routes; they close with this screen.
  NavigatorState? _navigator;
  final List<Route<void>> _phoneRoutes = [];
  bool _active = true;

  @override
  void initState() {
    super.initState();
    _glowPulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    widget.controller.windowService.onPasteShortcut = _pasteFromClipboard;
    widget.controller.windowService.setMainDrawerActive(true);
    _shownBannerSerial = widget.controller.bannerSerial;
    _searchFocusNode.addListener(_syncMainDrawerShortcutState);
    if (widget.controller.windowService.isMobile) {
      // Focusing enters search; losing focus with no active query/filter exits cleanly.
      _searchFocusNode.addListener(() {
        if (!mounted) return;
        if (_searchFocusNode.hasFocus && !_searchOpen) {
          setState(() => _searchOpen = true);
        } else if (!_searchFocusNode.hasFocus &&
            _searchOpen &&
            _searchCtrl.text.trim().isEmpty &&
            _filterKind == 'all') {
          setState(() => _searchOpen = false);
        }
      });
      _mobileLifecycle = AppLifecycleListener(
        onResume: () => unawaited(widget.controller.refreshOnResume()),
      );
      unawaited(widget.controller.checkPendingMobileShares());
    }
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.maybeOf(context);
  }

  @override
  void dispose() {
    // Signing out replaces this screen; pages pushed from it must go too.
    final navigator = _navigator;
    final routes = List<Route<void>>.of(_phoneRoutes);
    if (navigator != null && routes.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final route in routes) {
          if (route.isActive) navigator.removeRoute(route);
        }
      });
    }
    _searchFocusNode.removeListener(_syncMainDrawerShortcutState);
    _closeWindowsMoreMenu(widget.controller);
    _mobileLifecycle?.dispose();
    _mobileLifecycle = null;
    _hideCapsule();
    widget.controller.windowService.onPasteShortcut = null;
    widget.controller.windowService.setMainDrawerActive(false);
    _shortcutFocusNode.dispose();
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
    _dragLeaveTimer?.cancel();
    _dragLeaveTimer = null;
    _glowPulseCtrl.dispose();
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

  /// Negotiate an OLE/Cocoa drop operation supported by the drag source.
  /// Text drags on Windows (browsers/editors/chat apps) sometimes advertise
  /// only `move` without `copy`; returning `copy` in that case makes Win32
  /// OLE mask the effect to `DROPEFFECT_NONE` and destabilizes hover state.
  static DropOperation _preferredDropOperation(Set<DropOperation> allowed) {
    if (allowed.contains(DropOperation.copy)) return DropOperation.copy;
    if (allowed.contains(DropOperation.move)) return DropOperation.move;
    if (allowed.contains(DropOperation.link)) return DropOperation.link;
    return DropOperation.copy;
  }

  void _setDragHovering(bool hovering) {
    if (hovering) {
      _dragLeaveTimer?.cancel();
      _dragLeaveTimer = null;
    }
    if (_isDragHovering == hovering) return;
    if (hovering) {
      _glowPulseCtrl.repeat(reverse: true);
    } else {
      _glowPulseCtrl
        ..stop()
        ..value = 0;
    }
    setState(() => _isDragHovering = hovering);
  }

  /// Debounce transient `onDropLeave` / `onDropEnded` bursts on Windows where
  /// Win32 OLE text-drag previews briefly steal focus over topmost/Acrylic
  /// windows and emit single-frame `DragLeave → DragEnter` jitter.
  void _scheduleDragHoverEnd() {
    _dragLeaveTimer?.cancel();
    _dragLeaveTimer = Timer(const Duration(milliseconds: 140), () {
      _dragLeaveTimer = null;
      if (!mounted) return;
      _setDragHovering(false);
    });
  }

  String _dropPolicyHint(DropDrawerController c) {
    if (c.defaultDropPolicy == 'p2p_only') {
      return l10n.p2pEndToEndOnThis;
    }
    if (c.defaultDropPolicy == 'cloud_cached') {
      return l10n.policyAlwaysUploadShort(c.defaultStorageBackendName);
    }
    return l10n.policySmartShort(c.autoCloudThresholdBytes ~/ (1024 * 1024));
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
    if (widget.controller.windowService.isMobile) {
      if (target != _DrawerPage.drawer) {
        _pushPhonePage(target, shareItems: shareItems, previewItemId: previewItemId);
      }
      return;
    }
    setState(() {
      _page = target;
      _shareTargetItems =
          target == _DrawerPage.share ? (shareItems ?? const []) : const [];
      _previewItemId = target == _DrawerPage.preview ? previewItemId : null;
    });
    _syncMainDrawerShortcutState();
  }

  /// Opens a secondary page on a phone with the platform's page transition
  /// (iOS: slide in, swipe from the left edge to go back).
  void _pushPhonePage(
    _DrawerPage target, {
    List<DrawerItem>? shareItems,
    String? previewItemId,
  }) {
    final c = widget.controller;
    var closing = false;

    Widget page(BuildContext context) {
      void back() {
        if (closing) return;
        closing = true;
        unawaited(Navigator.of(context).maybePop());
      }

      switch (target) {
        case _DrawerPage.storage:
          return StorageSettingsView(controller: c, onBack: back);
        case _DrawerPage.devices:
          return _buildDevicesView(c, onBack: back);
        case _DrawerPage.share:
          return ShareView(
            controller: c,
            targetItems: shareItems ?? const [],
            onBack: back,
          );
        case _DrawerPage.preferences:
          return PreferencesView(controller: c, onBack: back);
        case _DrawerPage.preview:
          final item = c.items.where((e) => e.id == previewItemId).firstOrNull;
          if (item == null) {
            // The item was removed (here or on another device).
            WidgetsBinding.instance.addPostFrameCallback((_) => back());
            return const SizedBox.shrink();
          }
          return ItemPreviewView(
            controller: c,
            item: item,
            onBack: back,
            onShare: () =>
                _switchPage(_DrawerPage.share, shareItems: [item]),
          );
        case _DrawerPage.drawer:
          return const SizedBox.shrink();
      }
    }

    Widget shell(BuildContext context) => UiDensity(
          touch: true,
          child: Scaffold(
            backgroundColor: MacPalette.background,
            body: ListenableBuilder(
              listenable: c,
              // After sign-out this screen is deactivated and the route is
              // about to be removed; its pages read this screen's state.
              builder: (context, _) =>
                  _active ? page(context) : const SizedBox.shrink(),
            ),
          ),
        );

    final Route<void> route = usesMaterialChrome(context)
        ? MaterialPageRoute<void>(builder: shell)
        : CupertinoPageRoute<void>(builder: shell);
    _phoneRoutes.add(route);
    unawaited(
      Navigator.of(context).push(route).whenComplete(() {
        _phoneRoutes.remove(route);
      }),
    );
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
      c.setBanner(next == 'left' ? l10n.dockedToTheLeftSideOf : l10n.dockedToTheRightSideOf);
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
      unawaited(_confirmAndQuit(c));
    }
  }

  Future<void> _confirmAndQuit(DropDrawerController c) async {
    final active = c.activeTransferCount;
    if (active <= 0) {
      await c.windowService.quitApp();
      return;
    }
    final confirmed = await showAdaptiveConfirm(
      context,
      title: l10n.transfersInProgress(active),
      message: l10n.quittingInterruptsTheCurrentTransfersUnfinished,
      confirmLabel: l10n.quitAnyway,
      cancelLabel: l10n.keepRunningInBackground,
      destructive: true,
    );
    if (!mounted) return;
    if (confirmed) {
      await c.windowService.setActiveTransferCount(0);
      await c.windowService.quitApp();
    } else if (c.windowService.edgeMode) {
      await c.windowService.collapseDrawer();
    }
  }

  Future<void> _confirmAndClearDrawer(DropDrawerController c) async {
    if (c.items.isEmpty) return;
    final confirmed = await showAdaptiveConfirm(
      context,
      title: l10n.clearAll,
      message: l10n.clearAllMessage(c.items.length),
      confirmLabel: l10n.clear,
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
      widget.controller.setBanner(l10n.filePickerFailed(e));
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
      widget.controller.setBanner(l10n.photoPickerFailed(e));
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
                ? l10n.screenshotPastedAndSyncedToThe
                : l10n.pastedFiles(paths.length),
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
        widget.controller.setBanner(l10n.foldersCanTBePastedDirectly);
        return;
      }

      widget.controller.setBanner(l10n.theClipboardIsEmptyYouCan);
    } catch (e) {
      widget.controller.setBanner(l10n.clipboardReadFailed(e));
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
              floatingActionButton: isMobile &&
                      usesMaterialChrome(context) &&
                      _page == _DrawerPage.drawer &&
                      !_selectionMode
                  ? FloatingActionButton.extended(
                      tooltip: l10n.add,
                      onPressed: _showAddSheet,
                      icon: const Icon(Icons.add),
                      label: Text(l10n.add),
                    )
                  : null,
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
                    // Phone navigation bars extend under the status bar.
                    top: false,
                    bottom: isMobile,
                    child: _wrapDesktopDropRegion(
                      c: c,
                      isMobile: isMobile,
                      child: Stack(
                        alignment: Alignment.topCenter,
                        fit: StackFit.expand,
                        children: [
                          _buildActivePage(context, c),
                          if (!isMobile && _page != _DrawerPage.drawer)
                            _buildSecondaryDropOverlay(c),
                          if (!isMobile)
                            _buildInnerEdgeGlow(radius),
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
          ),
        );
      },
    );
  }

  Widget _wrapDesktopDropRegion({
    required DropDrawerController c,
    required bool isMobile,
    required Widget child,
  }) {
    if (isMobile) return child;
    return DropRegion(
      formats: const [Formats.fileUri, Formats.plainText],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) {
        if (c.windowService.modalOpen) return DropOperation.none;
        _setDragHovering(true);
        return _preferredDropOperation(event.session.allowedOperations);
      },
      onDropLeave: (_) => _scheduleDragHoverEnd(),
      onDropEnded: (_) => _scheduleDragHoverEnd(),
      onPerformDrop: (event) => _handleDropSession(c, event),
      child: child,
    );
  }

  /// Website-inspired inner luminous halo around the window border while a
  /// file or text drag hovers over the drawer (zero layout shift).
  Widget _buildInnerEdgeGlow(double radius) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          opacity: _isDragHovering ? 1.0 : 0.0,
          child: AnimatedBuilder(
            animation: _glowPulseCtrl,
            builder: (_, _) => CustomPaint(
              painter: _InnerEdgeGlowPainter(
                color: MacPalette.accent,
                radius: radius,
                pulse: Curves.easeInOut.transform(_glowPulseCtrl.value),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Centered luminous drop prompt shown when dragging files/text onto any
  /// secondary desktop page (Settings, Storage, Devices, Share, Preview).
  Widget _buildSecondaryDropOverlay(DropDrawerController c) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          opacity: _isDragHovering ? 1.0 : 0.0,
          child: _isDragHovering
              ? ClipRect(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                    child: Container(
                      color: MacPalette.shade(0.58),
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 270),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 18,
                          ),
                          decoration: BoxDecoration(
                            color: MacPalette.elevatedBg.withValues(alpha: 0.94),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: MacPalette.accent.withValues(alpha: 0.68),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: MacPalette.accent.withValues(alpha: 0.28),
                                blurRadius: 28,
                                spreadRadius: -2,
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  color: MacPalette.accent,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: MacPalette.accent
                                          .withValues(alpha: 0.45),
                                      blurRadius: 16,
                                      spreadRadius: -2,
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  CupertinoIcons.tray_arrow_down_fill,
                                  size: 20,
                                  color: MacPalette.onAccent,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                l10n.releaseToDropIntoTheDrawer,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: MacPalette.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _dropPolicyHint(c),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: MacPalette.textSecondary,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
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
            message: l10n.moveDrawer,
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
    final pillRadius = isWindows ? 8.0 : 13.0;
    return DropRegion(
      formats: const [Formats.fileUri, Formats.plainText],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) =>
          _preferredDropOperation(event.session.allowedOperations),
      onPerformDrop: (event) => _handleDropSession(c, event, expandAfterDrop: true),
      child: Material(
        color: Colors.transparent,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: isWindows
                    ? (c.windowService.windowsBackdrop
                        ? const Color(0xB32B2B2B)
                        : const Color(0xFF2B2B2B))
                    : const Color(0xEC1C1C20),
                borderRadius: BorderRadius.circular(pillRadius),
                border: Border.all(
                  color: MacPalette.accent.withValues(alpha: 0.55),
                  width: 1.0,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: MacPalette.accent,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: MacPalette.accent.withValues(alpha: 0.45),
                          blurRadius: 10,
                          spreadRadius: -1,
                        ),
                      ],
                    ),
                    child: Icon(
                      CupertinoIcons.tray_arrow_down_fill,
                      size: 12,
                      color: MacPalette.onAccent,
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
                        l10n.dragHereToDropIntoThe,
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
            IgnorePointer(
              child: CustomPaint(
                painter: _InnerEdgeGlowPainter(
                  color: MacPalette.accent,
                  radius: pillRadius,
                  pulse: 0.35,
                  subtle: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleDropSession(
    DropDrawerController c,
    PerformDropEvent event, {
    bool expandAfterDrop = false,
  }) async {
    _dragLeaveTimer?.cancel();
    _dragLeaveTimer = null;
    _setDragHovering(false);
    // Interaction A: always bring the user back to the home drawer on drop so
    // the new item and its upload/P2P progress are immediately visible.
    if (_page != _DrawerPage.drawer) {
      _switchPage(_DrawerPage.drawer);
    }
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
        return _preferredDropOperation(event.session.allowedOperations);
      },
      onPerformDrop: (event) => _handleDropSession(c, event, expandAfterDrop: true),
      child: handle,
    );
  }

  Widget _buildActivePage(BuildContext context, DropDrawerController c) {
    // Desktop shows secondary pages in place; phones push them as routes.
    void back() => _switchPage(_DrawerPage.drawer);
    if (_page == _DrawerPage.storage) {
      return StorageSettingsView(controller: c, onBack: back);
    }
    if (_page == _DrawerPage.devices) {
      return _buildDevicesView(c);
    }
    if (_page == _DrawerPage.share) {
      return ShareView(
        controller: c,
        targetItems: _shareTargetItems,
        onBack: back,
      );
    }
    if (_page == _DrawerPage.preferences) {
      return PreferencesView(controller: c, onBack: back);
    }
    if (_page == _DrawerPage.preview && _previewItemId != null) {
      final found = c.items.where((e) => e.id == _previewItemId).toList();
      if (found.isNotEmpty) {
        final item = found.first;
        return ItemPreviewView(
          controller: c,
          item: item,
          onBack: back,
          onShare: () => _switchPage(_DrawerPage.share, shareItems: [item]),
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
          child: isMobile
              ? _buildPhoneHome(context, c, visibleItems)
              : Column(
                  children: [
                    _buildToolbar(context, c),
                    const Divider(height: 0.5, thickness: 0.5),
                    _buildDropHeader(c),
                    if (c.items.isNotEmpty)
                      _buildBatchActionStrip(c, visibleItems),
                    if (c.items.isNotEmpty && _searchOpen)
                      _buildSearchFilterBar(false),
                    Expanded(child: _buildItemList(context, c, visibleItems)),
                    if (_selectionMode)
                      _buildBatchFooter(c)
                    else ...[
                      AnnouncementBanner(controller: c, mobile: false),
                      UpdateBanner(updates: c.updates, mobile: false),
                      _buildFooter(c),
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  List<PhoneMenuEntry> _phoneAddEntries() => [
        PhoneMenuEntry(
          label: l10n.chooseFiles,
          icon: CupertinoIcons.doc,
          materialIcon: Icons.insert_drive_file_outlined,
          onSelected: _pickFiles,
        ),
        PhoneMenuEntry(
          label: l10n.photoLibrary,
          icon: CupertinoIcons.photo_on_rectangle,
          materialIcon: Icons.photo_library_outlined,
          onSelected: _pickMedia,
        ),
        PhoneMenuEntry(
          label: l10n.paste,
          icon: CupertinoIcons.doc_on_clipboard,
          materialIcon: Icons.content_paste,
          onSelected: _pasteFromClipboard,
        ),
      ];

  List<PhoneMenuEntry> _phoneMoreEntries(
    DropDrawerController c,
    List<DrawerItem> visibleItems,
  ) =>
      [
        if (c.items.isNotEmpty) ...[
          PhoneMenuEntry(
            label: l10n.select,
            icon: CupertinoIcons.checkmark_circle,
            materialIcon: Icons.checklist,
            onSelected: () => _enterSelectionMode(),
          ),
          PhoneMenuEntry(
            label: l10n.downloadAll,
            icon: CupertinoIcons.arrow_down_circle,
            materialIcon: Icons.download_outlined,
            onSelected: () => c.batchDownloadItems(visibleItems),
          ),
        ],
        PhoneMenuEntry(
          label: l10n.cloudStorage,
          icon: CupertinoIcons.cloud,
          materialIcon: Icons.cloud_outlined,
          startsGroup: true,
          onSelected: () => _switchPage(_DrawerPage.storage),
        ),
        PhoneMenuEntry(
          label: l10n.shareLinksTitle,
          icon: CupertinoIcons.link,
          materialIcon: Icons.link,
          onSelected: () => _switchPage(_DrawerPage.share),
        ),
        PhoneMenuEntry(
          label: l10n.devicesP2p,
          icon: CupertinoIcons.device_laptop,
          materialIcon: Icons.devices_outlined,
          onSelected: () => _switchPage(_DrawerPage.devices),
        ),
        PhoneMenuEntry(
          label: l10n.preferences,
          icon: CupertinoIcons.gear,
          materialIcon: Icons.settings_outlined,
          onSelected: () => _switchPage(_DrawerPage.preferences),
        ),
        if (c.items.isNotEmpty)
          PhoneMenuEntry(
            label: l10n.clearAll,
            icon: CupertinoIcons.trash,
            materialIcon: Icons.delete_sweep_outlined,
            destructive: true,
            startsGroup: true,
            onSelected: () => _confirmAndClearDrawer(c),
          ),
        PhoneMenuEntry(
          label: l10n.signOut,
          icon: CupertinoIcons.square_arrow_right,
          materialIcon: Icons.logout,
          destructive: true,
          startsGroup: c.items.isEmpty,
          onSelected: c.logout,
        ),
      ];

  /// Phone home: a large-title navigation bar (iOS) or large top app bar
  /// (Android) over the drawer list. Adding sits behind "+" on iOS and the
  /// floating button on Android; selecting turns the bar into a selection bar.
  Widget _buildPhoneHome(
    BuildContext context,
    DropDrawerController c,
    List<DrawerItem> visibleItems,
  ) {
    final material = usesMaterialChrome(context);
    final selecting = _selectionMode;
    final visibleIds = visibleItems.map((e) => e.id).toSet();
    final existingIds = c.items.map((e) => e.id).toSet();
    _selectedIds.removeWhere((id) => !existingIds.contains(id));
    final allSelected =
        visibleItems.isNotEmpty && visibleIds.every(_selectedIds.contains);
    void toggleAll() => setState(() {
          if (allSelected) {
            _selectedIds.removeAll(visibleIds);
          } else {
            _selectedIds.addAll(visibleIds);
          }
        });
    void finish() => setState(() {
          _selectionMode = false;
          _selectedIds.clear();
        });
    if (material) {
      return _buildMaterialHome(
        context,
        c,
        visibleItems,
        allSelected: allSelected,
        toggleAll: toggleAll,
        finish: finish,
      );
    }
    final title = Text(selecting ? l10n.selectedCount(_selectedIds.length) : 'DropDrawer');
    final more = PhoneMenuButton(
      icon: CupertinoIcons.ellipsis,
      materialIcon: Icons.more_vert,
      tooltip: l10n.more,
      entries: _phoneMoreEntries(c, visibleItems),
    );

    final navBar = CupertinoSliverNavigationBar(
      largeTitle: title,
      backgroundColor: MacPalette.background.withValues(alpha: 0.85),
      stretch: true,
      // iOS shows no hairline under an expanded large title.
      border: null,
      leading: selecting
          ? Material(
              type: MaterialType.transparency,
              child: Align(
                alignment: Alignment.centerLeft,
                child: LiquidGlassButton(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  onPressed: toggleAll,
                  child: Text(
                    allSelected ? l10n.deselectAll : l10n.selectAll,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: MacPalette.textPrimary,
                    ),
                  ),
                ),
              ),
            )
          : null,
      // The bar flies over the page transition outside the Scaffold; its
      // buttons need a Material ancestor there too.
      trailing: Material(
        type: MaterialType.transparency,
        child: selecting
            ? LiquidGlassButton(
                height: 36,
                tinted: true,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                onPressed: finish,
                child: Text(
                  l10n.done,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: MacPalette.accent,
                  ),
                ),
              )
            : more,
      ),
    );

    final searchingIos =
        !material && !selecting && c.items.isNotEmpty &&
        (_searchOpen || _searchCtrl.text.isNotEmpty || _filterKind != 'all');

    final scroll = CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: AlwaysScrollableScrollPhysics(
        parent: material
            ? const ClampingScrollPhysics()
            : const BouncingScrollPhysics(),
      ),
      slivers: [
        navBar,
        if (!material) CupertinoSliverRefreshControl(onRefresh: c.manualRefresh),
        if (!selecting)
          SliverToBoxAdapter(
            child: _buildPhoneStatus(c, visibleItems, material: material),
          ),
        if (searchingIos)
          SliverToBoxAdapter(child: _buildIosScopeBar()),
        _buildItemSliver(context, c, visibleItems),
        // Keep the last row clear of the floating add button / iOS 26 glass dock.
        if (!selecting)
          const SliverToBoxAdapter(child: SizedBox(height: 112)),
      ],
    );
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  if (_searchFocusNode.hasFocus) _searchFocusNode.unfocus();
                },
                child: scroll,
              ),
              if (!selecting)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _buildIosBottomDock(context, c),
                ),
            ],
          ),
        ),
        if (selecting)
          _buildBatchFooter(c)
        else ...[
          AnnouncementBanner(controller: c, mobile: true),
          UpdateBanner(updates: c.updates, mobile: true),
        ],
      ],
    );
  }

  /// Android home, after Files by Google / Gmail: a floating search bar is
  /// the top app bar (with the overflow menu inside it), a status chip and
  /// the item count below, full-width list items, and the add button. In
  /// multi-select a contextual top app bar replaces the search bar.
  Widget _buildMaterialHome(
    BuildContext context,
    DropDrawerController c,
    List<DrawerItem> visibleItems, {
    required bool allSelected,
    required VoidCallback toggleAll,
    required VoidCallback finish,
  }) {
    final selecting = _selectionMode;
    final searching = _searchOpen ||
        _searchCtrl.text.isNotEmpty ||
        _filterKind != 'all';
    const barHeight = 72.0;

    final Widget appBar;
    if (selecting) {
      appBar = SliverAppBar(
        pinned: true,
        backgroundColor: MacPalette.cardBg,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          tooltip: l10n.done,
          icon: const Icon(Icons.close),
          onPressed: finish,
        ),
        title: Text(l10n.selectedCount(_selectedIds.length)),
        actions: [
          IconButton(
            tooltip: allSelected ? l10n.deselectAll : l10n.selectAll,
            icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
            onPressed: toggleAll,
          ),
          const SizedBox(width: 4),
        ],
      );
    } else {
      appBar = SliverAppBar(
        floating: true,
        snap: true,
        automaticallyImplyLeading: false,
        toolbarHeight: barHeight,
        titleSpacing: 16,
        backgroundColor: MacPalette.background,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: _buildMaterialSearchBar(c, visibleItems, searching),
      );
    }

    final scroll = CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const AlwaysScrollableScrollPhysics(
        parent: ClampingScrollPhysics(),
      ),
      slivers: [
        appBar,
        if (!selecting)
          SliverToBoxAdapter(
            child: searching && c.items.isNotEmpty
                ? _buildMaterialFilterChips(c, visibleItems)
                : _buildMaterialStatus(c),
          ),
        _buildItemSliver(context, c, visibleItems),
        // Keep the last row clear of the floating add button.
        if (!selecting) const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: c.manualRefresh,
            edgeOffset: MediaQuery.paddingOf(context).top + barHeight,
            child: scroll,
          ),
        ),
        if (selecting)
          _buildBatchFooter(c)
        else ...[
          AnnouncementBanner(controller: c, mobile: true),
          UpdateBanner(updates: c.updates, mobile: true),
        ],
      ],
    );
  }

  /// The Material 3 search bar that heads the Android home. Searching swaps
  /// the search icon for a back arrow and the overflow menu for clear.
  Widget _buildMaterialSearchBar(
    DropDrawerController c,
    List<DrawerItem> visibleItems,
    bool searching,
  ) {
    return SearchBar(
      controller: _searchCtrl,
      focusNode: _searchFocusNode,
      hintText: l10n.searchDropdrawer,
      constraints: const BoxConstraints(minHeight: 56, maxHeight: 56),
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(MacPalette.elevatedBg),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 4),
      ),
      textStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 16, color: MacPalette.textPrimary),
      ),
      hintStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 16, color: MacPalette.textSecondary),
      ),
      leading: searching
          ? IconButton(
              tooltip: l10n.closeSearch,
              icon: const Icon(Icons.arrow_back),
              onPressed: _closeSearch,
            )
          : const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Icon(Icons.search),
            ),
      trailing: [
        if (_searchCtrl.text.isNotEmpty)
          IconButton(
            tooltip: l10n.clearSearch,
            icon: const Icon(Icons.close),
            onPressed: () => setState(_searchCtrl.clear),
          )
        else if (!searching)
          PhoneMenuButton(
            icon: CupertinoIcons.ellipsis,
            materialIcon: Icons.more_vert,
            tooltip: l10n.more,
            entries: _phoneMoreEntries(c, visibleItems),
          ),
      ],
      onTap: () {
        if (!_searchOpen) setState(() => _searchOpen = true);
      },
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _searchFocusNode.unfocus(),
    );
  }

  /// Android: connection state as an assist chip (opens the device page)
  /// with the item count at the end of the line.
  Widget _buildMaterialStatus(DropDrawerController c) {
    final status = !c.wsConnected
        ? l10n.connecting
        : l10n.devicesOnline(c.onlineDeviceCount);
    final dotColor = c.wsConnected
        ? (c.p2pReady ? MacPalette.green : MacPalette.accent)
        : MacPalette.red;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 20, 4),
      child: Row(
        children: [
          Flexible(
            child: ActionChip(
            avatar: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dotColor,
              ),
            ),
            label: Text(status),
            labelStyle: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: MacPalette.textPrimary,
            ),
            side: BorderSide(color: MacPalette.hairline),
            backgroundColor: MacPalette.background,
            onPressed: () => _switchPage(_DrawerPage.devices),
          ),
          ),
          const Spacer(),
          if (c.items.isNotEmpty)
            Text(
              l10n.itemsCount(c.items.length),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: MacPalette.textSecondary,
              ),
            ),
        ],
      ),
    );
  }

  /// Android search filters: Material 3 filter chips and the match count.
  Widget _buildMaterialFilterChips(
    DropDrawerController c,
    List<DrawerItem> visibleItems,
  ) {
    final scopes = [('all', l10n.all), ('file', l10n.file), ('text', l10n.text)];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 20, 4),
      child: Row(
        children: [
          for (final (kind, label) in scopes) ...[
            FilterChip(
              label: Text(label),
              selected: _filterKind == kind,
              showCheckmark: false,
              onSelected: (_) => setState(() => _filterKind = kind),
            ),
            const SizedBox(width: 8),
          ],
          const Spacer(),
          Text(
            '${visibleItems.length}/${c.items.length}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: MacPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// Native iOS scope filter shown below the header while searching.
  Widget _buildIosScopeBar() {
    final scopes = [('all', l10n.all), ('file', l10n.file), ('text', l10n.text)];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: CupertinoSlidingSegmentedControl<String>(
        groupValue: _filterKind,
        children: {
          for (final (kind, label) in scopes)
            kind: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(label, style: const TextStyle(fontSize: 13.5)),
            ),
        },
        onValueChanged: (kind) {
          if (kind != null) setState(() => _filterKind = kind);
        },
      ),
    );
  }

  /// iOS 26 floating bottom dock: search capsule (when items exist) paired
  /// with a detached circular "+" button (or "×" to leave active search).
  Widget _buildIosBottomDock(BuildContext context, DropDrawerController c) {
    final active = _searchOpen ||
        _searchCtrl.text.isNotEmpty ||
        _filterKind != 'all';
    final showSearch = c.items.isNotEmpty;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            MacPalette.background.withValues(alpha: 0.0),
            MacPalette.background.withValues(alpha: 0.88),
            MacPalette.background,
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(
            mainAxisAlignment:
                showSearch ? MainAxisAlignment.start : MainAxisAlignment.end,
            children: [
              if (showSearch) ...[
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (!_searchOpen) setState(() => _searchOpen = true);
                      _searchFocusNode.requestFocus();
                    },
                    child: LiquidGlass(
                      borderRadius: BorderRadius.circular(24),
                      blur: 26,
                      child: SizedBox(
                        height: 48,
                        child: Row(
                          children: [
                            const SizedBox(width: 15),
                            Icon(
                              CupertinoIcons.search,
                              size: 18,
                              color: MacPalette.textSecondary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _searchCtrl,
                                focusNode: _searchFocusNode,
                                textInputAction: TextInputAction.search,
                                onTap: () {
                                  if (!_searchOpen) {
                                    setState(() => _searchOpen = true);
                                  }
                                },
                                onChanged: (_) => setState(() {}),
                                onSubmitted: (_) => _searchFocusNode.unfocus(),
                                style: TextStyle(
                                  fontSize: 16,
                                  letterSpacing: -0.32,
                                  color: MacPalette.textPrimary,
                                ),
                                cursorColor: MacPalette.accent,
                                decoration: InputDecoration.collapsed(
                                  hintText: l10n.search,
                                  hintStyle: TextStyle(
                                    fontSize: 16,
                                    letterSpacing: -0.32,
                                    color: MacPalette.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                            if (_searchCtrl.text.isNotEmpty)
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => setState(_searchCtrl.clear),
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Icon(
                                    CupertinoIcons.clear_circled_solid,
                                    size: 18,
                                    color: MacPalette.textTertiary,
                                  ),
                                ),
                              )
                            else
                              const SizedBox(width: 12),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              if (active && showSearch)
                LiquidGlassButton(
                  width: 48,
                  height: 48,
                  onPressed: _closeSearch,
                  child: Icon(
                    CupertinoIcons.xmark,
                    size: 18,
                    color: MacPalette.textPrimary,
                  ),
                )
              else
                PhoneMenuButton(
                  icon: CupertinoIcons.plus,
                  materialIcon: Icons.add,
                  tooltip: l10n.add,
                  prominent: true,
                  entries: _phoneAddEntries(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Android: the add choices as a Material 3 bottom sheet.
  Future<void> _showAddSheet() async {
    final entries = _phoneAddEntries();
    final chosen = await showModalBottomSheet<PhoneMenuEntry>(
      context: context,
      showDragHandle: true,
      backgroundColor: MacPalette.elevatedBg,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in entries)
              ListTile(
                leading: Icon(entry.materialIcon),
                title: Text(entry.label),
                onTap: () => Navigator.of(context).pop(entry),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    chosen?.onSelected();
  }

  /// Under the phone title (Android) or above the inset-grouped list (iOS):
  /// connection state and online devices (opens the device page) and the item count.
  Widget _buildPhoneStatus(
    DropDrawerController c,
    List<DrawerItem> visibleItems, {
    required bool material,
  }) {
    final isFiltering =
        _filterKind != 'all' || _searchCtrl.text.trim().isNotEmpty;
    final status = !c.wsConnected
        ? l10n.connecting
        : l10n.devicesOnline(c.onlineDeviceCount);
    final label = isFiltering
        ? l10n.statusFiltered(status, visibleItems.length, c.items.length)
        : (c.items.isEmpty ? status : l10n.statusItems(status, c.items.length));
    return Padding(
      padding: material
          ? const EdgeInsets.fromLTRB(16, 0, 16, 2)
          : const EdgeInsets.fromLTRB(20, 0, 16, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          onTap: () => _switchPage(_DrawerPage.devices),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: material ? 8 : 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: material ? 8 : 7,
                  height: material ? 8 : 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.wsConnected
                        ? (c.p2pReady ? MacPalette.green : MacPalette.accent)
                        : MacPalette.red,
                  ),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: material ? 15 : 13.5,
                      letterSpacing: material ? null : -0.1,
                      color: MacPalette.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                Icon(
                  CupertinoIcons.chevron_right,
                  size: material ? 14 : 12,
                  color: MacPalette.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _closeSearch() {
    setState(() {
      _searchOpen = false;
      _searchCtrl.clear();
      _filterKind = 'all';
      _searchFocusNode.unfocus();
    });
    _syncMainDrawerShortcutState();
  }

  /// A phone list row: an iOS inset grouped row (rounded group, inset
  /// separators, swipe to remove, long-press menu) or a Material 3 list item
  /// (swipe to remove with undo, long press selects).
  Widget _buildPhoneEntry(
    BuildContext context,
    DropDrawerController c,
    List<DrawerItem> visibleItems,
    int index,
  ) {
    final material = usesMaterialChrome(context);
    final pending = c.pendingDrops;
    final last = index == _listEntryCount(c, visibleItems) - 1;
    final radius = material
        ? BorderRadius.zero
        : BorderRadius.vertical(
            top: Radius.circular(index == 0 ? 16 : 0),
            bottom: Radius.circular(last ? 16 : 0),
          );
    Widget frame(Widget child, {bool selected = false}) => _PhoneRowFrame(
          material: material,
          radius: radius,
          separator: !last && !material,
          selected: selected,
          child: child,
        );
    if (index < pending.length) {
      return frame(_PendingDropTile(drop: pending[index], isMobile: true, framed: true));
    }
    final item = visibleItems[index - pending.length];
    final selected = _selectedIds.contains(item.id);
    void toggle() => setState(() {
          if (!_selectedIds.remove(item.id)) _selectedIds.add(item.id);
        });
    final row = frame(
      _PhoneItemRow(
        controller: c,
        item: item,
        localPath: c.localFilePaths[item.id],
        material: material,
        selectionMode: _selectionMode,
        selected: selected,
        onTap: _selectionMode
            ? toggle
            : () => _switchPage(_DrawerPage.preview, previewItemId: item.id),
        onLongPress: material && !_selectionMode
            ? () {
                HapticFeedback.mediumImpact();
                _enterSelectionMode(item.id);
              }
            : null,
      ),
      selected: selected,
    );
    if (_selectionMode) return row;
    if (material) {
      return Dismissible(
        key: ValueKey('mobile_item_${item.id}'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          color: MacPalette.red,
          child: Icon(Icons.delete_outline, color: MacPalette.onAccent),
        ),
        onDismissed: (_) => _deleteWithUndo(c, item),
        child: row,
      );
    }
    return PhoneSwipeToDelete(
      key: ValueKey('mobile_item_${item.id}'),
      borderRadius: radius,
      onDelete: () => _deleteNow(c, item),
      // The menu previews the row in an unbounded box; give it its width.
      child: LayoutBuilder(
        builder: (context, constraints) => CupertinoContextMenu(
          actions: _itemContextActions(c, item),
          child: SizedBox(width: constraints.maxWidth, child: row),
        ),
      ),
    );
  }

  /// iOS long-press menu for an item.
  List<Widget> _itemContextActions(DropDrawerController c, DrawerItem item) {
    final localPath = c.localFilePaths[item.id];
    final isMine = item.ownerDeviceId == c.deviceId;
    Widget action(
      String label,
      IconData icon,
      VoidCallback onPressed, {
      bool destructive = false,
    }) =>
        CupertinoContextMenuAction(
          trailingIcon: icon,
          isDestructiveAction: destructive,
          onPressed: () {
            Navigator.of(context).pop();
            onPressed();
          },
          child: Text(label),
        );
    return [
      if (item.kind == 'text')
        action(l10n.copyText, CupertinoIcons.doc_on_doc, () {
          Clipboard.setData(ClipboardData(text: item.textContent ?? item.name));
          c.setBanner(l10n.copiedToClipboard);
        })
      else if (localPath != null)
        action(l10n.share, CupertinoIcons.share, () async {
          final ok = await c.windowService.shareFilesNative([localPath]);
          if (!ok) c.setBanner(l10n.couldnTOpenTheShareSheet);
        })
      else
        action(l10n.downloads, CupertinoIcons.arrow_down_circle, () => c.downloadItem(item)),
      if (c.canCreateShares)
        action(l10n.createShareLink2, CupertinoIcons.link,
            () => _switchPage(_DrawerPage.share, shareItems: [item])),
      if (item.kind == 'file' && isMine && !item.cloudReady && localPath != null &&
          c.canUploadToCloud)
        action(l10n.saveToCloudAction, CupertinoIcons.cloud_upload,
            () => c.cacheItemToCloud(item.id, localPath)),
      action(l10n.select, CupertinoIcons.checkmark_circle,
          () => _enterSelectionMode(item.id)),
      action(l10n.remove, CupertinoIcons.trash, () => _deleteNow(c, item),
          destructive: true),
    ];
  }

  /// Removes an item without an undo window (iOS asks for an explicit swipe
  /// or menu choice first).
  void _deleteNow(DropDrawerController c, DrawerItem item) {
    setState(() {
      _pendingDeletes[item.id] = Timer(
        Duration.zero,
        () => unawaited(_commitDelete(c, item.id)),
      );
    });
  }

  void _toggleSearch() {
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
  }

  Widget _buildSearchToggle({required bool isMobile, required bool active}) {
    return GestureDetector(
      onTap: _toggleSearch,
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
            color: active ? MacPalette.textPrimary : MacPalette.textSecondary,
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
                            l10n.devicesOnlineShort(c.onlineDeviceCount),
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
                    ? l10n.pinnedOpenClickToHideAutomatically
                    : l10n.hidesAutomaticallyWhenYouLeaveClick,
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
                tooltip: l10n.collapseToEdgeEsc,
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
                tooltip: isEdge ? l10n.switchToARegularWindow : l10n.switchToTheEdgeDrawer,
                size: 14,
                onPressed: () => c.windowService.setEdgeDrawerMode(!isEdge),
              ),
              const SizedBox(width: 2),
            ],
            MacIconButton(
              icon: CupertinoIcons.cloud,
              tooltip: l10n.cloudStorageTransferStorage,
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
                  tooltip: l10n.more,
                  size: 15,
                  onPressed: () => _openNativeMoreMenu(c),
                ),
              )
            else
              _buildPhoneMoreMenu(
                c,
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

  /// The "more" menu where the native macOS/Windows menus are unavailable
  /// (phones, other desktops).
  Widget _buildPhoneMoreMenu(DropDrawerController c, {required Widget child}) {
    final isMobile = c.windowService.isMobile;
    return PopupMenuButton<String>(
      tooltip: l10n.more,
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
              Text(l10n.shareLinksTitle, style: TextStyle(fontSize: isMobile ? 14 : 12)),
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
              Text(l10n.deviceStatus, style: TextStyle(fontSize: isMobile ? 14 : 12)),
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
              Text(l10n.preferences, style: TextStyle(fontSize: isMobile ? 14 : 12)),
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
                Text(l10n.clearDrawer, style: TextStyle(fontSize: 14, color: MacPalette.red)),
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
                l10n.signOut,
                style: TextStyle(
                  fontSize: isMobile ? 14 : 12,
                  color: MacPalette.red,
                ),
              ),
            ],
          ),
        ),
      ],
      child: child,
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
      tooltip: l10n.more,
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
        entry('shares', l10n.shareLinksTitle, CupertinoIcons.link),
        entry('devices', l10n.deviceStatus, CupertinoIcons.device_laptop),
        entry('preferences', l10n.preferences, CupertinoIcons.gear_alt),
        entry(
          'toggle_dock_side',
          dockLeft ? l10n.dockRight : l10n.dockLeft,
          dockLeft ? CupertinoIcons.sidebar_right : CupertinoIcons.sidebar_left,
        ),
        PopupMenuDivider(
          height: 8,
          indent: 12,
          endIndent: 12,
          color: MacPalette.hairline,
        ),
        entry('logout', l10n.signOut, CupertinoIcons.square_arrow_right),
        entry('quit', l10n.quit, CupertinoIcons.power, destructive: true),
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
                      ? MacPalette.accent.withValues(alpha: 0.16)
                      : MacPalette.fill(0.05),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color: _isDragHovering
                        ? MacPalette.accent.withValues(alpha: 0.72)
                        : MacPalette.hairline,
                    width: 1.0,
                  ),
                  boxShadow: _isDragHovering
                      ? [
                          BoxShadow(
                            color: MacPalette.accent.withValues(alpha: 0.24),
                            blurRadius: 16,
                            spreadRadius: -2,
                          ),
                        ]
                      : const [],
                ),
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: _isDragHovering
                            ? MacPalette.accent
                            : MacPalette.fill(0.08),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: _isDragHovering
                            ? [
                                BoxShadow(
                                  color: MacPalette.accent
                                      .withValues(alpha: 0.42),
                                  blurRadius: 10,
                                  spreadRadius: -1,
                                ),
                              ]
                            : const [],
                      ),
                      child: Icon(
                        _isDragHovering
                            ? CupertinoIcons.tray_arrow_down_fill
                            : CupertinoIcons.plus,
                        size: 16,
                        color: _isDragHovering
                            ? MacPalette.onAccent
                            : MacPalette.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isDragHovering
                                ? l10n.releaseToDropIntoTheDrawer2
                                : l10n.dropPickOrPaste(c.windowService.pasteShortcutLabel),
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: _isDragHovering
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: MacPalette.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            _dropPolicyHint(c),
                            style: TextStyle(
                              fontSize: 10.5,
                              color: _isDragHovering
                                  ? MacPalette.textSecondary
                                  : MacPalette.textTertiary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    MacIconButton(
                      icon: CupertinoIcons.doc_on_clipboard,
                      tooltip: l10n.smartPasteTooltip(c.windowService.pasteShortcutLabel),
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
              ('smart', l10n.smartPolicyShort(c.autoCloudThresholdBytes ~/ (1024 * 1024))),
              ('p2p_only', l10n.policyP2pOnly),
              ('cloud_cached', l10n.alwaysSaveToCloud),
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
              label: allSelected ? l10n.deselectAll : l10n.selectAllCount(visibleItems.length),
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
            Flexible(
              child: Text(
                l10n.selectedCount(_selectedIds.length),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: isMobile ? 12 : 10.5,
                  color: MacPalette.textTertiary,
                ),
              ),
            ),
            const Spacer(),
            _miniTextAction(
              label: l10n.done,
              color: MacPalette.textPrimary,
              isMobile: isMobile,
              onTap: () => setState(() {
                _selectionMode = false;
                _selectedIds.clear();
              }),
            ),
          ] else ...[
            Flexible(
              child: Text(
                isFiltering
                    ? l10n.filteredResults(visibleItems.length, c.items.length)
                    : l10n.drawerItemsCount(c.items.length),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: isMobile ? 13.5 : 10.5,
                  color: MacPalette.textTertiary,
                ),
              ),
            ),
            const Spacer(),
            _buildSearchToggle(
              isMobile: isMobile,
              active: _searchOpen || isFiltering,
            ),
            if (!isMobile) ...[
              const SizedBox(width: 8),
              _miniTextAction(
                label: l10n.multiSelect,
                onTap: () => _enterSelectionMode(),
              ),
              const SizedBox(width: 10),
              _miniTextAction(
                label: l10n.downloadAll,
                onTap: () => c.batchDownloadItems(visibleItems),
              ),
            ],
            if (!isMobile) ...[
              const SizedBox(width: 10),
              if (_confirmingClear) ...[
                _miniTextAction(
                  label: l10n.confirmClear,
                  color: MacPalette.red,
                  onTap: () async {
                    setState(() => _confirmingClear = false);
                    await c.clearDrawer();
                  },
                ),
                const SizedBox(width: 6),
                _miniTextAction(
                  label: l10n.cancel,
                  onTap: () => setState(() => _confirmingClear = false),
                ),
              ] else
                _miniTextAction(
                  label: l10n.clear,
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
                        hintText: l10n.searchFileNamesOrText,
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
          _filterPill('all', l10n.all),
          const SizedBox(width: 4),
          _filterPill('file', l10n.file),
          const SizedBox(width: 4),
          _filterPill('text', l10n.text),
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
    if (!usesMaterialChrome(context)) {
      // iOS has no snack bars: a brief capsule under the status bar.
      _showCapsule(message, duration);
      return;
    }
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
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  OverlayEntry? _capsule;
  Timer? _capsuleTimer;

  void _showCapsule(String message, Duration duration) {
    _hideCapsule();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final entry = OverlayEntry(builder: (_) => _ToastCapsule(message: message));
    overlay.insert(entry);
    _capsule = entry;
    _capsuleTimer = Timer(duration, _hideCapsule);
  }

  void _hideCapsule() {
    _capsuleTimer?.cancel();
    _capsuleTimer = null;
    _capsule?.remove();
    _capsule = null;
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
      l10n.removedItem(item.name),
      duration: const Duration(seconds: 4),
      action: SnackBarAction(
        label: l10n.undo,
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
      c.setBanner(l10n.removeFailedError(e));
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
            label: l10n.downloads,
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
            label: c.windowService.isMobile ? l10n.shareAction : l10n.copy,
            enabled: localSelectedPaths.isNotEmpty,
            onTap: () async {
              if (c.windowService.isMobile) {
                final ok = await c.windowService
                    .shareFilesNative(localSelectedPaths);
                if (!ok) c.setBanner(l10n.couldnTOpenTheShareSheet);
                return;
              }
              final ok = await c.windowService
                  .copyFilesToClipboard(localSelectedPaths);
              c.setBanner(
                ok
                    ? l10n.copiedFiles(localSelectedPaths.length, c.windowService.pasteShortcutLabel)
                    : l10n.couldnTCopyTheFile,
              );
            },
          ),
          if (c.canCreateShares)
          _batchFooterBtn(
            isMobile: isMobile,
            icon: CupertinoIcons.link,
            label: l10n.link,
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
          if (c.canUploadToCloud)
          _batchFooterBtn(
            isMobile: isMobile,
            icon: CupertinoIcons.cloud_upload,
            label: l10n.saveToCloudShort,
            enabled: hasSelection,
            onTap: () async {
              await c.batchCacheToCloud(selectedItems);
            },
          ),
          _batchFooterBtn(
            isMobile: isMobile,
            icon: CupertinoIcons.trash,
            label: hasSelection ? l10n.deleteCount(selectedItems.length) : l10n.delete,
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
    final tint = isMobile && !usesMaterialChrome(context)
        ? MacPalette.accent // iOS toolbars tint their buttons.
        : MacPalette.textPrimary;
    final effectiveColor =
        enabled ? (color ?? tint) : MacPalette.textTertiary;
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

  /// The empty-drawer or no-match message, or null when there are entries.
  Widget? _buildListPlaceholder(
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
                isMobile ? l10n.nothingHereYet : l10n.theDrawerIsEmpty,
                style: TextStyle(
                  fontSize: isMobile ? 17 : 13,
                  fontWeight: FontWeight.w500,
                  color: MacPalette.textSecondary,
                ),
              ),
              SizedBox(height: isMobile ? 8 : 5),
              Text(
                isMobile
                    ? (usesMaterialChrome(context)
                        ? l10n.tapAddAtTheBottomRight
                        : l10n.tapAtTheBottomRightTo)
                    : l10n.dragAFileOrTextNear,
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
          l10n.noMatches,
          style: TextStyle(
            fontSize: isMobile ? 15 : 12,
            color: MacPalette.textTertiary,
          ),
        ),
      );
    }

    return null;
  }

  int _listEntryCount(DropDrawerController c, List<DrawerItem> visibleItems) =>
      c.pendingDrops.length + visibleItems.length;

  Widget _buildListEntry(
    BuildContext context,
    DropDrawerController c,
    List<DrawerItem> visibleItems,
    int index,
  ) {
    final isMobile = c.windowService.isMobile;
    if (isMobile) return _buildPhoneEntry(context, c, visibleItems, index);
    final pending = c.pendingDrops;
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
  }

  EdgeInsets _listPadding(bool isMobile) => EdgeInsets.fromLTRB(
        isMobile ? 14 : 12,
        isMobile ? 6 : 4,
        isMobile ? 14 : 12,
        isMobile ? 12 : 8,
      );

  /// Desktop list of drawer entries.
  Widget _buildItemList(
    BuildContext context,
    DropDrawerController c,
    List<DrawerItem> visibleItems,
  ) {
    final placeholder = _buildListPlaceholder(c, visibleItems);
    if (placeholder != null) return placeholder;
    return ListView.separated(
      padding: _listPadding(false),
      itemCount: _listEntryCount(c, visibleItems),
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) =>
          _buildListEntry(context, c, visibleItems, index),
    );
  }

  /// Phone list of drawer entries, as slivers below the navigation bar.
  Widget _buildItemSliver(
    BuildContext context,
    DropDrawerController c,
    List<DrawerItem> visibleItems,
  ) {
    final placeholder = _buildListPlaceholder(c, visibleItems);
    if (placeholder != null) {
      return SliverFillRemaining(hasScrollBody: false, child: placeholder);
    }
    return SliverPadding(
      // iOS: an inset grouped list. Android: full-width list items.
      padding: usesMaterialChrome(context)
          ? const EdgeInsets.only(top: 4, bottom: 8)
          : const EdgeInsets.fromLTRB(16, 4, 16, 24),
      sliver: SliverList.builder(
        itemCount: _listEntryCount(c, visibleItems),
        itemBuilder: (context, index) =>
            _buildListEntry(context, c, visibleItems, index),
      ),
    );
  }


  /// Phones: the local P2P node and the account's devices as grouped rows.
  Widget _buildPhoneDevicesBody(
    DropDrawerController c,
    List<DeviceInfo> primary,
    List<DeviceInfo> sameNameOffline,
  ) {
    final material = usesMaterialChrome(context);
    IconData platformIcon(String platform) {
      final p = platform.toLowerCase();
      if (p.contains('ios') || p.contains('android')) {
        return material
            ? Icons.phone_iphone
            : CupertinoIcons.device_phone_portrait;
      }
      if (p.contains('win')) {
        return material
            ? Icons.desktop_windows_outlined
            : CupertinoIcons.desktopcomputer;
      }
      return material ? Icons.laptop_mac : CupertinoIcons.device_laptop;
    }

    Widget deviceRow(DeviceInfo device) {
      final cleanName = device.name
          .replaceAll(RegExp(r'\.local$', caseSensitive: false), '')
          .trim();
      return PhoneRow(
        leading: Icon(
          platformIcon(device.platform),
          size: 21,
          color: device.online ? MacPalette.textPrimary : MacPalette.textTertiary,
        ),
        title: '$cleanName${device.id == c.deviceId ? l10n.thisDeviceSuffix : ''}',
        subtitle: platformDisplayName(device.platform),
        value: device.online ? l10n.online : l10n.offline,
        trailing: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: device.online ? MacPalette.green : MacPalette.textTertiary,
          ),
        ),
      );
    }

    final nodeId = c.localNodeInfo?.nodeId;
    final shortNodeId = nodeId != null && nodeId.length > 20
        ? '${nodeId.substring(0, 10)}…${nodeId.substring(nodeId.length - 8)}'
        : nodeId;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        PhoneSection(
          header: l10n.thisDeviceSP2pNode,
          footer: c.p2pReady
              ? l10n.irohQuicNodeRunningDirectLan
              : l10n.theP2pEngineIsnTLoaded,
          children: [
            PhoneRow(
              title: l10n.nodeStatus,
              value: c.p2pReady ? l10n.running : l10n.notLoaded,
              trailing: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.p2pReady ? MacPalette.green : MacPalette.amber,
                ),
              ),
            ),
            if (nodeId != null)
              PhoneRow(
                title: 'Node ID',
                value: shortNodeId,
                chevron: false,
                trailing: Icon(
                  material ? Icons.content_copy : CupertinoIcons.doc_on_doc,
                  size: 17,
                  color: MacPalette.accent,
                ),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: nodeId));
                  c.setBanner(l10n.nodeIdCopied);
                },
              ),
          ],
        ),
        PhoneSection(
          header: l10n.devicesOnThisAccount,
          children: [for (final device in primary) deviceRow(device)],
        ),
        if (sameNameOffline.isNotEmpty)
          PhoneSection(
            header: l10n.sameNameOffline(sameNameOffline.length),
            footer: l10n.oldRecordsLeftWhenTheSame,
            children: [for (final device in sameNameOffline) deviceRow(device)],
          ),
      ],
    );
  }

  Widget _buildDevicesView(DropDrawerController c, {VoidCallback? onBack}) {
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
    // This screen's own context sits above its UiDensity.
    if (c.windowService.isMobile) {
      return PhonePage(
        title: l10n.devicesP2p,
        body: _buildPhoneDevicesBody(c, primary, sameNameOffline),
      );
    }
    return AdaptivePage(
      title: l10n.devicesP2p,
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
                  onPressed: onBack ?? () => _switchPage(_DrawerPage.drawer),
                ),
                const SizedBox(width: 4),
                Text(
                  l10n.signedInDevicesP2pNodes,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      body: ListView(
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
                          c.p2pReady ? l10n.irohQuicP2pNodeRunningOn : l10n.p2pEngineNotLoaded,
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
                l10n.devicesOnThisAccount,
                style: TextStyle(fontSize: 11.5, color: MacPalette.textSecondary),
              ),
              const SizedBox(height: 6),
              _buildDeviceRows(primary, c.deviceId),
              if (sameNameOffline.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    l10n.sameNameOffline(sameNameOffline.length),
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  children: [_buildDeviceRows(sameNameOffline, c.deviceId)],
                ),
            ],
          ),
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
                            '${device.name}${device.id == localDeviceId ? l10n.thisDeviceSuffixShort : ''}',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${platformDisplayName(device.platform)} · ${device.online ? l10n.online : l10n.offline}',
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
            ? l10n.irohP2pReadyDirectLanAnd
            : l10n.runningInCloudRelayMode);

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
            l10n.itemsCount(c.items.length),
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

class _ToastCapsule extends StatelessWidget {
  final String message;

  const _ToastCapsule({required this.message});

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + 6;
    return Positioned(
      top: top,
      left: 24,
      right: 24,
      child: IgnorePointer(
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, (1 - t) * -16),
                child: child,
              ),
            ),
            child: Material(
              color: MacPalette.toastBackground,
              elevation: 8,
              shadowColor: MacPalette.shade(0.5),
              borderRadius: BorderRadius.circular(22),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: MacPalette.toastText),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingDropTile extends StatelessWidget {
  final PendingDrop drop;
  final bool isMobile;

  /// Inside a phone row frame, which draws the background.
  final bool framed;

  const _PendingDropTile({
    required this.drop,
    required this.isMobile,
    this.framed = false,
  });

  @override
  Widget build(BuildContext context) {
    final box = isMobile ? 44.0 : 34.0;
    return Container(
      padding: framed
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 10)
          : EdgeInsets.symmetric(
              horizontal: isMobile ? 12 : 10,
              vertical: isMobile ? 11 : 9,
            ),
      decoration: framed
          ? null
          : BoxDecoration(
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
                  l10n.addingToTheDrawer,
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

/// Paints a soft inward-blooming luminous halo + crisp glowing rim clipped to
/// the rounded window interior so desktop windows glow during drag hover
/// without overflowing native window bounds or shifting layout.
class _InnerEdgeGlowPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double pulse;
  final bool subtle;

  const _InnerEdgeGlowPainter({
    required this.color,
    required this.radius,
    required this.pulse,
    this.subtle = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final outer = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas.save();
    canvas.clipRRect(outer);

    final wideHalo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = subtle ? 14 : 26
      ..color = color.withValues(alpha: subtle ? 0.16 : (0.24 + 0.10 * pulse))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, subtle ? 8 : 14);
    canvas.drawRRect(outer, wideHalo);

    final midRim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = subtle ? 6 : 10
      ..color = color.withValues(alpha: subtle ? 0.24 : (0.38 + 0.14 * pulse))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, subtle ? 3.5 : 5);
    canvas.drawRRect(outer, midRim);

    final rimRect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.9),
      Radius.circular((radius - 0.9).clamp(0.0, radius)),
    );
    final crispRim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = subtle ? 1.2 : 1.8
      ..color = color.withValues(alpha: subtle ? 0.65 : (0.84 + 0.16 * pulse));
    canvas.drawRRect(rimRect, crispRim);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_InnerEdgeGlowPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.pulse != pulse ||
      old.subtle != subtle;
}

/// Short relative time in the UI language, e.g. "Just now", "5 minutes ago",
/// "Yesterday" or "Mar 2".
@visibleForTesting
String relativeTimeLabel(DateTime time, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final local = time.toLocal();
  final diff = current.difference(local);
  if (diff.inMinutes < 1) return l10n.justNow;
  if (diff.inHours < 1) return l10n.minutesAgo(diff.inMinutes);
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(local.year, local.month, local.day);
  final days = today.difference(day).inDays;
  if (days == 0) return l10n.hoursAgo(diff.inHours);
  if (days == 1) return l10n.yesterday;
  return AppLocale.shortDate(local, now: current);
}
