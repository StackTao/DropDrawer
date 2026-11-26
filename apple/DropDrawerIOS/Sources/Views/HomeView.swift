import DropDrawerCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum AppRoute: Hashable {
    case detail(String)
    case shares([DrawerItem])
    case devices
}

struct HomeView: View {
    @Bindable var store: DropDrawerStore

    @State private var path: [AppRoute] = []
    @State private var editMode: EditMode = .inactive
    @State private var selectedIds: Set<String> = []

    @State private var showFileImporter: Bool = false
    @State private var showPhotosPicker: Bool = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var confirmClearAll: Bool = false

    private var isSelecting: Bool { editMode.isEditing }

    private var sortedOutgoingTransfers: [(id: String, progress: TransferProgress)] {
        store.outgoingTransfers
            .filter { !$0.value.finished }
            .sorted { $0.key < $1.key }
            .map { (id: $0.key, progress: $0.value) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(selection: $selectedIds) {
                if !isSelecting, let announcement = store.activeAnnouncement {
                    AnnouncementSection(announcement: announcement) {
                        withAnimation { store.dismissAnnouncement() }
                    }
                }
                if !isSelecting {
                    quickActionsSection
                }

                if !isSelecting && !sortedOutgoingTransfers.isEmpty {
                    Section("正在向其他设备发送") {
                        ForEach(sortedOutgoingTransfers, id: \.id) { entry in
                            let itemName = store.items.first(where: { $0.id == entry.progress.itemId })?.name ?? "文件"
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 10) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(itemName)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                        Text(entry.progress.channelLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    if entry.progress.total > 0 {
                                        Text("\(Int(entry.progress.fraction * 100))%")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Button {
                                        store.cancelOutgoingTransfer(transferId: entry.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("取消发送")
                                }
                                ProgressView(value: entry.progress.indicatorValue)
                                    .tint(.accentColor)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if store.items.isEmpty && store.pendingDrops.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("暂无内容", systemImage: "tray")
                        } description: {
                            Text("点上方快捷按钮发送照片、文件或剪贴板，也可在其他 App 中「分享 → DropDrawer」。")
                        }
                        .padding(.vertical, 12)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(store.pendingDrops) { pending in
                            HStack(spacing: 12) {
                                ProgressView()
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pending.name)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text("正在加入…")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        ForEach(store.items) { item in
                            HomeItemRow(
                                store: store,
                                item: item,
                                isSelecting: isSelecting,
                                onOpen: { path.append(.detail(item.id)) }
                            )
                            .tag(item.id)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await store.deleteItem(item.id) }
                                } label: {
                                    Label("移出", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                itemContextMenu(for: item)
                            }
                        }
                    } header: {
                        HStack {
                            Text("最近传输 · \(store.items.count) 项")
                            Spacer()
                        }
                        .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable {
                await store.refreshAll()
            }
            .navigationTitle(isSelecting ? "已选 \(selectedIds.count) 项" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isSelecting ? .hidden : .visible, for: .tabBar)
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        let allIds = Set(store.items.map(\.id))
                        let allSelected = !allIds.isEmpty && allIds.isSubset(of: selectedIds)
                        Button(allSelected ? "取消全选" : "全选") {
                            if allSelected {
                                selectedIds.subtract(allIds)
                            } else {
                                selectedIds.formUnion(allIds)
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") {
                            withAnimation {
                                editMode = .inactive
                                selectedIds.removeAll()
                            }
                        }
                        .fontWeight(.semibold)
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        if store.canCreateShares {
                            Button {
                                let targets = store.items.filter { selectedIds.contains($0.id) }
                                editMode = .inactive
                                selectedIds.removeAll()
                                path.append(.shares(targets))
                            } label: {
                                Label("打包外链", systemImage: "link")
                            }
                            .disabled(selectedIds.isEmpty)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            let ids = Array(selectedIds)
                            editMode = .inactive
                            selectedIds.removeAll()
                            Task { await store.batchDelete(itemIds: ids) }
                        } label: {
                            Label("移出 (\(selectedIds.count))", systemImage: "trash")
                        }
                        .disabled(selectedIds.isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            path.append(.devices)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(store.wsConnected ? (store.p2pReady ? Color.green : Color.accentColor) : Color.red)
                                    .frame(width: 7, height: 7)
                                Text(store.wsConnected ? "\(store.onlineDeviceCount) 台在线" : "连接中…")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 4)
                        }
                    }

                    if !store.items.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("选择") {
                                withAnimation { editMode = .active }
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button {
                                    Task { await store.downloadAllPending() }
                                } label: {
                                    Label("全部下载", systemImage: "arrow.down.circle")
                                }
                                Button {
                                    Task { await store.refreshAll() }
                                } label: {
                                    Label("刷新列表", systemImage: "arrow.clockwise")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    confirmClearAll = true
                                } label: {
                                    Label("清空全部", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .accessibilityLabel("更多")
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .detail(let itemId):
                    if let item = store.items.first(where: { $0.id == itemId }) {
                        ItemDetailView(store: store, item: item) {
                            path.append(.shares([item]))
                        }
                    } else {
                        ContentUnavailableView("条目已移出", systemImage: "tray")
                    }
                case .shares(let targets):
                    ShareLinksView(store: store, targetItems: targets)
                case .devices:
                    DevicesView(store: store)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result, !urls.isEmpty {
                    Task { await store.addFiles(urls) }
                }
            }
            .photosPicker(
                isPresented: $showPhotosPicker,
                selection: $pickedPhotos,
                maxSelectionCount: 20,
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: pickedPhotos) { _, newItems in
                guard !newItems.isEmpty else { return }
                let toLoad = newItems
                pickedPhotos = []
                Task { await importPickedPhotos(toLoad) }
            }
            .confirmationDialog(
                "清空全部内容？",
                isPresented: $confirmClearAll,
                titleVisibility: .visible
            ) {
                Button("清空全部 (\(store.items.count) 项)", role: .destructive) {
                    Task { await store.batchDelete(clearAll: true) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将清理列表中的 \(store.items.count) 项内容及其在服务器或网盘的副本。本机原文件会保留。")
            }
        }
    }

    private var quickActionsSection: some View {
        Section {
            HStack(spacing: 10) {
                QuickActionTile(
                    title: "照片",
                    systemImage: "photo.fill",
                    tint: .blue
                ) {
                    showPhotosPicker = true
                }
                QuickActionTile(
                    title: "文件",
                    systemImage: "doc.fill",
                    tint: .indigo
                ) {
                    showFileImporter = true
                }
                QuickActionTile(
                    title: "粘贴",
                    systemImage: "doc.on.clipboard.fill",
                    tint: .teal
                ) {
                    Task { await MediaExportHelper.pasteFromClipboard(into: store) }
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func itemContextMenu(for item: DrawerItem) -> some View {
        if item.isText {
            Button {
                UIPasteboard.general.string = item.textContent ?? item.name
                store.showToast("已复制到剪贴板")
            } label: {
                Label("复制文本", systemImage: "doc.on.doc")
            }
        } else if let local = store.localFileURL(for: item.id) {
            ShareLink(item: local) {
                Label("分享…", systemImage: "square.and.arrow.up")
            }
            if item.canSaveToPhotos {
                Button {
                    Task {
                        let ok = await MediaExportHelper.saveToPhotos(fileURL: local)
                        store.showToast(ok ? "已保存到相册" : "保存相册失败")
                    }
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                }
            }
        } else {
            Button {
                Task { await store.downloadItem(item) }
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }
        }

        if store.canCreateShares {
            Button {
                path.append(.shares([item]))
            } label: {
                Label("创建外链", systemImage: "link")
            }
        }

        if store.canUploadToCloud, !item.isText && !item.cloudReady, let local = store.localFileURL(for: item.id) {
            Button {
                Task { await store.cacheItemToCloud(itemId: item.id, fileURL: local) }
            } label: {
                Label("存到云盘", systemImage: "icloud.and.arrow.up")
            }
        }

        Button {
            withAnimation {
                editMode = .active
                selectedIds.insert(item.id)
            }
        } label: {
            Label("选择", systemImage: "checkmark.circle")
        }

        Divider()

        Button(role: .destructive) {
            Task { await store.deleteItem(item.id) }
        } label: {
            Label("移出", systemImage: "trash")
        }
    }

    private func importPickedPhotos(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        for (idx, pickerItem) in items.enumerated() {
            if let picked = try? await pickerItem.loadTransferable(type: PickedMediaFile.self) {
                urls.append(picked.url)
                continue
            }
            // Fallback for types that only vend in-memory Data (e.g., some live/generated items).
            if let data = try? await pickerItem.loadTransferable(type: Data.self) {
                let ext = pickerItem.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("photo_\(Int(Date().timeIntervalSince1970 * 1000))_\(idx).\(ext)")
                if (try? data.write(to: temp)) != nil {
                    urls.append(temp)
                }
            }
        }
        if !urls.isEmpty {
            await store.addFiles(urls)
            for u in urls { try? FileManager.default.removeItem(at: u) }
        }
    }
}

/// Streams picked photos and large videos directly from disk via `FileRepresentation`
/// instead of buffering the entire media file into memory.
private struct PickedMediaFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try Self.copyToTemp(received.file, defaultExt: "mov")
        }
        FileRepresentation(importedContentType: .image) { received in
            try Self.copyToTemp(received.file, defaultExt: "jpg")
        }
        FileRepresentation(importedContentType: .data) { received in
            try Self.copyToTemp(received.file, defaultExt: "bin")
        }
    }

    private static func copyToTemp(_ source: URL, defaultExt: String) throws -> PickedMediaFile {
        let ext = source.pathExtension.isEmpty ? defaultExt : source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        let baseName = stem.isEmpty ? "media" : stem
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName)_\(UUID().uuidString.prefix(8)).\(ext)")
        try FileManager.default.copyItem(at: source, to: dest)
        return PickedMediaFile(url: dest)
    }
}

/// Native iOS 26 Search tab (renders as detached circular Liquid Glass search orb).
struct SearchTabView: View {
    @Bindable var store: DropDrawerStore
    @State private var path: [AppRoute] = []
    @State private var searchText: String = ""
    @State private var filterKind: ItemFilterKind = .all

    private var results: [DrawerItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.items.filter { item in
            if filterKind == .file && item.isText { return false }
            if filterKind == .text && !item.isText { return false }
            if q.isEmpty { return true }
            if item.name.lowercased().contains(q) { return true }
            if (item.textContent ?? "").lowercased().contains(q) { return true }
            if (item.cleanOwnerDeviceName ?? "").lowercased().contains(q) { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .listRowBackground(Color.clear)
                } else {
                    Section("匹配结果（\(results.count)）") {
                        ForEach(results) { item in
                            HomeItemRow(
                                store: store,
                                item: item,
                                isSelecting: false,
                                onOpen: { path.append(.detail(item.id)) }
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索文件名、文本或来源设备")
            .searchScopes($filterKind) {
                ForEach(ItemFilterKind.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .detail(let itemId):
                    if let item = store.items.first(where: { $0.id == itemId }) {
                        ItemDetailView(store: store, item: item) {
                            path.append(.shares([item]))
                        }
                    } else {
                        ContentUnavailableView("条目已移出", systemImage: "tray")
                    }
                case .shares(let targets):
                    ShareLinksView(store: store, targetItems: targets)
                case .devices:
                    DevicesView(store: store)
                }
            }
        }
    }
}

private struct QuickActionTile: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

struct HomeItemRow: View {
    let store: DropDrawerStore
    let item: DrawerItem
    let isSelecting: Bool
    let onOpen: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    ItemThumbnailView(store: store, item: item, size: 46)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Circle()
                                .fill(availabilityColor)
                                .frame(width: 7, height: 7)
                            Text(metaSummary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if item.isText,
                           let preview = item.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !preview.isEmpty, preview != item.name {
                            Text(preview)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 4)

                    if !isSelecting {
                        trailingControl
                    }
                }

                if let progress = store.activeTransfers[item.id], !progress.finished {
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: progress.indicatorValue)
                            .tint(.accentColor)
                        HStack {
                            Text(progress.channelLabel)
                            Spacer()
                            if progress.total > 0 && !progress.awaitingUploadConfirmation {
                                Text("\(Int(progress.fraction * 100))%")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 58)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if let progress = store.activeTransfers[item.id], !progress.finished {
            Button {
                store.cancelTransfer(for: item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("取消传输")
        } else if item.isText {
            Button {
                UIPasteboard.general.string = item.textContent ?? item.name
                store.showToast("已复制到剪贴板")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
        } else if let local = store.localFileURL(for: item.id) {
            ShareLink(item: local) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
        } else {
            Button {
                Task { await store.downloadItem(item) }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
        }
    }

    private var availabilityColor: Color {
        if store.canDownloadP2P(item) { return .green }
        if item.cloudReady { return .accentColor }
        return Color(.tertiaryLabel)
    }

    private var metaSummary: String {
        var parts = [
            formatBytes(item.size),
            DateParsing.formatRelative(item.createdAt),
        ]
        if let dev = item.cleanOwnerDeviceName {
            parts.append("来自 \(dev)")
        }
        if !item.isText && !store.canDownloadP2P(item) && !item.cloudReady {
            parts.append("来源离线")
        }
        return parts.joined(separator: " · ")
    }
}
