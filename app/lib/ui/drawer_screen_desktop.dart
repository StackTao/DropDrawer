part of 'drawer_screen.dart';

/// Desktop layouts of the drawer screen (edge drawer chrome, toolbar, drop
/// header, menus, footer and device list). An extension of the screen state;
/// anything that calls `setState` stays in `drawer_screen.dart`.
extension _DesktopLayout on _DrawerScreenState {
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
          _DrawerScreenState._preferredDropOperation(event.session.allowedOperations),
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
