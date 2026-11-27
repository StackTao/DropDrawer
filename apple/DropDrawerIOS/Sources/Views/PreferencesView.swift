import DropDrawerCore
import SwiftUI
import UIKit

struct PreferencesView: View {
    @Bindable var store: DropDrawerStore
    @Environment(\.openURL) private var openURL
    @State private var confirmLogout: Bool = false
    @State private var confirmClearCache: Bool = false
    @State private var showChangePassword: Bool = false
    @State private var showBindEmail: Bool = false
    @State private var showDeleteAccount: Bool = false
    @State private var localCacheBytes: Int64 = 0

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.3"
    }

    private var cleanServerHost: String {
        URL(string: store.serverUrl)?.host ?? store.serverUrl
    }

    /// Keep the server default available and limit explicit presets to the cap.
    private var ttlOptions: [(Int, String)] {
        let base: [(Int, String)] = [(0, String(localized: "跟随服务器")), (24, String(localized: "24 小时")), (168, String(localized: "7 天")), (720, String(localized: "30 天"))]
        guard let cap = store.maxItemTtlHours, cap > 0 else { return base }
        var options = base.filter { $0.0 <= cap }
        if !options.contains(where: { $0.0 == cap }) {
            options.append((cap, (cap % 24 == 0 ? String(localized: "\(cap / 24) 天", locale: AppLanguage.locale) : String(localized: "\(cap) 小时", locale: AppLanguage.locale)) + String(localized: "（上限）")))
        }
        return options
    }

    /// The stored preference, shown as the cap when it exceeds it.
    private var ttlSelection: Int {
        let value = store.defaultTtlHours
        if ttlOptions.contains(where: { $0.0 == value }) { return value }
        return store.maxItemTtlHours ?? value
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.gradient)
                        Text(String((store.user?.username ?? "U").prefix(1)).uppercased())
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.user?.username ?? String(localized: "已登录"))
                            .font(.headline)
                        Text(cleanServerHost)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        Circle()
                            .fill(store.wsConnected ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                        Text(store.wsConnected ? String(localized: "已连接") : String(localized: "离线"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                NavigationLink {
                    DevicesView(store: store)
                } label: {
                    LabeledContent {
                        Text(String(localized: "\(store.onlineDeviceCount) 台在线"))
                    } label: {
                        Label {
                            Text(String(localized: "设备与 P2P"))
                        } icon: {
                            SettingsIconBadge(systemImage: "laptopcomputer.and.iphone", color: .blue)
                        }
                    }
                }

                NavigationLink {
                    StorageSettingsView(store: store)
                } label: {
                    LabeledContent {
                        Text(store.defaultStorageBackendName)
                    } label: {
                        Label {
                            Text(String(localized: "云盘与存储"))
                        } icon: {
                            SettingsIconBadge(systemImage: "cloud.fill", color: .cyan)
                        }
                    }
                }
            } header: {
                Text(String(localized: "连接与存储"))
            }

            Section {
                Picker(selection: Binding(
                    get: { store.dropPolicy },
                    set: { store.setDropPolicy($0) }
                )) {
                    ForEach(DropPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                } label: {
                    Label {
                        Text(String(localized: "传输策略"))
                    } icon: {
                        SettingsIconBadge(systemImage: "arrow.left.arrow.right", color: .indigo)
                    }
                }

                Picker(selection: Binding(
                    get: { store.autoCloudThresholdMb },
                    set: { store.setAutoCloudThresholdMb($0) }
                )) {
                    Text("10 MB").tag(10)
                    Text("20 MB").tag(20)
                    Text("50 MB").tag(50)
                    Text("100 MB").tag(100)
                } label: {
                    Label {
                        Text(String(localized: "智能上云阈值"))
                    } icon: {
                        SettingsIconBadge(systemImage: "gauge.medium", color: .teal)
                    }
                }

                Picker(selection: Binding(
                    get: { ttlSelection },
                    set: { store.setDefaultTtlHours($0) }
                )) {
                    ForEach(ttlOptions, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                } label: {
                    Label {
                        Text(String(localized: "自动清理"))
                    } icon: {
                        SettingsIconBadge(systemImage: "clock.arrow.circlepath", color: .orange)
                    }
                }
            } header: {
                Text(String(localized: "传输与清理"))
            } footer: {
                Text(String(localized: "智能模式下小文件同步存云盘、大文件直连 P2P；到期后自动清理云端缓存与列表记录。"))
            }

            Section(String(localized: "下载与关于")) {
                LabeledContent(String(localized: "保存位置"), value: String(localized: "「文件」App › DropDrawer"))
                LabeledContent(String(localized: "本地缓存"), value: formatBytes(localCacheBytes))
                Button(String(localized: "清理本地缓存"), role: .destructive) {
                    confirmClearCache = true
                }
                .disabled(localCacheBytes == 0)
                // iOS keeps the per-app language in Settings › DropDrawer › Language.
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    LabeledContent(String(localized: "语言"), value: AppLanguage.isChinese ? "简体中文" : "English")
                }
                .foregroundStyle(.primary)
                .accessibilityHint(String(localized: "在「设置」中更改 DropDrawer 的显示语言"))
                LabeledContent(String(localized: "版本"), value: appVersion)
                if let url = URL(string: "https://github.com/StackTao/DropDrawer/releases") {
                    Button(String(localized: "查看发布页")) {
                        openURL(url)
                    }
                }
            }

            Section {
                let email = store.accountInfo?.email ?? store.user?.email
                let hasEmail = !(email ?? "").isEmpty
                let hasPassword = store.accountInfo?.hasPassword ?? true
                let emailBindingAvailable = store.accountInfo?.emailBindingAvailable ?? false

                if store.accountInfo?.googleLinked == true {
                    LabeledContent(String(localized: "第三方登录"), value: String(localized: "已关联 Google"))
                }

                if emailBindingAvailable {
                    Button {
                        showBindEmail = true
                    } label: {
                        LabeledContent {
                            Text(hasEmail ? (email ?? "") : String(localized: "未绑定"))
                                .foregroundStyle(.secondary)
                        } label: {
                            Label {
                                Text(hasEmail ? String(localized: "更换邮箱") : String(localized: "绑定邮箱"))
                            } icon: {
                                SettingsIconBadge(systemImage: "envelope.fill", color: .blue)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                } else if hasEmail {
                    LabeledContent {
                        Text(email ?? "")
                    } label: {
                        Label {
                            Text(String(localized: "绑定邮箱"))
                        } icon: {
                            SettingsIconBadge(systemImage: "envelope.fill", color: .blue)
                        }
                    }
                }

                Button {
                    showChangePassword = true
                } label: {
                    Label {
                        Text(hasPassword ? String(localized: "修改密码") : String(localized: "设置密码"))
                    } icon: {
                        SettingsIconBadge(systemImage: "key.fill", color: .purple)
                    }
                }
                .foregroundStyle(.primary)

                Button(role: .destructive) {
                    showDeleteAccount = true
                } label: {
                    Label {
                        Text(String(localized: "注销账号"))
                    } icon: {
                        SettingsIconBadge(systemImage: "person.crop.circle.badge.xmark", color: .red)
                    }
                }
            } header: {
                Text(String(localized: "账号与安全"))
            } footer: {
                Text(String(localized: "修改密码会让其他设备下线；注销账号会永久删除所有云端文件、外链和设备记录。"))
            }

            Section {
                Button(String(localized: "退出登录"), role: .destructive) {
                    confirmLogout = true
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(String(localized: "设置"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            localCacheBytes = store.localCacheSizeBytes()
            await store.refreshAccountInfo()
        }
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordSheet(
                store: store,
                hasPassword: store.accountInfo?.hasPassword ?? true
            )
        }
        .sheet(isPresented: $showBindEmail) {
            BindEmailSheet(
                store: store,
                initialEmail: store.accountInfo?.email ?? store.user?.email ?? ""
            )
        }
        .sheet(isPresented: $showDeleteAccount) {
            DeleteAccountSheet(
                store: store,
                username: store.accountInfo?.username ?? store.user?.username ?? "",
                hasPassword: store.accountInfo?.hasPassword ?? true
            )
        }
        .confirmationDialog(String(localized: "清理已下载的本地缓存文件？"), isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button(String(localized: "清理本地缓存"), role: .destructive) {
                _ = store.clearLocalCache()
                ThumbnailImageCache.shared.clear()
                localCacheBytes = store.localCacheSizeBytes()
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "仅删除本机缓存副本，不影响云端与列表记录。"))
        }
        .confirmationDialog(String(localized: "退出当前账号？"), isPresented: $confirmLogout, titleVisibility: .visible) {
            Button(String(localized: "退出登录"), role: .destructive) {
                ThumbnailImageCache.shared.clear()
                store.logout()
            }
            Button(String(localized: "取消"), role: .cancel) {}
        }
    }
}

private struct SettingsIconBadge: View {
    let systemImage: String
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.gradient)
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
    }
}

private struct ChangePasswordSheet: View {
    let store: DropDrawerStore
    let hasPassword: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword: String = ""
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var submitting: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if hasPassword {
                    Section {
                        SecureField(String(localized: "当前密码"), text: $currentPassword)
                            .textContentType(.password)
                    }
                }

                Section {
                    SecureField(String(localized: "新密码（至少 6 位）"), text: $newPassword)
                        .textContentType(.newPassword)
                    SecureField(String(localized: "确认新密码"), text: $confirmPassword)
                        .textContentType(.newPassword)
                } footer: {
                    Text(hasPassword
                         ? String(localized: "修改密码后，其他已登录设备需要重新登录。")
                         : String(localized: "设置密码后，除了 Google 登录，也可使用用户名和密码登录。"))
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(hasPassword ? String(localized: "修改密码") : String(localized: "设置密码"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                        .disabled(submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存")) {
                        Task { await submit() }
                    }
                    .disabled(submitting)
                }
            }
        }
    }

    private func submit() async {
        if hasPassword && currentPassword.isEmpty {
            errorMessage = String(localized: "请输入当前密码")
            return
        }
        if newPassword.count < 6 {
            errorMessage = String(localized: "新密码至少 6 位")
            return
        }
        if newPassword != confirmPassword {
            errorMessage = String(localized: "两次输入的新密码不一致")
            return
        }
        submitting = true
        errorMessage = nil
        defer { submitting = false }
        do {
            try await store.changeOwnPassword(
                currentPassword: hasPassword ? currentPassword : nil,
                newPassword: newPassword
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BindEmailSheet: View {
    let store: DropDrawerStore
    let initialEmail: String
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var code: String = ""
    @State private var currentPassword: String = ""
    @State private var cooldown: Int = 0
    @State private var sending: Bool = false
    @State private var submitting: Bool = false
    @State private var infoMessage: String?
    @State private var errorMessage: String?
    @State private var cooldownTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "邮箱地址"), text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)

                    HStack {
                        TextField(String(localized: "6 位验证码"), text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        Button {
                            Task { await sendCode() }
                        } label: {
                            if cooldown > 0 {
                                Text(String(localized: "\(cooldown)s 后重发"))
                            } else {
                                Text(String(localized: "发送验证码"))
                            }
                        }
                        .disabled(sending || cooldown > 0 || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    // The recovery email only changes with the current password; accounts
                    // without one must have signed in recently (the server checks both).
                    if needsPassword {
                        SecureField(String(localized: "当前密码"), text: $currentPassword)
                            .textContentType(.password)
                    }
                } footer: {
                    Text(String(localized: "绑定后可用于邮箱登录和找回密码。"))
                }

                if let infoMessage {
                    Section {
                        Text(infoMessage)
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(initialEmail.isEmpty ? String(localized: "绑定邮箱") : String(localized: "更换邮箱"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if email.isEmpty { email = initialEmail }
            }
            .onDisappear {
                cooldownTask?.cancel()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                        .disabled(submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存")) {
                        Task { await submit() }
                    }
                    .disabled(submitting || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (needsPassword && currentPassword.isEmpty))
                }
            }
        }
    }

    private var needsPassword: Bool {
        store.accountInfo?.hasPassword ?? false
    }

    private func startCooldown() {
        cooldownTask?.cancel()
        cooldown = 60
        cooldownTask = Task {
            while cooldown > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled {
                    cooldown -= 1
                }
            }
        }
    }

    private func sendCode() async {
        sending = true
        errorMessage = nil
        infoMessage = nil
        defer { sending = false }
        do {
            try await store.sendBindEmailCode(email: email)
            startCooldown()
            infoMessage = String(localized: "验证码已发送到邮箱")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submit() async {
        submitting = true
        errorMessage = nil
        defer { submitting = false }
        do {
            try await store.confirmBindEmail(
                email: email,
                code: code,
                currentPassword: needsPassword ? currentPassword : nil
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DeleteAccountSheet: View {
    let store: DropDrawerStore
    let username: String
    let hasPassword: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var confirmationInput: String = ""
    @State private var submitting: Bool = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        if submitting { return false }
        if hasPassword { return !confirmationInput.isEmpty }
        return confirmationInput.trimmingCharacters(in: .whitespacesAndNewlines) == username && !username.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(String(localized: "注销后将立即永久删除你的账号、全部抽屉记录、云端文件、外链分享与设备信息，且无法恢复。"))
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    if hasPassword {
                        SecureField(String(localized: "输入当前密码以确认"), text: $confirmationInput)
                            .textContentType(.password)
                    } else {
                        TextField(String(localized: "输入用户名「\(username)」以确认"), text: $confirmationInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if submitting {
                                ProgressView()
                            } else {
                                Text(String(localized: "确认永久注销"))
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle(String(localized: "注销账号"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                        .disabled(submitting)
                }
            }
        }
    }

    private func submit() async {
        submitting = true
        errorMessage = nil
        defer { submitting = false }
        do {
            try await store.deleteOwnAccount(
                password: hasPassword ? confirmationInput : nil,
                confirmUsername: hasPassword ? nil : confirmationInput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            ThumbnailImageCache.shared.clear()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
