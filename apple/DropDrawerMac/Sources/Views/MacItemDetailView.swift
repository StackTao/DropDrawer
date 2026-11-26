import AppKit
import DropDrawerCore
import SwiftUI

public struct MacItemDetailView: View {
    @Bindable var store: DropDrawerStore
    @Bindable var controller: EdgeDrawerController
    let item: DrawerItem

    private var localURL: URL? { store.localFileURL(for: item.id) }
    private var progress: TransferProgress? { store.activeTransfers[item.id] }
    private var isMine: Bool { item.ownerDeviceId == store.deviceId }
    private var outgoingForItem: [(String, TransferProgress)] {
        store.outgoingTransfers
            .filter { $0.value.itemId == item.id }
            .sorted { $0.key < $1.key }
    }

    private var pageTitle: String {
        if item.isText { return "文本预览" }
        return item.isImage ? "图片预览" : "文件详情"
    }

    public var body: some View {
        VStack(spacing: 0) {
            MacSubpageHeader(
                title: pageTitle,
                controller: controller,
                trailing: AnyView(
                    HStack(spacing: 2) {
                        MacIconButton(symbol: "link", size: 13, help: "创建外链分享") {
                            controller.route = .shares([item.id])
                        }
                        MacIconButton(symbol: "trash", tint: MacTheme.red, size: 13, help: "移出抽屉") {
                            Task {
                                await store.deleteItem(item.id)
                                controller.route = .home
                            }
                        }
                    }
                )
            )
            MacDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    heroPreview
                    metadataCard
                    if progress != nil || !outgoingForItem.isEmpty {
                        transferCard
                    }
                    actionButtons
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private var heroPreview: some View {
        if item.isText {
            MacGroupedCard {
                Text(item.textContent ?? item.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(MacTheme.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } else if item.isImage {
            ZStack {
                if let local = localURL, let img = NSImage(contentsOf: local) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                        .onTapGesture { MacQuickLookController.shared.preview(local) }
                } else if let data = store.thumbnailData(for: item), let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(MacTheme.textTertiary)
                        Text("下载到本地后可查看高清原图")
                            .font(.system(size: 11))
                            .foregroundStyle(MacTheme.textTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .background(MacTheme.shade(0.32), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(MacTheme.hairline, lineWidth: 0.7)
            )
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            MacGroupedCard(alpha: 0.24) {
                VStack(spacing: 10) {
                    let sym = MacPlatformServices.symbolForItem(item)
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(MacTheme.fill(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(MacTheme.hairline, lineWidth: 0.7)
                            )
                        Image(systemName: sym.name)
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(MacTheme.textPrimary)
                    }
                    .frame(width: 48, height: 48)

                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MacTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 18)
            }
        }
    }

    private var metadataCard: some View {
        let rows: [(String, String)] = {
            var r: [(String, String)] = []
            if !item.isText {
                r.append(("文件名", item.name))
            }
            r.append(("大小", MacPlatformServices.formatBytes(item.size)))
            if let owner = item.cleanOwnerDeviceName, !owner.isEmpty {
                r.append(("来源设备", owner))
            }
            r.append(("添加时间", DateParsing.formatDateTime(item.createdAt)))
            let transport: String
            if store.canDownloadP2P(item) && item.cloudReady {
                transport = "P2P 直连 + \(item.storageBackendName ?? "云端缓存")"
            } else if store.canDownloadP2P(item) {
                transport = "仅 P2P 直连"
            } else if item.cloudReady {
                transport = item.storageBackendName ?? "已存云盘"
            } else {
                transport = "来源离线"
            }
            r.append(("传输方式", transport))
            r.append(("到期清理", item.expiresAt.map { DateParsing.formatDateTime($0) } ?? "永不过期"))
            if let local = localURL {
                r.append(("本机位置", local.path))
            }
            return r
        }()

        return MacGroupedCard {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                if idx > 0 { MacDivider(indent: 12) }
                HStack(alignment: .top, spacing: 8) {
                    Text(row.0)
                        .font(.system(size: 11))
                        .foregroundStyle(MacTheme.textTertiary)
                        .frame(width: 64, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacTheme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8.5)
            }
        }
    }

    private var transferCard: some View {
        MacGroupedCard {
            VStack(alignment: .leading, spacing: 8) {
                if let prog = progress, !prog.finished {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: prog.fraction)
                            .progressViewStyle(.linear)
                            .tint(MacTheme.textPrimary)
                        HStack {
                            Text(prog.channelLabel)
                                .font(.system(size: 11))
                                .foregroundStyle(MacTheme.textSecondary)
                            Spacer()
                            Text("\(Int(prog.fraction * 100))%\(prog.speedBps > 0 ? " · \(MacPlatformServices.formatSpeed(prog.speedBps))" : "")")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(MacTheme.textPrimary)
                            Button(prog.channel == "upload" ? "取消上传" : "取消下载") {
                                store.cancelTransfer(for: item.id)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(MacTheme.red)
                            .padding(.leading, 6)
                        }
                    }
                }
                ForEach(outgoingForItem, id: \.0) { tid, prog in
                    HStack {
                        Text("正在发送 · \(Int(prog.fraction * 100))%")
                            .font(.system(size: 11))
                            .foregroundStyle(MacTheme.textSecondary)
                        Spacer()
                        Button("取消发送") {
                            store.cancelOutgoingTransfer(transferId: tid)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(MacTheme.red)
                    }
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if item.isText {
            HStack(spacing: 8) {
                MacPrimaryButton(title: "复制全部文本", symbol: "doc.on.doc", height: 32) {
                    MacPlatformServices.copyText(item.textContent ?? item.name)
                    store.showToast("已复制全部文本")
                }
                compactSecondaryButton(symbol: "link", title: "外链") {
                    controller.route = .shares([item.id])
                }
            }
        } else {
            MacFlowLayout(spacing: 8, runSpacing: 8) {
                if let local = localURL {
                    compactPrimaryButton(symbol: "doc.on.doc", title: "复制文件") {
                        let ok = MacPlatformServices.copyFilesToClipboard([local])
                        store.showToast(ok ? "已复制文件，可直接 ⌘V 粘贴" : "复制文件失败")
                    }
                    compactSecondaryButton(symbol: "folder", title: "访达中显示") {
                        MacPlatformServices.revealInFinder(local)
                    }
                    compactSecondaryButton(symbol: "eye", title: "快速查看") {
                        MacQuickLookController.shared.preview(local)
                    }
                } else {
                    compactPrimaryButton(
                        symbol: "arrow.down.circle",
                        title: store.canDownloadP2P(item) ? "P2P 优先下载" : "云端下载"
                    ) {
                        Task { await store.downloadItem(item) }
                    }
                }
                if isMine && !item.cloudReady, let local = localURL {
                    compactSecondaryButton(symbol: "icloud.and.arrow.up", title: "存云盘") {
                        Task { await store.cacheItemToCloud(itemId: item.id, fileURL: local) }
                    }
                }
                compactSecondaryButton(symbol: "link", title: "外链分享") {
                    controller.route = .shares([item.id])
                }
            }
        }
    }

    private func compactPrimaryButton(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12.5))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(MacTheme.onTextPrimary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(MacTheme.textPrimary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func compactSecondaryButton(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12.5))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(MacTheme.textPrimary)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(MacTheme.strongHairline, lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
    }
}
