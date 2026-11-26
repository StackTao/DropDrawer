import DropDrawerCore
import SwiftUI

public struct MacDevicesView: View {
    @Bindable var store: DropDrawerStore
    @Bindable var controller: EdgeDrawerController

    @State private var showOfflineDuplicates = false

    private var groupedDevices: (primary: [DeviceInfo], sameNameOffline: [DeviceInfo]) {
        func key(_ d: DeviceInfo) -> String {
            "\(d.platform.lowercased())::\(d.displayName.lowercased())"
        }
        let onlineKeys = Set(store.devices.filter(\.online).map(key))
        var primary: [DeviceInfo] = []
        var offlineDups: [DeviceInfo] = []
        for dev in store.devices {
            if !dev.online && dev.id != store.deviceId && onlineKeys.contains(key(dev)) {
                offlineDups.append(dev)
            } else {
                primary.append(dev)
            }
        }
        return (primary, offlineDups)
    }

    public var body: some View {
        VStack(spacing: 0) {
            MacSubpageHeader(
                title: "已登录设备与 P2P 节点",
                controller: controller,
                trailing: AnyView(
                    MacIconButton(symbol: "arrow.clockwise", size: 12.5, help: "刷新设备列表") {
                        Task { await store.refreshAll() }
                    }
                )
            )
            MacDivider()

            ScrollView {
                let groups = groupedDevices
                VStack(alignment: .leading, spacing: 14) {
                    localNodeCard

                    if !store.outgoingTransfers.isEmpty {
                        outgoingSection
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("同账号设备")
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacTheme.textSecondary)
                        deviceRows(groups.primary)
                    }

                    if !groups.sameNameOffline.isEmpty {
                        DisclosureGroup(isExpanded: $showOfflineDuplicates) {
                            deviceRows(groups.sameNameOffline)
                                .padding(.top, 6)
                        } label: {
                            Text("同名离线设备（\(groups.sameNameOffline.count)）")
                                .font(.system(size: 11.5))
                                .foregroundStyle(MacTheme.textSecondary)
                        }
                    }
                }
                .padding(14)
            }
        }
        .task {
            await store.refreshAll()
        }
    }

    private var localNodeCard: some View {
        MacGroupedCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(store.p2pReady ? MacTheme.green : MacTheme.amber)
                        .frame(width: 7, height: 7)
                    Text(store.p2pReady ? "本机 iroh QUIC P2P 节点运行中" : "P2P 引擎未加载")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MacTheme.textPrimary)
                    Spacer()
                    if let info = store.localNodeInfo {
                        Button("复制 ID") {
                            MacPlatformServices.copyText(info.nodeId)
                            store.showToast("已复制 Node ID")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(MacTheme.textSecondary)
                    }
                }

                if let info = store.localNodeInfo {
                    Text("Node ID: \(info.nodeId)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(MacTheme.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
        }
    }

    private var outgoingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("正在向外发送")
                .font(.system(size: 11.5))
                .foregroundStyle(MacTheme.textSecondary)

            MacGroupedCard {
                ForEach(Array(store.outgoingTransfers.keys.sorted().enumerated()), id: \.element) { idx, tid in
                    if let prog = store.outgoingTransfers[tid] {
                        if idx > 0 { MacDivider(indent: 12) }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(store.items.first(where: { $0.id == prog.itemId })?.name ?? prog.itemId)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(MacTheme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Button("取消") {
                                    store.cancelOutgoingTransfer(transferId: tid)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(MacTheme.red)
                            }
                            ProgressView(value: prog.fraction)
                                .progressViewStyle(.linear)
                                .tint(MacTheme.accent)
                            HStack {
                                Text(prog.channelLabel)
                                Spacer()
                                if prog.speedBps > 0 {
                                    Text(MacPlatformServices.formatSpeed(prog.speedBps))
                                }
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(MacTheme.textTertiary)
                        }
                        .padding(11)
                    }
                }
            }
        }
    }

    private func deviceRows(_ list: [DeviceInfo]) -> some View {
        MacGroupedCard {
            ForEach(Array(list.enumerated()), id: \.element.id) { idx, dev in
                if idx > 0 { MacDivider(indent: 12) }
                HStack(spacing: 10) {
                    Circle()
                        .fill(dev.online ? MacTheme.green : MacTheme.textTertiary)
                        .frame(width: 7, height: 7)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(dev.displayName)\(dev.id == store.deviceId ? " (本机)" : "")")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(MacTheme.textPrimary)
                            .lineLimit(1)
                        Text("\(dev.platform) · \(dev.online ? "在线" : "离线")")
                            .font(.system(size: 10.5))
                            .foregroundStyle(MacTheme.textTertiary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }
}
