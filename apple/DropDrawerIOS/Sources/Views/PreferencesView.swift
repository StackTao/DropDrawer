import DropDrawerCore
import SwiftUI

struct PreferencesView: View {
    @Bindable var store: DropDrawerStore
    @Environment(\.openURL) private var openURL
    @State private var confirmLogout: Bool = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.1"
    }

    private var cleanServerHost: String {
        URL(string: store.serverUrl)?.host ?? store.serverUrl
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
                        Text(store.user?.username ?? "已登录")
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
                        Text(store.wsConnected ? "已连接" : "离线")
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
                        Text("\(store.onlineDeviceCount) 台在线")
                    } label: {
                        Label {
                            Text("设备与 P2P")
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
                            Text("云盘与存储")
                        } icon: {
                            SettingsIconBadge(systemImage: "cloud.fill", color: .cyan)
                        }
                    }
                }
            } header: {
                Text("连接与存储")
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
                        Text("传输策略")
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
                        Text("智能上云阈值")
                    } icon: {
                        SettingsIconBadge(systemImage: "gauge.medium", color: .teal)
                    }
                }

                Picker(selection: Binding(
                    get: { store.defaultTtlHours },
                    set: { store.setDefaultTtlHours($0) }
                )) {
                    Text("永不过期").tag(0)
                    Text("24 小时").tag(24)
                    Text("7 天").tag(168)
                    Text("30 天").tag(720)
                } label: {
                    Label {
                        Text("自动清理")
                    } icon: {
                        SettingsIconBadge(systemImage: "clock.arrow.circlepath", color: .orange)
                    }
                }
            } header: {
                Text("传输与清理")
            } footer: {
                Text("智能模式下小文件同步存云盘、大文件直连 P2P；到期后自动清理云端缓存与列表记录。")
            }

            Section("下载与关于") {
                LabeledContent("保存位置", value: "「文件」App › DropDrawer")
                LabeledContent("版本", value: appVersion)
                if let url = URL(string: "https://github.com/StackTao/DropDrawer/releases") {
                    Button("查看发布页") {
                        openURL(url)
                    }
                }
            }

            Section {
                Button("退出登录", role: .destructive) {
                    confirmLogout = true
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("退出当前账号？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                store.logout()
            }
            Button("取消", role: .cancel) {}
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
