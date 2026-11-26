import DropDrawerCore
import SwiftUI

struct ShareLinksView: View {
    @Bindable var store: DropDrawerStore
    let targetItems: [DrawerItem]

    @Environment(\.openURL) private var openURL

    @State private var bundleTitle: String = ""
    @State private var passcode: String = ""
    @State private var expiresHours: Int = 168
    @State private var maxDownloads: Int = 0
    @State private var creating: Bool = false
    @State private var errorMessage: String?
    @State private var justCreated: ShareLinkInfo?
    @State private var justCreatedPasscode: String?
    @State private var selectedLink: ShareLinkInfo?

    private var isBundle: Bool { targetItems.count > 1 }

    private static func hoursLabel(_ h: Int) -> String {
        h % 24 == 0 ? "\(h / 24) 天" : "\(h) 小时"
    }

    /// Applies an administrator cap: drops "unlimited" (0) and larger choices and
    /// offers the cap itself when it is not one of the presets.
    private static func capped(_ base: [(Int, String)], cap: Int?, label: (Int) -> String) -> [(Int, String)] {
        guard let cap, cap > 0 else { return base }
        var options = base.filter { $0.0 > 0 && $0.0 <= cap }
        if !options.contains(where: { $0.0 == cap }) { options.append((cap, label(cap))) }
        return options
    }

    private var expiryOptions: [(Int, String)] {
        Self.capped(
            [(1, "1 小时"), (24, "24 小时"), (168, "7 天"), (0, "永久")],
            cap: store.maxShareExpiresHours
        ) { "\(Self.hoursLabel($0))（上限）" }
    }

    private var downloadOptions: [(Int, String)] {
        Self.capped(
            [(0, "不限"), (1, "1 次（阅后即焚）"), (5, "5 次"), (20, "20 次")],
            cap: store.maxShareDownloads
        ) { "\($0) 次（上限）" }
    }

    /// Keeps the selected values inside the administrator's caps.
    private func clampChoices() {
        let expiry = expiryOptions
        if !expiry.contains(where: { $0.0 == expiresHours }) {
            expiresHours = expiry.last(where: { $0.0 > 0 && $0.0 <= 168 })?.0 ?? expiry.first?.0 ?? 0
        }
        let downloads = downloadOptions
        if !downloads.contains(where: { $0.0 == maxDownloads }) {
            maxDownloads = downloads.last?.0 ?? 0
        }
    }
    private var totalBytes: Int64 { targetItems.reduce(0) { $0 + $1.size } }
    private var pendingUploadCount: Int {
        targetItems.filter { !$0.isText && !$0.cloudReady }.count
    }

