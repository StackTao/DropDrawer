import DropDrawerCore
import QuickLook
import SwiftUI

struct ItemDetailView: View {
    @Bindable var store: DropDrawerStore
    let item: DrawerItem
    let onCreateShare: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quickLookURL: URL?
    @State private var heroImage: UIImage?

    private var localURL: URL? { store.localFileURL(for: item.id) }
    private var heroCacheKey: String {
        "hero_\(item.id)_\(localURL?.path ?? "")"
    }

    var body: some View {
        List {
            heroSection
            actionsSection
            if let progress = store.activeTransfers[item.id], !progress.finished {
                transferSection(progress)
            }
            infoSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item.isText ? String(localized: "文本预览") : (item.isImage ? String(localized: "图片预览") : String(localized: "文件详情")))
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($quickLookURL)
        .toolbar {
            if store.canCreateShares {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onCreateShare()
                    } label: {
                        Image(systemName: "link")
                    }
                    .accessibilityLabel(String(localized: "创建外链"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    Task {
                        await store.deleteItem(item.id)
                        dismiss()
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(String(localized: "移出"))
            }
        }
    }

    @ViewBuilder
    private var heroSection: some View {
        if item.isText {
            Section {
                Text(item.textContent ?? item.name)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
            }
        } else if item.isImage {
            Section {
                Group {
                    if let img = heroImage ?? ThumbnailImageCache.shared.image(forKey: heroCacheKey) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 320)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .onTapGesture {
                    if let url = localURL { quickLookURL = url }
                }
                .task(id: heroCacheKey) {
                    let key = heroCacheKey
                    if let cached = ThumbnailImageCache.shared.image(forKey: key) {
                        heroImage = cached
                        return
                    }
                    let local = localURL
                    let thumbData = local == nil ? store.thumbnailData(for: item) : nil
                    let decoded = await ThumbnailImageCache.shared.loadDownsampled(
                        key: key,
                        thumbnailData: thumbData,
                        localFileURL: local,
                        maxPixelSize: 1200
                    )
                    if !Task.isCancelled {
                        heroImage = decoded
                    }
                }
            }
        } else {
            Section {
                VStack(spacing: 10) {
                    ItemThumbnailView(store: store, item: item, size: 72)
                    Text(item.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Text(formatBytes(item.size))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }
        }
    }

    private var actionsSection: some View {
        Section {
            if item.isText {
                Button {
                    UIPasteboard.general.string = item.textContent ?? item.name
                    store.showToast(String(localized: "已复制到剪贴板"))
                } label: {
                    Label(String(localized: "复制文本"), systemImage: "doc.on.doc")
                }
                ShareLink(item: item.textContent ?? item.name) {
                    Label(String(localized: "系统分享"), systemImage: "square.and.arrow.up")
                }
            } else if let local = localURL {
                Button {
                    quickLookURL = local
                } label: {
                    Label(String(localized: "快速预览"), systemImage: "eye")
                }
                ShareLink(item: local) {
                    Label(String(localized: "分享或用其他 App 打开"), systemImage: "square.and.arrow.up")
                }
                if item.canSaveToPhotos {
                    Button {
                        Task {
                            let ok = await MediaExportHelper.saveToPhotos(fileURL: local)
                            store.showToast(ok ? String(localized: "已保存到系统相册") : String(localized: "保存失败，请检查相册权限"))
                        }
                    } label: {
                        Label(String(localized: "保存到系统相册"), systemImage: "square.and.arrow.down")
                    }
                }
                if !item.cloudReady && store.canUploadToCloud {
                    Button {
                        Task { await store.cacheItemToCloud(itemId: item.id, fileURL: local) }
                    } label: {
                        Label(String(localized: "上传缓存到云盘"), systemImage: "icloud.and.arrow.up")
                    }
                }
            } else {
                Button {
                    Task { await store.downloadItem(item) }
                } label: {
                    Label(
                        store.canDownloadP2P(item) ? String(localized: "P2P 优先下载") : String(localized: "从云端下载"),
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(!store.canDownloadP2P(item) && !item.cloudReady)
            }

            if store.canCreateShares {
                Button {
                    onCreateShare()
                } label: {
                    Label(String(localized: "创建公网外链"), systemImage: "link")
                }
            }
        }
    }

    private func transferSection(_ progress: TransferProgress) -> some View {
        Section(String(localized: "传输进度")) {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.indicatorValue)
                HStack {
                    Text(progress.channelLabel)
                    Spacer()
                    if progress.total > 0 && !progress.awaitingUploadConfirmation {
                        Text("\(formatBytes(progress.transferred)) / \(formatBytes(progress.total))")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Button(String(localized: "取消传输"), role: .destructive) {
                store.cancelTransfer(for: item.id)
            }
        }
    }

    private var infoSection: some View {
        Section(String(localized: "信息")) {
            if !item.isText {
                LabeledContent(String(localized: "文件名"), value: item.name)
            }
            LabeledContent(String(localized: "大小"), value: formatBytes(item.size))
            if let dev = item.cleanOwnerDeviceName {
                LabeledContent(String(localized: "来源设备"), value: dev)
            }
            LabeledContent(String(localized: "添加时间"), value: DateParsing.formatDateTime(item.createdAt))
            LabeledContent(String(localized: "传输方式"), value: transferModeLabel)
            LabeledContent(String(localized: "到期清理"), value: item.expiresAt.map(DateParsing.formatDateTime) ?? String(localized: "永不过期"))
            if localURL != nil {
                LabeledContent(String(localized: "本地缓存"), value: String(localized: "已保存到本机"))
            }
        }
    }

    private var transferModeLabel: String {
        let p2p = store.canDownloadP2P(item)
        if p2p && item.cloudReady {
            return String(localized: "P2P 直连 + \(item.storageBackendName ?? String(localized: "云端缓存"))")
        }
        if p2p { return String(localized: "仅 P2P 直连") }
        if item.cloudReady { return item.storageBackendName ?? String(localized: "已存云盘") }
        return String(localized: "来源离线")
    }
}
