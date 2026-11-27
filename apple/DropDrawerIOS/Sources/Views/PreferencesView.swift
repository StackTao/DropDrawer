import DropDrawerCore
import SwiftUI
import UIKit

struct PreferencesView: View {
    @Bindable var store: DropDrawerStore
    @Environment(\.openURL) private var openURL
    @State private var confirmLogout: Bool = false
    @State private var confirmClearCache: Bool = false
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