    var body: some View {
        List {
            if !targetItems.isEmpty {
                createSections
            }

            if let created = justCreated {
                createdSection(created)
            }

            existingLinksSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(targetItems.isEmpty ? "外链管理" : (isBundle ? "创建合集外链" : "创建外链"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refreshShareLinks()
        }
        .task {
            await store.refreshShareLinks()
        }
        .confirmationDialog(
            selectedLink?.itemName ?? "外链操作",
            isPresented: Binding(
                get: { selectedLink != nil },
                set: { if !$0 { selectedLink = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let link = selectedLink {
                Button("复制链接") {
                    UIPasteboard.general.string = store.buildFullShareURL(link.sharePath)
                    store.showToast("已复制外链")
                }
                if let url = URL(string: store.buildFullShareURL(link.sharePath)) {
                    Button("在浏览器中打开") {
                        openURL(url)
                    }
                }
                Button("撤销外链", role: .destructive) {
                    Task { await store.deleteShareLink(code: link.code) }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private var createSections: some View {
        Section {
            ForEach(targetItems.prefix(8)) { item in
                HStack(spacing: 12) {
                    ItemThumbnailView(store: store, item: item, size: 32)
                    Text(item.name)
                        .lineLimit(1)
                    Spacer()
                    Text(formatBytes(item.size))
                        .foregroundStyle(.secondary)
                }
            }
            if targetItems.count > 8 {
                Text("以及另外 \(targetItems.count - 8) 项")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(isBundle ? "打包 \(targetItems.count) 项 · \(formatBytes(totalBytes))" : "分享内容")
        } footer: {
            if pendingUploadCount > 0 {
                Text("生成前会先把 \(pendingUploadCount) 个文件上传到「\(store.defaultStorageBackendName)」，拿到链接的人用浏览器即可下载，无需登录。")
            } else {
                Text("拿到链接的人用浏览器即可下载，无需登录。")
            }
        }

        if isBundle {
            Section("合集标题") {
                TextField("\(targetItems.first?.name ?? "文件") 等 \(targetItems.count) 项", text: $bundleTitle)
            }
        }

        Section {
            Picker("有效期", selection: $expiresHours) {
                ForEach(expiryOptions, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            Picker("下载次数", selection: $maxDownloads) {
                ForEach(downloadOptions, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .task(id: store.clientConfig) {
                clampChoices()
            }
            HStack {
                Text(store.shareRequiresPasscode ? "提取码（必填）" : "提取码")
                TextField(store.shareRequiresPasscode ? "必填" : "留空为公开", text: $passcode)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    passcode = randomPasscode()
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("随机生成提取码")
            }
        } header: {
            Text("访问设置")
        } footer: {
            Text(store.shareRequiresPasscode
                 ? "服务器要求外链必须设置提取码。"
                 : "提取码留空时，任何拿到链接的人都能下载。")
        }

        if let errorMessage {
            Section {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }

        Section {
            Button {
                Task { await createShare() }
            } label: {
                HStack {
                    Spacer()
                    if creating {
                        ProgressView()
                            .padding(.trailing, 6)
                        Text("正在生成…")
                    } else {
                        Text(pendingUploadCount > 0
                             ? "上传并生成外链"
                             : (isBundle ? "生成合集外链并复制" : "生成外链并复制"))
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(creating)
        }
    }

    private func createdSection(_ link: ShareLinkInfo) -> some View {
        let copyText = formatCopyText(link, plainPasscode: justCreatedPasscode)
        return Section("已生成并复制到剪贴板") {
            Text(copyText)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
            Button("再次复制") {
                UIPasteboard.general.string = copyText
                store.showToast("已复制外链信息")
            }
            if let url = shareOpenURL(link, plainPasscode: justCreatedPasscode) {
                Button("在浏览器中打开") {
                    openURL(url)
                }
            }
        }
    }

    private var existingLinksSection: some View {
        Section {
            if store.shareLinks.isEmpty {
                Text("还没有外链")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.shareLinks) { link in
                    let inactive = link.isExpired || link.isExhausted
                    Button {
                        selectedLink = link
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(link.itemName)
                                    .foregroundStyle(inactive ? .secondary : .primary)
                                    .lineLimit(1)
                                Text(linkSubtitle(link))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if inactive {
                                Text(link.isExpired ? "已过期" : "已用完")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await store.deleteShareLink(code: link.code) }
                        } label: {
                            Label("撤销", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("已创建的外链（\(store.shareLinks.count)）")
        } footer: {
            Text(store.shareLinks.isEmpty
                 ? "在首页长按或打开任意一项即可创建外链；多选后可打包成合集。"
                 : "点按外链可复制、打开或撤销，左滑可直接撤销。")
        }
    }

    private func linkSubtitle(_ link: ShareLinkInfo) -> String {
        var parts: [String] = []
        if link.itemCount > 1 { parts.append("\(link.itemCount) 项合集") }
        parts.append(formatBytes(link.itemSize))
        if let max = link.maxDownloads {
            parts.append("已下 \(link.downloadCount)/\(max) 次")
        } else {
            parts.append("已下 \(link.downloadCount) 次")
        }
        if link.hasPasscode { parts.append("需提取码") }
        return parts.joined(separator: " · ")
    }

    private func createShare() async {
        creating = true
        errorMessage = nil
        defer { creating = false }
        let trimmedPass = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let link = try await store.createShareLink(
                items: targetItems,
                title: isBundle ? bundleTitle : nil,
                passcode: trimmedPass.isEmpty ? nil : trimmedPass,
                expiresHours: expiresHours > 0 ? expiresHours : nil,
                maxDownloads: maxDownloads > 0 ? maxDownloads : nil
            )
            justCreated = link
            justCreatedPasscode = trimmedPass.isEmpty ? nil : trimmedPass
            let text = formatCopyText(link, plainPasscode: justCreatedPasscode)
            UIPasteboard.general.string = text
            store.showToast("已生成外链并复制")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatCopyText(_ link: ShareLinkInfo, plainPasscode: String?) -> String {
        let url = store.buildFullShareURL(link.sharePath)
        if let pass = plainPasscode, !pass.isEmpty {
            return "\(url)\n提取码：\(pass)"
        }
        return url
    }

    private func shareOpenURL(_ link: ShareLinkInfo, plainPasscode: String?) -> URL? {
        let base = store.buildFullShareURL(link.sharePath)
        if let pass = plainPasscode, !pass.isEmpty,
           let encoded = pass.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: "\(base)?p=\(encoded)")
        }
        return URL(string: base)
    }

    private func randomPasscode() -> String {
        let chars = Array("23456789abcdefghjkmnpqrstuvwxyz")
        return String((0..<4).compactMap { _ in chars.randomElement() })
    }
}
