import AppKit
import DropDrawerCore
import SwiftUI
import UniformTypeIdentifiers

private enum MacItemFilter: String, CaseIterable {
    case all = "全部"
    case file = "文件"
    case text = "文本"
}

public struct MacDrawerHomeView: View {
    @Bindable var store: DropDrawerStore
    @Bindable var controller: EdgeDrawerController
    var isDragHovering: Bool = false

    @State private var searchOpen = false
    @State private var query = ""
    @State private var filter: MacItemFilter = .all
    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []
    @State private var confirmingClear = false
    @State private var isHeaderDragging = false
    @State private var isDropCardHovered = false

    private var filteredItems: [DrawerItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.items.filter { item in
            switch filter {
            case .all: break
            case .file: if item.isText { return false }
            case .text: if !item.isText { return false }
            }
            if q.isEmpty { return true }
            if item.name.lowercased().contains(q) { return true }
            if let text = item.textContent, text.lowercased().contains(q) { return true }
            if let owner = item.cleanOwnerDeviceName, owner.lowercased().contains(q) { return true }
            return false
        }
    }

    private var isFiltering: Bool {
        filter != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            MacDivider()
            dropHeader

            if !store.items.isEmpty {
                batchActionStrip
            }
            if !store.items.isEmpty && searchOpen {
                searchFilterBar
            }

            itemListArea

            if isSelecting {
                batchFooter
            } else {
                MacUpdateBanner(updater: controller.updater)
                statusFooter
            }
        }
    }

    // MARK: - Top Toolbar (exact Flutter macOS layout)

    private var toolbar: some View {
        HStack(spacing: 2) {
            Circle()
                .fill(store.wsConnected ? (store.p2pReady ? MacTheme.green : MacTheme.accent) : MacTheme.red)
                .frame(width: 7, height: 7)

            Text("DropDrawer")
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(MacTheme.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 6)

            Button {
                controller.route = .devices
            } label: {
                Text("\(store.onlineDeviceCount) 设备在线")
                    .font(.system(size: 10.5))
                    .foregroundStyle(MacTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(MacTheme.fill(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .help("查看已登录设备与 P2P 节点")

            Spacer(minLength: 4)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { _ in
                            guard controller.isEdgeMode else { return }
                            if !isHeaderDragging {
                                isHeaderDragging = true
                                controller.beginHeaderDrag()
                            }
                            controller.updateHeaderDrag()
                        }
                        .onEnded { _ in
                            isHeaderDragging = false
                            controller.endHeaderDrag()
                        }
                )

            if controller.isEdgeMode {
                MacIconButton(
                    symbol: controller.isPinned ? "pin.fill" : "pin",
                    active: controller.isPinned,
                    size: 12.5,
                    help: controller.isPinned ? "已固定展开（点击开启离开自动隐藏）" : "离开自动隐藏（点击固定展开）"
                ) {
                    controller.togglePinned()
                }

                MacIconButton(
                    symbol: controller.dockSide == .left ? "arrow.left.to.line" : "arrow.right.to.line",
                    size: 12.5,
                    help: "收起到边缘 (Esc)"
                ) {
                    controller.collapse(animated: true, restoreFocus: true)
                }
            }

            MacIconButton(
                symbol: controller.isEdgeMode
                    ? "macwindow"
                    : (controller.dockSide == .left ? "sidebar.left" : "sidebar.right"),
                size: 13,
                help: controller.isEdgeMode ? "切换为常规窗口" : "切换为边缘抽屉"
            ) {
                controller.toggleWindowMode()
            }

            MacIconButton(
                symbol: "cloud",
                size: 13.5,
                help: "多云盘与中转存储"
            ) {
                controller.route = .storage
            }

            MacIconButton(
                symbol: "ellipsis",
                size: 14,
                help: "更多"
            ) {
                controller.presentMoreMenu()
            }
        }
        .frame(height: 26)
        .padding(.leading, controller.isEdgeMode ? 14 : 78)
        .padding(.trailing, 10)
        .padding(.top, controller.isEdgeMode ? 10 : 5)
        .padding(.bottom, controller.isEdgeMode ? 9 : 6)
    }

    // MARK: - Drop Header + Segmented Transfer Policy

    private var dropHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(MacTheme.fill(0.08))
                    Image(systemName: isDragHovering ? "arrow.down.doc.fill" : "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(MacTheme.textPrimary)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(isDragHovering ? "松开以放进抽屉" : "拖入、选取或 ⌘V 粘贴")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(MacTheme.textPrimary)
                        .lineLimit(1)
                    Text(policySubtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(MacTheme.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                MacIconButton(
                    symbol: "doc.on.clipboard",
                    size: 13.5,
                    help: "智能粘贴文件 / 截图 / 文本 (⌘V)"
                ) {
                    Task { await controller.pasteClipboardIntoDrawer() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isDragHovering ? MacTheme.fill(0.14) : MacTheme.fill(isDropCardHovered ? 0.08 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isDragHovering ? MacTheme.fill(0.45) : MacTheme.hairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .onHover { isDropCardHovered = $0 }
            .onTapGesture {
                Task { await controller.pickAndAddFiles() }
            }

            MacSegmentedControl(
                items: [
                    (DropPolicy.smart, "智能(<\(store.autoCloudThresholdMb)M上云)"),
                    (DropPolicy.p2pOnly, "纯 P2P 直连"),
                    (DropPolicy.cloudCached, "强制存云盘"),
                ],
                selected: store.dropPolicy
            ) { policy in
                store.setDropPolicy(policy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var policySubtitle: String {
        switch store.dropPolicy {
        case .p2pOnly:
            return "仅本机 P2P 端到端直连 · 不占服务器与云盘"
        case .cloudCached:
            return "直接上传至「\(store.defaultStorageBackendName)」· 离线可下"
        case .smart:
            return "小于 \(store.autoCloudThresholdMb)MB 自动云存 · 大文件纯 P2P 直连"
        }
    }

    // MARK: - Inline Batch Action Strip (Search hidden behind magnifying glass until toggled)

    private var batchActionStrip: some View {
        let visibleIds = Set(filteredItems.map(\.id))
        let allSelected = !filteredItems.isEmpty && visibleIds.isSubset(of: selectedIds)

        return HStack(spacing: 8) {
            if isSelecting {
                miniTextAction(allSelected ? "取消全选" : "全选 (\(filteredItems.count))") {
                    if allSelected {
                        selectedIds.subtract(visibleIds)
                    } else {
                        selectedIds.formUnion(visibleIds)
                    }
                }
                Text("已选 \(selectedIds.count) 项")
                    .font(.system(size: 10.5))
                    .foregroundStyle(MacTheme.textTertiary)
                Spacer()
                miniTextAction("完成", color: MacTheme.textPrimary) {
                    isSelecting = false
                    selectedIds.removeAll()
                }
            } else {
                Text(isFiltering ? "筛选结果 · \(filteredItems.count)/\(store.items.count)" : "抽屉内容 · \(store.items.count) 项")
                    .font(.system(size: 10.5))
                    .foregroundStyle(MacTheme.textTertiary)

                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        searchOpen.toggle()
                        if !searchOpen {
                            query = ""
                            filter = .all
                        }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundStyle((searchOpen || isFiltering) ? MacTheme.textPrimary : MacTheme.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .help("搜索与筛选")

                miniTextAction("多选") {
                    isSelecting = true
                    confirmingClear = false
                    selectedIds.removeAll()
                }

                miniTextAction("全部下载") {
                    Task {
                        for item in filteredItems where !item.isText && store.localFileURL(for: item.id) == nil {
                            await store.downloadItem(item)
                        }
                    }
                }

                if confirmingClear {
                    miniTextAction("确认清空", color: MacTheme.red) {
                        confirmingClear = false
                        Task { await store.batchDelete(clearAll: true) }
                    }
                    miniTextAction("取消") {
                        confirmingClear = false
                    }
                } else {
                    miniTextAction("清空") {
                        confirmingClear = true
                        Task {
                            try? await Task.sleep(for: .seconds(4))
                            if confirmingClear { confirmingClear = false }
                        }
                    }
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    private func miniTextAction(_ label: String, color: Color = MacTheme.textSecondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expandable Search & Filter Pills

    private var searchFilterBar: some View {
        HStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacTheme.textTertiary)
                TextField("", text: $query, prompt: Text("搜索文件名或文本...").foregroundStyle(MacTheme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacTheme.textPrimary)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(MacTheme.shade(0.28), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(MacTheme.hairline, lineWidth: 0.6)
            )

            ForEach(MacItemFilter.allCases, id: \.self) { kind in
                let active = filter == kind
                Button {
                    filter = kind
                } label: {
                    Text(kind.rawValue)
                        .font(.system(size: 10.5, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? MacTheme.textPrimary : MacTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(active ? MacTheme.fill(0.16) : MacTheme.group(0.22))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(active ? MacTheme.strongHairline : MacTheme.hairline, lineWidth: 0.6)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    // MARK: - Item List Area

    @ViewBuilder
    private var itemListArea: some View {
        if store.items.isEmpty && store.pendingDrops.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(MacTheme.fill(0.16))
                Text("抽屉是空的")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MacTheme.textSecondary)
                Text("拖起文件或文本靠近悬浮引导条\n点击边缘手柄展开 · 拖动可调整上下或左右停靠")
                    .font(.system(size: 11))
                    .foregroundStyle(MacTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                Spacer()
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredItems.isEmpty && store.pendingDrops.isEmpty {
            VStack {
                Spacer()
                Text("没有匹配的内容")
                    .font(.system(size: 12))
                    .foregroundStyle(MacTheme.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.pendingDrops) { pending in
                        pendingRow(pending)
                    }
                    ForEach(filteredItems) { item in
                        MacItemRow(
                            item: item,
                            store: store,
                            isSelecting: isSelecting,
                            isSelected: selectedIds.contains(item.id),
                            onTap: { handleRowTap(item) },
                            onDoubleClick: { handleRowDoubleClick(item) },
                            onShare: { controller.route = .shares([item.id]) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
    }

    private func pendingRow(_ pending: PendingDrop) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 34, height: 34)
                .background(MacTheme.fill(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(MacTheme.textPrimary)
                    .lineLimit(1)
                Text("正在加入抽屉…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(MacTheme.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(MacTheme.cardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Bottom Status Footer & Multi-Select Footer

    private var statusFooter: some View {
        let text = store.toastMessage
            ?? (store.p2pReady
                ? "iroh P2P 就绪 · 局域网与公网直连优先"
                : "当前运行在云端中转模式")

        return VStack(spacing: 0) {
            MacDivider()
            HStack {
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(store.toastMessage != nil ? MacTheme.textSecondary : MacTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("\(store.items.count) 项")
                    .font(.system(size: 10.5))
                    .foregroundStyle(MacTheme.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
    }

    private var batchFooter: some View {
        let selectedItems = store.items.filter { selectedIds.contains($0.id) }
        let hasSelection = !selectedItems.isEmpty
        let localURLs = selectedItems.compactMap { store.localFileURL(for: $0.id) }

        return VStack(spacing: 0) {
            MacDivider()
            HStack {
                batchFooterBtn(symbol: "arrow.down.circle", label: "下载", enabled: hasSelection) {
                    Task {
                        for item in selectedItems where !item.isText {
                            await store.downloadItem(item)
                        }
                        isSelecting = false
                        selectedIds.removeAll()
                    }
                }
                Spacer()
                batchFooterBtn(symbol: "doc.on.doc", label: "复制", enabled: !localURLs.isEmpty) {
                    let ok = MacPlatformServices.copyFilesToClipboard(localURLs)
                    store.showToast(ok ? "已复制 \(localURLs.count) 个文件，可直接 ⌘V 粘贴" : "复制文件失败")
                }
                Spacer()
                batchFooterBtn(symbol: "link", label: "外链", enabled: hasSelection) {
                    let ids = selectedItems.map(\.id)
                    isSelecting = false
                    selectedIds.removeAll()
                    controller.route = .shares(ids)
                }
                Spacer()
                batchFooterBtn(symbol: "icloud.and.arrow.up", label: "存云盘", enabled: hasSelection) {
                    Task {
                        for item in selectedItems where !item.isText && !item.cloudReady {
                            if let local = store.localFileURL(for: item.id) {
                                await store.cacheItemToCloud(itemId: item.id, fileURL: local)
                            }
                        }
                    }
                }
                Spacer()
                batchFooterBtn(
                    symbol: "trash",
                    label: hasSelection ? "删除(\(selectedItems.count))" : "删除",
                    enabled: hasSelection,
                    color: MacTheme.red
                ) {
                    let ids = selectedItems.map(\.id)
                    Task {
                        await store.batchDelete(itemIds: ids)
                        selectedIds.removeAll()
                        if store.items.isEmpty { isSelecting = false }
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(MacTheme.shade(0.28))
        }
    }

    private func batchFooterBtn(
        symbol: String,
        label: String,
        enabled: Bool,
        color: Color = MacTheme.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(enabled ? color : MacTheme.textTertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func handleRowTap(_ item: DrawerItem) {
        if isSelecting {
            if selectedIds.contains(item.id) {
                selectedIds.remove(item.id)
            } else {
                selectedIds.insert(item.id)
            }
        } else {
            controller.route = .detail(item.id)
        }
    }

    private func handleRowDoubleClick(_ item: DrawerItem) {
        guard !isSelecting else { return }
        if item.isText {
            if let text = item.textContent {
                MacPlatformServices.copyText(text)
                store.showToast("已复制文本")
            }
        } else if let local = store.localFileURL(for: item.id) {
            MacQuickLookController.shared.preview(local)
        } else {
            Task { await store.downloadItem(item) }
        }
    }
}

// MARK: - Dark Frosted Item Card (matches Flutter _DrawerItemTile 1:1)

private struct MacItemRow: View {
    let item: DrawerItem
    @Bindable var store: DropDrawerStore
    let isSelecting: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onDoubleClick: () -> Void
    let onShare: () -> Void

    @State private var isHovered = false

    private var localURL: URL? { store.localFileURL(for: item.id) }
    private var progress: TransferProgress? { store.activeTransfers[item.id] }
    private var isMine: Bool { item.ownerDeviceId == store.deviceId }
    private var outgoingForItem: [(String, TransferProgress)] {
        store.outgoingTransfers
            .filter { $0.value.itemId == item.id }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? MacTheme.accent : MacTheme.textTertiary)
                }

                thumbnail

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(MacTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(itemStatusDotColor)
                            .frame(width: 5, height: 5)
                        Text(metaText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(MacTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingActions
            }

            transferSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? MacTheme.accent.opacity(0.16) : (isHovered ? MacTheme.cardHoverBg : MacTheme.cardBg))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? MacTheme.accent.opacity(0.65) : (isHovered ? MacTheme.strongHairline : .clear),
                    lineWidth: 0.7
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onDoubleClick() }
        .onTapGesture(count: 1) { onTap() }
        .onDrag { makeDragProvider() }
        .contextMenu { contextMenuContent }
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            if let nsImage = MacPlatformServices.cachedThumbnail(for: item, localURL: localURL, store: store) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                            .strokeBorder(MacTheme.hairline, lineWidth: 0.5)
                    )
            } else {
                let sym = MacPlatformServices.symbolForItem(item)
                ZStack {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(MacTheme.fill(0.07))
                    Image(systemName: sym.name)
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(MacTheme.textPrimary)
                }
                .frame(width: 34, height: 34)
            }

            if !item.isText && localURL != nil {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(MacTheme.textPrimary, MacTheme.elevatedBg)
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var itemStatusDotColor: Color {
        if store.canDownloadP2P(item) { return MacTheme.green }
        if item.cloudReady { return MacTheme.accent }
        return MacTheme.textTertiary
    }

    @ViewBuilder
    private var transferSection: some View {
        let isTransferring = progress != nil && progress?.finished == false
        let hasError = progress != nil && progress?.finished == true && progress?.error != nil
        if isTransferring || !outgoingForItem.isEmpty || hasError {
            VStack(spacing: 4) {
                if let prog = progress, !prog.finished {
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: prog.fraction > 0 ? prog.fraction : nil)
                            .progressViewStyle(.linear)
                            .tint(MacTheme.textPrimary)
                            .controlSize(.mini)
                        HStack {
                            Text(channelDescription(prog.channel))
                                .font(.system(size: 10))
                                .foregroundStyle(MacTheme.textTertiary)
                            Spacer()
                            Text("\(Int(prog.fraction * 100))%\(prog.speedBps > 0 ? " · \(MacPlatformServices.formatSpeed(prog.speedBps))" : "")")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(MacTheme.textSecondary)
                            Button(prog.channel == "cancelling" ? "正在取消" : (prog.channel == "upload" ? "取消上传" : "取消下载")) {
                                store.cancelTransfer(for: item.id)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(MacTheme.red)
                            .disabled(prog.channel == "cancelling")
                            .padding(.leading, 4)
                        }
                    }
                    .padding(.top, 7)
                }

                ForEach(outgoingForItem, id: \.0) { tid, prog in
                    HStack {
                        let peerName = store.devices.first(where: { $0.irohNodeId == prog.sendingTo })?.displayName ?? "设备"
                        Text("正在发送给 \(peerName) · \(Int(prog.fraction * 100))%")
                            .font(.system(size: 10))
                            .foregroundStyle(MacTheme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Button("取消发送") {
                            store.cancelOutgoingTransfer(transferId: tid)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(MacTheme.red)
                    }
                    .padding(.top, 4)
                }

                if let prog = progress, prog.finished, let err = prog.error {
                    HStack {
                        Text("传输失败：\(err)")
                            .font(.system(size: 10))
                            .foregroundStyle(MacTheme.red)
                            .lineLimit(1)
                        Spacer()
                        Button("重试") {
                            Task { await store.downloadItem(item) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(MacTheme.accent)
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func channelDescription(_ channel: String) -> String {
        switch channel {
        case "preparing": return "正在准备下载"
        case "upload": return "正在上传到云盘"
        case "p2p_connecting": return "正在建立 P2P 连接"
        case "p2p_replica": return "P2P 局域网副本"
        case "p2p_direct": return "P2P 端到端直连"
        case "p2p_relay": return "P2P 加密中继"
        case "cancelling": return "正在取消…"
        default: return "云端高速下载"
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if item.isText {
            parts.append("文本")
            parts.append(MacPlatformServices.relativeTime(item.createdAt))
        } else {
            parts.append(MacPlatformServices.formatBytes(item.size))
            if store.canDownloadP2P(item) && item.cloudReady {
                parts.append("P2P · 云端")
            } else if store.canDownloadP2P(item) {
                parts.append("P2P 直连")
            } else if item.cloudReady {
                parts.append(item.storageBackendName ?? "已存云盘")
            } else {
                parts.append("来源离线")
            }
        }
        if let owner = item.cleanOwnerDeviceName, !owner.isEmpty {
            parts.append(owner)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailingActions: some View {
        if isSelecting {
            EmptyView()
        } else {
            HStack(spacing: 1) {
                MacIconButton(symbol: "link", size: 12.5, help: "创建外链分享") {
                    onShare()
                }
                if item.isText {
                    MacIconButton(symbol: "doc.on.doc", size: 13, help: "复制文本") {
                        if let text = item.textContent {
                            MacPlatformServices.copyText(text)
                            store.showToast("已复制到剪贴板")
                        }
                    }
                } else if let local = localURL {
                    if isMine && !item.cloudReady {
                        MacIconButton(symbol: "icloud.and.arrow.up", size: 13.5, help: "转存到云盘 (离线可下)") {
                            Task { await store.cacheItemToCloud(itemId: item.id, fileURL: local) }
                        }
                    }
                    MacIconButton(symbol: "doc.on.doc", size: 13, help: "复制文件 (可直接 ⌘V 粘贴到微信/访达)") {
                        if MacPlatformServices.copyFilesToClipboard([local]) {
                            store.showToast("已复制文件，可直接 ⌘V 粘贴")
                        }
                    }
                    MacIconButton(symbol: "folder", size: 13.5, help: "在访达中显示 (也可直接按住卡片拖出)") {
                        MacPlatformServices.revealInFinder(local)
                    }
                } else {
                    MacIconButton(
                        symbol: "arrow.down.circle",
                        tint: MacTheme.textPrimary,
                        size: 15,
                        help: store.canDownloadP2P(item) ? "P2P 优先下载" : "从云端下载"
                    ) {
                        Task { await store.downloadItem(item) }
                    }
                }
                if isHovered {
                    MacIconButton(symbol: "xmark", size: 12, help: "移出抽屉") {
                        Task { await store.deleteItem(item.id) }
                    }
                }
            }
        }
    }

    private func makeDragProvider() -> NSItemProvider {
        if let local = localURL, let provider = NSItemProvider(contentsOf: local) {
            return provider
        }
        if item.isText, let text = item.textContent {
            return NSItemProvider(object: text as NSString)
        }
        return NSItemProvider()
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if item.isText {
            Button {
                if let text = item.textContent {
                    MacPlatformServices.copyText(text)
                    store.showToast("已复制文本")
                }
            } label: {
                Label("复制文本", systemImage: "doc.on.doc")
            }
        } else if let local = localURL {
            Button { MacQuickLookController.shared.preview(local) } label: {
                Label("快速查看", systemImage: "eye")
            }
            Button { MacPlatformServices.openFile(local) } label: {
                Label("使用默认应用打开", systemImage: "arrow.up.forward.app")
            }
            Button { MacPlatformServices.revealInFinder(local) } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            Button {
                if MacPlatformServices.copyFilesToClipboard([local]) {
                    store.showToast("已复制文件")
                }
            } label: {
                Label("复制文件", systemImage: "doc.on.doc")
            }
            if !item.cloudReady {
                Button {
                    Task { await store.cacheItemToCloud(itemId: item.id, fileURL: local) }
                } label: {
                    Label("缓存到云盘", systemImage: "icloud.and.arrow.up")
                }
            }
        } else {
            Button { Task { await store.downloadItem(item) } } label: {
                Label("下载到本机", systemImage: "arrow.down.circle")
            }
            if item.cloudReady {
                Button { Task { await store.downloadItem(item, cloudOnly: true) } } label: {
                    Label("仅从云端下载", systemImage: "icloud.and.arrow.down")
                }
            }
        }

        Divider()

        Button { onShare() } label: {
            Label("创建公网外链…", systemImage: "link")
        }
        Button { onTap() } label: {
            Label("查看详情", systemImage: "info.circle")
        }

        Divider()

        Button(role: .destructive) {
            Task { await store.deleteItem(item.id) }
        } label: {
            Label("移出抽屉", systemImage: "trash")
        }
    }
}
