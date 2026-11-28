part of 'drawer_screen.dart';

/// Phone layouts of the drawer screen (iOS and Android home, menus, status and
/// device list). Kept as an extension of the screen state so the methods share
/// its fields; anything that calls `setState` stays in `drawer_screen.dart`.
extension _PhoneLayout on _DrawerScreenState {
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
}
