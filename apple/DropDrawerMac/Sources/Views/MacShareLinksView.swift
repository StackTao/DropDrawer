import DropDrawerCore
import SwiftUI

/// In-drawer Share Links view matching the exact desktop `ShareView` design:
/// Top creation card (with bundle file list, sparkles random passcode, expiry/limit segmented controls,
/// green confirmation banner) + compact single-row share cards below.
public struct MacShareLinksView: View {
    @Bindable var store: DropDrawerStore
    @Bindable var controller: EdgeDrawerController
    let targetItems: [DrawerItem]

    @State private var bundleTitle = ""
    @State private var passcode = ""
    @State private var expiresHours = 24
    @State private var maxDownloads = 0
    @State private var creating = false
    @State private var errorMsg: String?
    @State private var justCreated: ShareLinkInfo?
    @State private var justCreatedPasscode: String?

    private var hasTargets: Bool { !targetItems.isEmpty }
    private var isBundle: Bool { targetItems.count > 1 }

    private var pageTitle: String {
        if !hasTargets { return "外链分享管理" }
        return isBundle ? "打包创建外链 (\(targetItems.count) 项)" : "创建外链分享"
    }

    public var body: some View {
        VStack(spacing: 0) {
            MacSubpageHeader(
                title: pageTitle,
                controller: controller,
                trailing: AnyView(
                    MacIconButton(symbol: "arrow.clockwise", size: 12.5, help: "刷新外链列表") {
                        Task { await store.refreshShareLinks() }
                    }
                )
            )
            MacDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if hasTargets {
                        createSection
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("已创建的外链 (\(store.shareLinks.count))")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(MacTheme.textSecondary)

                        if store.shareLinks.isEmpty {
                            MacGroupedCard(alpha: 0.20) {
                                Text("暂无外链分享\n点击单条链接图标，或进入「多选」打包创建合集外链")
                                    .font(.system(size: 11))
                                    .foregroundStyle(MacTheme.textTertiary)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(3)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 20)
                            }
                        } else {
                            VStack(spacing: 7) {
                                ForEach(store.shareLinks) { link in
                                    shareRow(link)
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .task {
            await store.refreshShareLinks()
        }
    }

    // MARK: - In-Drawer Create Share Section

    private var createSection: some View {
        let totalBytes = targetItems.reduce(Int64(0)) { $0 + $1.size }
        let pendingUploads = targetItems.filter { !$0.isText && !$0.cloudReady }.count
        let primaryName = targetItems.first?.name ?? ""

        return MacGroupedCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(MacTheme.fill(0.08))
                        Image(systemName: isBundle ? "square.stack" : (targetItems.first?.isText == true ? "doc.plaintext" : "doc"))
                            .font(.system(size: 13.5))
                            .foregroundStyle(MacTheme.textPrimary)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(isBundle ? "\(primaryName) 等 \(targetItems.count) 项" : primaryName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MacTheme.textPrimary)
                            .lineLimit(1)
                        Text(pendingUploads > 0
                             ? "\(MacPlatformServices.formatBytes(totalBytes)) · 生成前自动上云 \(pendingUploads) 个文件至「\(store.defaultStorageBackendName)」"
                             : "\(MacPlatformServices.formatBytes(totalBytes)) · 已就绪，外部浏览器免登录提取")
                            .font(.system(size: 10.5))
                            .foregroundStyle(MacTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                if isBundle {
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(targetItems) { it in
                                HStack(spacing: 6) {
                                    Image(systemName: it.isText ? "text.quote" : "doc")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(MacTheme.textTertiary)
                                    Text(it.name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(MacTheme.textSecondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(MacPlatformServices.formatBytes(it.size))
                                        .font(.system(size: 10))
                                        .foregroundStyle(MacTheme.textTertiary)
                                }
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 84)
                    .background(MacTheme.fill(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MacTheme.hairline, lineWidth: 0.5))

                    MacFormRow(
                        label: "合集标题",
                        placeholder: "可选，默认「\(primaryName) 等 \(targetItems.count) 项」",
                        text: $bundleTitle,
                        labelWidth: 56
                    )
                    .background(MacTheme.fill(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MacTheme.hairline, lineWidth: 0.6))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("有效期")
                        .font(.system(size: 11))
                        .foregroundStyle(MacTheme.textSecondary)
                    MacSegmentedControl(
                        items: [(1, "1 小时"), (24, "24 小时"), (168, "7 天"), (0, "永久")],
                        selected: expiresHours
                    ) { expiresHours = $0 }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("下载次数限制")
                        .font(.system(size: 11))
                        .foregroundStyle(MacTheme.textSecondary)
                    MacSegmentedControl(
                        items: [(0, "不限"), (1, "1次(阅后即焚)"), (5, "5 次"), (20, "20 次")],
                        selected: maxDownloads
                    ) { maxDownloads = $0 }
                }

                HStack(spacing: 0) {
                    MacFormRow(label: "提取码", placeholder: "留空为公开免密", text: $passcode, labelWidth: 52)
                    MacIconButton(symbol: "sparkles", size: 13, help: "随机生成 4 位提取码") {
                        generatePasscode()
                    }
                    .padding(.trailing, 6)
                }
                .background(MacTheme.fill(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MacTheme.hairline, lineWidth: 0.6))

                if let errorMsg {
                    Text(errorMsg)
                        .font(.system(size: 11))
                        .foregroundStyle(MacTheme.red)
                }

                MacPrimaryButton(
                    title: pendingUploads > 0
                        ? "自动上云并生成外链"
                        : (isBundle ? "生成合集外链并复制" : "生成外链并复制"),
                    loading: creating,
                    height: 34
                ) {
                    Task { await createShare() }
                }

                if let created = justCreated {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12.5))
                                .foregroundStyle(MacTheme.green)
                            Text("已生成并复制到剪贴板")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(MacTheme.textPrimary)
                            Spacer()
                            MacIconButton(symbol: "doc.on.doc", size: 12.5, help: "再次复制链接") {
                                MacPlatformServices.copyText(formatCopyText(created, plainPasscode: justCreatedPasscode))
                                store.showToast("已复制外链信息")
                            }
                            MacIconButton(symbol: "globe", size: 12.5, help: "在浏览器中打开预览") {
                                let base = store.buildFullShareURL(created.sharePath)
                                let full = justCreatedPasscode.map { "\(base)?p=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" } ?? base
                                if let url = URL(string: full) {
                                    MacPlatformServices.openURL(url)
                                }
                            }
                        }
                        Text(formatCopyText(created, plainPasscode: justCreatedPasscode))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(MacTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(MacTheme.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MacTheme.green.opacity(0.35), lineWidth: 0.7))
                }
            }
            .padding(12)
        }
    }

    // MARK: - Compact Single-Row Share Card (matches Flutter _buildShareCard 1:1)

    private func shareRow(_ link: ShareLinkInfo) -> some View {
        let fullURL = store.buildFullShareURL(link.sharePath)
        let inactive = link.isExpired || link.isExhausted

        let meta: [String] = {
            var parts: [String] = []
            if link.itemCount > 1 { parts.append("\(link.itemCount) 项合集") }
            if link.hasPasscode { parts.append("需提取码") }
            if let maxDl = link.maxDownloads {
                parts.append("已下 \(link.downloadCount)/\(maxDl) 次")
            } else {
                parts.append("已下 \(link.downloadCount) 次")
            }
            if link.isExpired {
                parts.append("已过期")
            } else if link.isExhausted {
                parts.append("次数用尽")
            } else if let exp = link.expiresAt {
                parts.append(formatRemaining(exp))
            } else {
                parts.append("永久有效")
            }
            return parts
        }()

        return HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(MacTheme.fill(0.07))
                Image(systemName: link.hasPasscode ? "lock.fill" : (link.itemCount > 1 ? "square.stack" : "link"))
                    .font(.system(size: 13))
                    .foregroundStyle(inactive ? MacTheme.textTertiary : MacTheme.textPrimary)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(link.itemName.isEmpty ? link.code : link.itemName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(inactive ? MacTheme.textTertiary : MacTheme.textPrimary)
                    .lineLimit(1)
                Text(meta.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(inactive ? MacTheme.red.opacity(0.85) : MacTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 1) {
                MacIconButton(symbol: "doc.on.doc", size: 12.5, help: "复制外链 (\(fullURL))") {
                    MacPlatformServices.copyText(fullURL)
                    store.showToast("已复制外链：\(fullURL)")
                }
                MacIconButton(symbol: "globe", size: 12.5, help: "浏览器打开") {
                    if let url = URL(string: fullURL) {
                        MacPlatformServices.openURL(url)
                    }
                }
                MacIconButton(symbol: "trash", tint: MacTheme.red, size: 12.5, help: "撤销外链") {
                    Task { await store.deleteShareLink(code: link.code) }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(MacTheme.cardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(MacTheme.hairline, lineWidth: 0.7)
        )
    }

    private func formatRemaining(_ date: Date) -> String {
        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return "已过期" }
        let days = Int(diff / 86400)
        if days >= 1 { return "剩余 \(days) 天" }
        let hours = Int(diff / 3600)
        if hours >= 1 { return "剩余 \(hours) 小时" }
        return "剩余 \(max(1, Int(diff / 60))) 分钟"
    }

    private func generatePasscode() {
        let chars = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        passcode = String((0..<4).map { _ in chars.randomElement()! })
    }

    private func formatCopyText(_ link: ShareLinkInfo, plainPasscode: String?) -> String {
        let url = store.buildFullShareURL(link.sharePath)
        if let plainPasscode, !plainPasscode.isEmpty {
            return "链接：\(url)\n提取码：\(plainPasscode)"
        }
        return url
    }

    private func createShare() async {
        guard !targetItems.isEmpty, !creating else { return }
        creating = true
        errorMsg = nil
        defer { creating = false }
        let cleanPass = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = bundleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let info = try await store.createShareLink(
                items: targetItems,
                title: cleanTitle.isEmpty ? nil : cleanTitle,
                passcode: cleanPass.isEmpty ? nil : cleanPass,
                expiresHours: expiresHours > 0 ? expiresHours : nil,
                maxDownloads: maxDownloads > 0 ? maxDownloads : nil
            )
            justCreated = info
            justCreatedPasscode = cleanPass.isEmpty ? nil : cleanPass
            MacPlatformServices.copyText(formatCopyText(info, plainPasscode: justCreatedPasscode))
            store.showToast("外链已生成并自动复制到剪贴板")
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
