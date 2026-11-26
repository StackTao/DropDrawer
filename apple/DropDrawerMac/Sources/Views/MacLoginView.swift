import AppKit
import DropDrawerCore
import SwiftUI

public struct MacLoginView: View {
    @Bindable var store: DropDrawerStore
    @Bindable var controller: EdgeDrawerController

    @State private var serverInput = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isRegister = false
    @State private var googleTask: Task<Void, Never>?

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 44)

                Text("DropDrawer")
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(MacTheme.textPrimary)
                    .padding(.top, 16)

                Text("跨端文件暂存抽屉")
                    .font(.system(size: 12))
                    .foregroundStyle(MacTheme.textSecondary)
                    .padding(.top, 4)

                MacGroupedCard(alpha: 0.24) {
                    MacFormRow(
                        label: "服务器",
                        placeholder: "http://127.0.0.1:8080",
                        text: $serverInput
                    )
                    MacDivider(indent: 12)
                    MacFormRow(
                        label: "账号",
                        placeholder: "输入用户名",
                        text: $username
                    )
                    MacDivider(indent: 12)
                    MacFormRow(
                        label: "密码",
                        placeholder: "至少 6 位",
                        text: $password,
                        secure: true,
                        onSubmit: { submit() }
                    )
                }
                .padding(.top, 28)

                if let err = store.authError, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacTheme.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                }

                MacPrimaryButton(
                    title: isRegister ? "创建账号并连接" : "继续",
                    loading: store.authLoading && googleTask == nil,
                    disabled: !canSubmit
                ) {
                    submit()
                }
                .padding(.top, 18)

                Group {
                    if googleTask != nil {
                        VStack(spacing: 6) {
                            Text("请在系统浏览器完成 Google 授权，然后返回 DropDrawer。")
                                .font(.system(size: 12))
                                .foregroundStyle(MacTheme.textSecondary)
                                .multilineTextAlignment(.center)
                            Button("取消等待") {
                                googleTask?.cancel()
                                googleTask = nil
                                store.authLoading = false
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MacTheme.accent)
                        }
                        .padding(.top, 10)
                    } else {
                        MacSecondaryButton(
                            title: "使用 Google 登录",
                            height: 36,
                            disabled: store.authLoading || serverInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ) {
                            startGoogleLogin()
                        }
                        .padding(.top, 8)
                    }
                }

                if !store.authLoading, let privacy = privacyURL {
                    Button("隐私说明") {
                        MacPlatformServices.openURL(privacy)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacTheme.textSecondary)
                    .padding(.top, 12)
                }

                Button(isRegister ? "已有账号，返回登录" : "还没有账号？创建一个") {
                    withAnimation(.easeOut(duration: 0.14)) {
                        isRegister.toggle()
                        store.authError = nil
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(MacTheme.textSecondary)
                .disabled(store.authLoading)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 300)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
        }
        .onAppear {
            if serverInput.isEmpty {
                serverInput = store.serverUrl
            }
        }
        .onDisappear {
            googleTask?.cancel()
            googleTask = nil
        }
    }

    private var canSubmit: Bool {
        !serverInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    private var privacyURL: URL? {
        let base = serverInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = URL(string: "\(base)/privacy"),
              url.scheme == "http" || url.scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    private func submit() {
        guard canSubmit, !store.authLoading else { return }
        Task {
            await store.login(server: serverInput, username: username, password: password, register: isRegister)
        }
    }

    private func startGoogleLogin() {
        let server = serverInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { return }
        store.authError = nil
        googleTask?.cancel()
        googleTask = Task {
            do {
                let start = try await store.startGoogleSignIn(server: server)
                MacPlatformServices.openURL(start.url)
                await store.completeGoogleSignIn(start: start)
            } catch {
                store.authError = error.localizedDescription
            }
            googleTask = nil
        }
    }
}
