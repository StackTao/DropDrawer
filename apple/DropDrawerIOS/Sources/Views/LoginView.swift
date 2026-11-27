import DropDrawerCore
import SwiftUI

private enum AuthScreenMode {
    case login
    case register
    case resetPassword
}

struct LoginView: View {
    @Bindable var store: DropDrawerStore
    @Environment(\.openURL) private var openURL

    @State private var serverUrl: String = ""
    @State private var username: String = ""
    @State private var email: String = ""
    @State private var emailCode: String = ""
    @State private var inviteCode: String = ""
    @State private var password: String = ""
    @State private var mode: AuthScreenMode = .login
    @State private var serverConfig: AuthPublicConfig?
    @State private var infoMessage: String?
    @State private var sendingCode: Bool = false
    @State private var cooldownSeconds: Int = 0
    @State private var cooldownTask: Task<Void, Never>?
    @State private var configTask: Task<Void, Never>?
    @State private var googleBusy: Bool = false
    @State private var googleTask: Task<Void, Never>?
    @State private var authCoordinator = WebAuthCoordinator()

    private var showPasswordForm: Bool {
        mode != .login || (serverConfig?.passwordLoginEnabled ?? true)
    }

    private var showRegisterToggle: Bool {
        serverConfig?.registrationAllowed ?? true
    }

    private var requireEmail: Bool {
        mode == .register && (serverConfig?.emailVerificationRequired ?? false)
    }

    private var requireInvite: Bool {
        mode == .register && (serverConfig?.inviteCodeRequired ?? false)
    }

    private var showResetEntry: Bool {
        mode == .login && (serverConfig?.emailPasswordResetEnabled ?? false)
    }

    private var showGoogleButton: Bool {
        mode != .resetPassword && (serverConfig == nil || serverConfig?.googleEnabled == true)
    }

