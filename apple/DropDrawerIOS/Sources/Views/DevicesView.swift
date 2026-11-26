import DropDrawerCore
import SwiftUI

struct DevicesView: View {
    @Bindable var store: DropDrawerStore

    private var grouped: (primary: [DeviceInfo], sameNameOffline: [DeviceInfo]) {
        func key(_ d: DeviceInfo) -> String {
            "\(d.platform.lowercased())::\(d.displayName.lowercased())"
        }
        let onlineKeys = Set(store.devices.filter(\.online).map(key))
        var primary: [DeviceInfo] = []
        var redundant: [DeviceInfo] = []
        for device in store.devices {
            if !device.online && device.id != store.deviceId && onlineKeys.contains(key(device)) {
                redundant.append(device)
            } else {
                primary.append(device)
            }
        }
        return (primary, redundant)
    }

    var body: some View {
        let split = grouped
        List {
            Section {
                LabeledContent("节点状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(store.p2pReady ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(store.p2pReady ? "运行中" : "未加载")
                            .foregroundStyle(.secondary)
                    }
                }
                if let nodeId = store.localNodeInfo?.nodeId {
                    Button {
                        UIPasteboard.general.string = nodeId
                        store.showToast("已复制 Node ID")
                    } label: {
                        LabeledContent("Node ID") {
                            HStack(spacing: 6) {
                                Text(abbreviate(nodeId))
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                                Image(systemName: "doc.on.doc")
                                    .font(.footnote)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("本机 P2P 节点")
            } footer: {
                Text(store.p2pReady
                     ? "iroh QUIC 节点运行中：局域网与公网直连优先，必要时经加密中继。"
                     : "P2P 引擎未加载，传输将自动回落到服务器与云盘。")
            }

            Section("同账号设备") {
                if split.primary.isEmpty {
                    Text("暂无设备记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(split.primary) { device in
                        deviceRow(device)
                    }
                }
            }

            if !split.sameNameOffline.isEmpty {
                Section {
                    ForEach(split.sameNameOffline) { device in
                        deviceRow(device)
                    }
                } header: {
                    Text("同名离线设备（\(split.sameNameOffline.count)）")
                } footer: {
                    Text("同一台设备重装或重新登录后留下的旧记录。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设备与 P2P")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refreshAll()
        }
    }

    private func deviceRow(_ device: DeviceInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: device.platform))
                .font(.title3)
                .foregroundStyle(device.online ? Color.primary : Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(device.displayName)\(device.id == store.deviceId ? "（本机）" : "")")
                    .lineLimit(1)
                Text(device.platform)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Text(device.online ? "在线" : "离线")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(device.online ? Color.green : Color(.tertiaryLabel))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private func symbol(for platform: String) -> String {
        let p = platform.lowercased()
        if p.contains("ios") || p.contains("iphone") { return "iphone" }
        if p.contains("ipad") { return "ipad" }
        if p.contains("android") { return "smartphone" }
        if p.contains("win") { return "desktopcomputer" }
        return "laptopcomputer"
    }

    private func abbreviate(_ id: String) -> String {
        guard id.count > 18 else { return id }
        return "\(id.prefix(8))…\(id.suffix(6))"
    }
}
