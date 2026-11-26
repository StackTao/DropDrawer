import AppKit
import Carbon.HIToolbox
import DropDrawerCore
import SwiftUI

/// macOS System-Settings style in-drawer Preferences view matching the
/// exact structure, descriptions, hotkey presets, and About/Update card.
public struct MacPreferencesView: View {
    @Bindable var store: DropDrawerStore
    @Bindable var controller: EdgeDrawerController

    @State private var hotkeyHint: String?

    private static let hotkeyPresets: [(label: String, keyCode: UInt32, modifiers: UInt32)] = [
        ("⌥⇧D", UInt32(kVK_ANSI_D), UInt32(optionKey | shiftKey)),
        ("⌃⌥D", UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey)),
        ("⌃⇧D", UInt32(kVK_ANSI_D), UInt32(controlKey | shiftKey)),
        ("⌘⇧X", UInt32(kVK_ANSI_X), UInt32(cmdKey | shiftKey)),
    ]

    public var body: some View {
        VStack(spacing: 0) {
            MacSubpageHeader(title: "偏好设置", controller: controller)
            MacDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    transferAndCleanupSection
                    windowAndMacIntegrationSection
                    aboutAndUpdateSection
                }
                .padding(14)
            }
        }
        .onAppear {
            controller.refreshGlobalHotkeyPermissions()
        }
        .onDisappear {
            if controller.isRecordingHotkey {
                controller.stopHotkeyRecording()
            }
        }
    }

    // MARK: - 1. 传输与自动清理

    private var transferAndCleanupSection: some View {
        section("传输与自动清理") {
            VStack(alignment: .leading, spacing: 0) {
                // 新文件传输策略
                VStack(alignment: .leading, spacing: 2) {
                    Text("新文件传输策略")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MacTheme.textPrimary)
                    Text("智能：小文件同时存云盘、大文件只走 P2P；纯 P2P：不经过服务器；强制存云盘：来源离线也能下载")
                        .font(.system(size: 10.5))
                        .foregroundStyle(MacTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    MacSegmentedControl(
                        items: [
                            (DropPolicy.smart, "智能"),
                            (DropPolicy.p2pOnly, "纯 P2P"),
                            (DropPolicy.cloudCached, "存云盘"),
                        ],
                        selected: store.dropPolicy
                    ) { store.setDropPolicy($0) }
                    .padding(.top, 6)
                }
                .padding(12)

                MacDivider(indent: 12)

                // 默认过期自动清理
                VStack(alignment: .leading, spacing: 2) {
                    Text("默认过期自动清理")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MacTheme.textPrimary)
                    Text("新拖入的文件/文本到期后自动清理云端缓存与抽屉记录")
                        .font(.system(size: 10.5))
                        .foregroundStyle(MacTheme.textTertiary)
                    MacSegmentedControl(
                        items: [(0, "永不过期"), (24, "24 小时"), (168, "7 天"), (720, "30 天")],
                        selected: store.defaultTtlHours
                    ) { store.setDefaultTtlHours($0) }
                    .padding(.top, 6)
                }
                .padding(12)

                MacDivider(indent: 12)

                // 智能模式自动上云阈值
                VStack(alignment: .leading, spacing: 2) {
                    Text("智能模式自动上云阈值")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MacTheme.textPrimary)
                    Text("小于该体积自动缓存至云盘，超过则纯 P2P 端到端直连")
                        .font(.system(size: 10.5))
                        .foregroundStyle(MacTheme.textTertiary)
                    MacSegmentedControl(
                        items: [(10, "10 MB"), (20, "20 MB"), (50, "50 MB"), (100, "100 MB")],
                        selected: [10, 20, 50, 100].contains(store.autoCloudThresholdMb) ? store.autoCloudThresholdMb : 20
                    ) { store.setAutoCloudThresholdMb($0) }
                    .padding(.top, 6)
                }
                .padding(12)

                MacDivider(indent: 12)

                // 默认下载目录
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("默认下载目录")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MacTheme.textPrimary)
                        Spacer()
                        if store.customDownloadDir != nil {
                            Button("恢复默认") {
                                store.setCustomDownloadDir(nil)
                                store.showToast("已恢复默认下载目录")
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(MacTheme.accent)
                        }
                    }

                    Text(store.downloadsDirectory().path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(MacTheme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        MacSecondaryButton(title: "更改目录", height: 28) {
                            Task {
                                if let path = await MacPlatformServices.pickDirectory(modalGuard: { controller.isModalOpen = $0 }) {
                                    store.setCustomDownloadDir(path)
                                    store.showToast("已更新下载目录")
                                }
                                if controller.isEdgeMode && controller.mode == .expanded {
                                    controller.window.orderFrontRegardless()
                                }
                            }
                        }
                        MacSecondaryButton(title: "打开", height: 28) {
                            MacPlatformServices.openFile(store.downloadsDirectory())
                        }
                        .frame(width: 64)
                    }
                    .padding(.top, 3)
                }
                .padding(12)
            }
        }
    }

    // MARK: - 2. 窗口与 macOS 集成

    private var windowAndMacIntegrationSection: some View {
        section("窗口与 macOS 集成") {
            VStack(alignment: .leading, spacing: 0) {
                // 边缘抽屉停靠侧
                VStack(alignment: .leading, spacing: 2) {
                    Text("边缘抽屉停靠侧")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MacTheme.textPrimary)
                    Text("也可直接按住边缘悬浮手柄上下或跨屏拖动调整")
                        .font(.system(size: 10.5))
                        .foregroundStyle(MacTheme.textTertiary)
                    MacSegmentedControl(
                        items: [(MacDockSide.left, "屏幕左侧"), (MacDockSide.right, "屏幕右侧")],
                        selected: controller.dockSide
                    ) { controller.setDockSide($0) }
                    .padding(.top, 6)
                }
                .padding(12)

                MacDivider(indent: 12)

                // 全局快捷键呼出抽屉
                switchRow(
                    title: "全局快捷键呼出抽屉",
                    subtitle: "任意应用下快速展开或收起抽屉，可自定义避免冲突",
                    isOn: Binding(
                        get: { controller.isHotkeyEnabled },
                        set: { enabled in
                            if controller.isRecordingHotkey {
                                controller.stopHotkeyRecording()
                            }
                            controller.setHotkeyEnabled(enabled)
                        }
                    )
                )

                if controller.isHotkeyEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("当前快捷键")
                                .font(.system(size: 11))
                                .foregroundStyle(MacTheme.textSecondary)
                            Spacer()
                            Button {
                                if controller.isRecordingHotkey {
                                    controller.stopHotkeyRecording()
                                    hotkeyHint = nil
                                } else {
                                    hotkeyHint = "请直接按下组合键（需含 ⌘ / ⌥ / ⌃ 或 F1-F12，Esc 取消）"
                                    controller.startHotkeyRecording()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: controller.isRecordingHotkey ? "keyboard" : "command")
                                        .font(.system(size: 11))
                                        .foregroundStyle(controller.isRecordingHotkey ? MacTheme.accent : MacTheme.textSecondary)
                                    Text(controller.isRecordingHotkey ? "按下组合键..." : controller.hotkeyLabel)
                                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(controller.isRecordingHotkey ? MacTheme.accent : MacTheme.textPrimary)
                                    if !controller.isRecordingHotkey {
                                        Text("点击修改")
                                            .font(.system(size: 10))
                                            .foregroundStyle(MacTheme.textTertiary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(controller.isRecordingHotkey ? MacTheme.accent.opacity(0.22) : MacTheme.fill(0.09))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(
                                            controller.isRecordingHotkey ? MacTheme.accent : MacTheme.strongHairline,
                                            lineWidth: controller.isRecordingHotkey ? 1.0 : 0.7
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        if let hint = hotkeyHint {
                            Text(hint)
                                .font(.system(size: 10.5))
                                .foregroundStyle(controller.isRecordingHotkey ? MacTheme.accent : MacTheme.textSecondary)
                        }

                        // Preset chips
                        HStack(spacing: 6) {
                            ForEach(Self.hotkeyPresets, id: \.label) { preset in
                                let active = controller.hotkeyLabel == preset.label
                                Button {
                                    controller.setHotkeyPreset(keyCode: preset.keyCode, modifiers: preset.modifiers)
                                    hotkeyHint = "已生效：\(preset.label)"
                                    store.showToast("全局呼出快捷键已设为 \(preset.label)")
                                } label: {
                                    Text(preset.label)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(active ? MacTheme.textPrimary : MacTheme.textSecondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(active ? MacTheme.fill(0.16) : MacTheme.fill(0.05))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(active ? MacTheme.strongHairline : MacTheme.hairline, lineWidth: 0.6)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Permission status card
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(controller.hasGlobalHotkeyPermission ? MacTheme.green : MacTheme.amber)
                                    .frame(width: 6, height: 6)
                                Text(controller.hasGlobalHotkeyPermission
                                     ? "全局监听已就绪 · 任意应用按 \(controller.hotkeyLabel) 即可呼出"
                                     : "需要开启 macOS「辅助功能」权限才能在其他应用下响应全局快捷键")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(MacTheme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if !controller.hasGlobalHotkeyPermission {
                                HStack(spacing: 6) {
                                    Button {
                                        controller.requestAccessibilityPermission()
                                    } label: {
                                        Text("前往开启辅助功能")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(MacTheme.onTextPrimary)
                                            .padding(.horizontal, 10)
                                            .frame(height: 25)
                                            .background(MacTheme.textPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        controller.refreshGlobalHotkeyPermissions()
                                        if controller.hasGlobalHotkeyPermission {
                                            store.showToast("已检测到权限，全局快捷键立即生效")
                                        } else {
                                            store.showToast("尚未检测到权限，请在系统设置中勾选 DropDrawer")
                                        }
                                    } label: {
                                        Text("重新检测")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(MacTheme.textSecondary)
                                            .padding(.horizontal, 9)
                                            .frame(height: 25)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                    .strokeBorder(MacTheme.hairline, lineWidth: 0.7)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(controller.hasGlobalHotkeyPermission
                                      ? MacTheme.green.opacity(0.10)
                                      : MacTheme.amber.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    controller.hasGlobalHotkeyPermission
                                        ? MacTheme.green.opacity(0.30)
                                        : MacTheme.amber.opacity(0.35),
                                    lineWidth: 0.6
                                )
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }

                MacDivider(indent: 12)

                // 在程序坞 (Dock) 显示图标
                switchRow(
                    title: "在程序坞 (Dock) 显示图标",
                    subtitle: "关闭时仅常驻顶部菜单栏，开启后同时在 Dock 显示",
                    isOn: Binding(
                        get: { controller.showDockIcon },
                        set: { controller.setShowDockIcon($0) }
                    )
                )

                MacDivider(indent: 12)

                // 开机自动启动
                switchRow(
                    title: "开机自动启动",
                    subtitle: "登录 macOS 时自动静默驻留状态栏与屏幕边缘",
                    isOn: Binding(
                        get: { controller.launchAtLogin },
                        set: { enabled in
                            controller.setLaunchAtLogin(enabled)
                            store.showToast(enabled ? "已开启开机自启动" : "已关闭开机自启动")
                        }
                    )
                )
            }
        }
    }

    // MARK: - 3. 关于与更新 (mirrors UpdateSettings 1:1)

    private var aboutAndUpdateSection: some View {
        let updater = controller.updater
        return section("关于与更新") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(updater.installedVersion.map { "DropDrawer \($0)" } ?? "DropDrawer")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MacTheme.textPrimary)
                    Spacer()
                    if updater.canUpdate {
                        Text("自动检查")
                            .font(.system(size: 10.5))
                            .foregroundStyle(MacTheme.textSecondary)
                        Toggle("", isOn: Binding(
                            get: { updater.autoCheck },
                            set: { updater.setAutoCheck($0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(MacTheme.green)
                        .labelsHidden()
                    }
                }

                Text(updater.statusDescription)
                    .font(.system(size: 10.5))
                    .foregroundStyle(MacTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if updater.phase == .checking || updater.phase == .downloading {
                    ProgressView(value: updater.phase == .downloading ? (updater.progress ?? 0) : nil)
                        .progressViewStyle(.linear)
                        .tint(MacTheme.accent)
                        .controlSize(.mini)
                        .padding(.top, 4)
                }

                MacFlowLayout(spacing: 8, runSpacing: 6) {
                    if updater.canUpdate {
                        Button("检查更新") {
                            Task { await updater.check() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(MacTheme.strongHairline, lineWidth: 0.7)
                        )
                        .disabled(updater.busy)
                    }

                    if let target = updater.update, updater.manualPackageURL == nil {
                        let mb = String(format: "%.1f", Double(target.size) / 1_048_576.0)
                        Button("更新到 \(target.version)（\(mb) MB）并重启") {
                            Task { await updater.installUpdate() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(MacTheme.onTextPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(MacTheme.textPrimary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .disabled(updater.busy)
                    }

                    if updater.manualPackageURL != nil {
                        Button("打开安装包") {
                            updater.openManualPackage()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(MacTheme.onTextPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(MacTheme.textPrimary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }

                    Button(updater.update == nil ? "发布页" : "更新说明") {
                        updater.openReleasePage()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacTheme.accent)
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                }
                .padding(.top, 6)
            }
            .padding(12)
        }
    }

    // MARK: - Group Helpers

    private func section<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(MacTheme.textSecondary)
            MacGroupedCard {
                content()
            }
        }
    }

    private func switchRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MacTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(MacTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(MacTheme.green)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