    private var canSubmitPrimary: Bool {
        if store.authLoading { return false }
        let trimmedServer = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedServer.isEmpty || password.count < 6 { return false }
        switch mode {
        case .login:
            return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .register:
            if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            if requireEmail && (email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || emailCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                return false
            }
            if requireInvite && inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            return true
        case .resetPassword:
            return !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !emailCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image("AppMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        Text("DropDrawer")
                            .font(.title2.weight(.bold))
                        Text(mode == .resetPassword ? String(localized: "通过邮箱验证码重置密码") : String(localized: "跨端文件传输与云端同步"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }

                Section {
                    LabeledContent(String(localized: "服务器")) {
                        TextField("https://your-server", text: $serverUrl)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                    }

                    if showPasswordForm && mode != .resetPassword {
                        LabeledContent(String(localized: "账号")) {
                            TextField(mode == .login ? String(localized: "用户名或已验证邮箱") : String(localized: "输入用户名"), text: $username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    if requireEmail || mode == .resetPassword {
                        LabeledContent(String(localized: "邮箱")) {
                            TextField("you@example.com", text: $email)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.emailAddress)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text(String(localized: "验证码"))
                            TextField(String(localized: "6 位数字"), text: $emailCode)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                            Button {
                                sendVerificationCode()
                            } label: {
                                if sendingCode {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text(cooldownSeconds > 0 ? "\(cooldownSeconds)s" : String(localized: "获取验证码"))
                                        .font(.footnote.weight(.medium))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(sendingCode || cooldownSeconds > 0 || store.authLoading)
                        }
                    }

                    if requireInvite {
                        LabeledContent(String(localized: "邀请码")) {
                            TextField(String(localized: "输入管理员邀请码"), text: $inviteCode)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    if showPasswordForm {
                        LabeledContent(mode == .resetPassword ? String(localized: "新密码") : String(localized: "密码")) {
                            SecureField(String(localized: "至少 6 位"), text: $password)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                if let info = infoMessage {
                    Section {
                        Text(info)
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }

                if let err = store.authError {
                    Section {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    VStack(spacing: 12) {
                        if showPasswordForm {
                            Button {
                                Task { await submitPrimary() }
                            } label: {
                                Group {
                                    if store.authLoading && !googleBusy {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Text(primaryButtonTitle)
                                            .fontWeight(.semibold)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                            .disabled(!canSubmitPrimary)
                        }

                        if showGoogleButton {
                            Button {
                                startGoogleFlow()
                            } label: {
                                HStack(spacing: 8) {
                                    if googleBusy {
                                        ProgressView()
                                        Text(String(localized: "等待 Google 授权…"))
                                    } else {
                                        Image(systemName: "globe")
                                        Text(mode == .register ? String(localized: "使用 Google 注册") : String(localized: "使用 Google 登录"))
                                            .fontWeight(.medium)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                            .disabled(store.authLoading || serverUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        VStack(spacing: 10) {
                            if showRegisterToggle || mode != .login {
                                Button(mode == .login ? String(localized: "还没有账号？创建一个") : String(localized: "已有账号？返回登录")) {
                                    withAnimation {
                                        mode = mode == .login ? .register : .login
                                        store.authError = nil
                                        infoMessage = nil
                                    }
                                }
                                .font(.subheadline)
                            }

                            HStack(spacing: 16) {
                                if showResetEntry {
                                    Button(String(localized: "忘记密码？")) {
                                        withAnimation {
                                            mode = .resetPassword
                                            store.authError = nil
                                            infoMessage = nil
                                        }
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                }

                                if let privacy = URL(string: "\(serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression))/privacy") {
                                    Button(String(localized: "隐私说明")) {
                                        openURL(privacy)
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .onAppear {
                if serverUrl.isEmpty { serverUrl = store.serverUrl }
                scheduleFetchConfig(immediate: true)
            }
            .onChange(of: serverUrl) { _, _ in
                scheduleFetchConfig(immediate: false)
            }
            .onDisappear {
                googleTask?.cancel()
                configTask?.cancel()
                cooldownTask?.cancel()
            }
        }
    }

    private var primaryButtonTitle: String {
        switch mode {
        case .login: return String(localized: "继续")
        case .register: return String(localized: "创建账号并登录")
        case .resetPassword: return String(localized: "确认重置密码")
        }
    }

    private func scheduleFetchConfig(immediate: Bool) {
        configTask?.cancel()
        let target = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        configTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
            }
            let cfg = await store.fetchAuthConfig(server: target)
            guard !Task.isCancelled,
                  serverUrl.trimmingCharacters(in: .whitespacesAndNewlines) == target
            else { return }
            withAnimation {
                serverConfig = cfg
                if let cfg {
                    if !cfg.registrationAllowed && mode == .register { mode = .login }
                    if !cfg.emailPasswordResetEnabled && mode == .resetPassword { mode = .login }
                }
            }
        }
    }

    private func sendVerificationCode() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, trimmedEmail.contains("@") else {
            store.authError = String(localized: "请先填写有效的邮箱地址")
            return
        }
        sendingCode = true
        store.authError = nil
        infoMessage = nil
        let purpose = mode == .resetPassword ? "reset_password" : "register"
        Task {
            defer { sendingCode = false }
            do {
                try await store.sendEmailCode(server: serverUrl, email: trimmedEmail, purpose: purpose)
                infoMessage = String(localized: "验证码已发送，请查收邮件（10 分钟内有效）")
                startCooldown()
            } catch {
                store.authError = error.localizedDescription
            }
        }
    }

    private func startCooldown() {
        cooldownTask?.cancel()
        cooldownSeconds = 60
        cooldownTask = Task {
            while cooldownSeconds > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                cooldownSeconds -= 1
            }
        }
    }

    private func submitPrimary() async {
        infoMessage = nil
        if mode == .resetPassword {
            store.authLoading = true
            store.authError = nil
            defer { store.authLoading = false }
            do {
                try await store.resetPassword(
                    server: serverUrl,
                    email: email,
                    code: emailCode,
                    newPassword: password
                )
                withAnimation {
                    mode = .login
                    username = email.trimmingCharacters(in: .whitespacesAndNewlines)
                    emailCode = ""
                    password = ""
                    infoMessage = String(localized: "密码已重置，请使用新密码登录")
                }
            } catch {
                store.authError = error.localizedDescription
            }
            return
        }

        await store.login(
            server: serverUrl,
            username: username,
            password: password,
            register: mode == .register,
            email: mode == .register ? email : nil,
            emailCode: mode == .register ? emailCode : nil,
            inviteCode: mode == .register ? inviteCode : nil
        )
    }

    private func startGoogleFlow() {
        let trimmedInvite = mode == .register ? inviteCode.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if mode == .register && requireInvite && trimmedInvite.isEmpty {
            store.authError = String(localized: "当前服务器需要邀请码，请先填写邀请码再使用 Google 注册")
            infoMessage = nil
            return
        }
        googleTask?.cancel()
        googleBusy = true
        store.authError = nil
        infoMessage = nil
        googleTask = Task {
            defer { googleBusy = false }
            do {
                let start = try await store.startGoogleSignIn(
                    server: serverUrl,
                    inviteCode: trimmedInvite.isEmpty ? nil : trimmedInvite
                )
                authCoordinator.start(url: start.url)
                await store.completeGoogleSignIn(start: start)
            } catch {
                store.authError = error.localizedDescription
            }
        }
    }
}
