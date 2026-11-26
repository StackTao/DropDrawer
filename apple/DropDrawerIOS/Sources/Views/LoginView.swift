import DropDrawerCore
import SwiftUI

struct LoginView: View {
    @Bindable var store: DropDrawerStore
    @Environment(\.openURL) private var openURL

    @State private var serverUrl: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isRegisterMode: Bool = false
    @State private var googleBusy: Bool = false
    @State private var googleTask: Task<Void, Never>?
    @State private var authCoordinator = WebAuthCoordinator()

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
                        Text("跨端文件传输与云端同步")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }

                Section {
                    LabeledContent("服务器") {
                        TextField("https://your-server", text: $serverUrl)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("账号") {
                        TextField("输入用户名", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("密码") {
                        SecureField("至少 6 位", text: $password)
                            .multilineTextAlignment(.trailing)
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
                        Button {
                            Task {
                                await store.login(
                                    server: serverUrl,
                                    username: username,
                                    password: password,
                                    register: isRegisterMode
                                )
                            }
                        } label: {
                            Group {
                                if store.authLoading && !googleBusy {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text(isRegisterMode ? "创建账号并登录" : "继续")
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .disabled(store.authLoading || serverUrl.trimmingCharacters(in: .whitespaces).isEmpty || username.trimmingCharacters(in: .whitespaces).isEmpty || password.count < 6)

                        Button {
                            startGoogleFlow()
                        } label: {
                            HStack(spacing: 8) {
                                if googleBusy {
                                    ProgressView()
                                    Text("等待 Google 授权…")
                                } else {
                                    Image(systemName: "globe")
                                    Text("使用 Google 登录")
                                        .fontWeight(.medium)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .disabled(store.authLoading || serverUrl.trimmingCharacters(in: .whitespaces).isEmpty)

                        VStack(spacing: 10) {
                            Button(isRegisterMode ? "已有账号？返回登录" : "还没有账号？创建一个") {
                                withAnimation {
                                    isRegisterMode.toggle()
                                    store.authError = nil
                                }
                            }
                            .font(.subheadline)

                            if let privacy = URL(string: "\(serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression))/privacy") {
                                Button("隐私说明") {
                                    openURL(privacy)
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
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
            }
            .onDisappear {
                googleTask?.cancel()
            }
        }
    }

    private func startGoogleFlow() {
        googleTask?.cancel()
        googleBusy = true
        store.authError = nil
        googleTask = Task {
            defer { googleBusy = false }
            do {
                let start = try await store.startGoogleSignIn(server: serverUrl)
                authCoordinator.start(url: start.url)
                await store.completeGoogleSignIn(start: start)
            } catch {
                store.authError = error.localizedDescription
            }
        }
    }
}
