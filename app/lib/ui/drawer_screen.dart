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
part 'drawer_screen_desktop.dart';
part 'drawer_screen_phone.dart';
part 'drawer_screen_widgets.dart';

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
        onHide: () => widget.controller.setPushForeground(false),
        onResume: () {
          widget.controller.setPushForeground(true);
          unawaited(widget.controller.refreshOnResume());
        },
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

  void _closeWindowsMoreMenu(DropDrawerController c) {
    final listener = _windowsMenuLifecycle;
    if (listener == null) return;
    listener.dispose();
    _windowsMenuLifecycle = null;
    unawaited(c.windowService.setModalOpen(false));
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
}
