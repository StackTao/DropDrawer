import AppKit
import Carbon.HIToolbox
import DropDrawerCore
import Observation
import QuartzCore
import SwiftUI

public enum MacDrawerMode: String, Sendable {
    case collapsed
    case dragPill = "drag_pill"
    case expanded
}

public enum MacDockSide: String, Sendable, CaseIterable {
    case right
    case left

    public var title: String {
        switch self {
        case .right: return "屏幕右侧"
        case .left: return "屏幕左侧"
        }
    }
}

public enum MacAppearanceMode: String, Sendable, CaseIterable {
    case system
    case dark
    case light

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
}

public enum MacRoute: Equatable {
    case home
    case detail(String)
    case shares([String])
    case storage
    case devices
    case preferences
}

// MARK: - Borderless / Adaptive Floating Panel

public final class DrawerPanel: NSPanel {
    weak var controller: EdgeDrawerController?

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public override func sendEvent(_ event: NSEvent) {
        if let ctrl = controller {
            if event.type == .leftMouseDown && ctrl.isEdgeMode && ctrl.mode == .collapsed && !ctrl.isAnimating {
                ctrl.handleCollapsedHandleMouseDown()
                return
            }
            if event.type == .leftMouseDown && ctrl.isEdgeMode && ctrl.mode == .expanded {
                if !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)
                }
                if !self.isKeyWindow {
                    self.makeKey()
                }
            }
        }
        super.sendEvent(event)
    }
}

// MARK: - Native macOS Edge Drawer & Window Controller

@Observable
@MainActor
public final class EdgeDrawerController: NSObject, NSWindowDelegate {
    // MARK: Persisted keys
    private enum PrefKey {
        static let edgeMode = "dd.mac.edgeMode"
        static let dockSide = "dd.mac.dockSide"
        static let dockYRatio = "dd.mac.dockYRatio"
        static let hotkeyEnabled = "dd.mac.hotkeyEnabled"
        static let hotkeyKeyCode = "dd.mac.hotkeyKeyCode"
        static let hotkeyModifiers = "dd.mac.hotkeyModifiers"
        static let showDockIcon = "dd.mac.showDockIcon"
        static let appearance = "dd.mac.appearance"
    }

    // MARK: Dimensions (1:1 with DropDrawer macOS)
    private let collapsedSize = NSSize(width: 10, height: 88)
    private let dragPillSize = NSSize(width: 246, height: 46)
    private let expandedSize = NSSize(width: 368, height: 560)
    private let regularSize = NSSize(width: 400, height: 600)
    private let edgeMargin: CGFloat = 10

    // MARK: Observable UI State
    public var isEdgeMode: Bool = true
    public var mode: MacDrawerMode = .collapsed
    public var dockSide: MacDockSide = .right
    public var isPinned: Bool = false
    public var appearance: MacAppearanceMode = .dark
    public var showDockIcon: Bool = false
    public var launchAtLogin: Bool = false

    public var isHotkeyEnabled: Bool = true
    public var hotkeyLabel: String = "⌥⇧D"
    public var hotkeyEngine: String = "local_only"
    public var hasGlobalHotkeyPermission: Bool = false
    public var isRecordingHotkey: Bool = false

    public var route: MacRoute = .home
    public var isModalOpen: Bool = false
    public let updater = MacUpdateController()

    // MARK: Internal Window & Monitors
    public private(set) var window: DrawerPanel!
    private var effectView: NSVisualEffectView!
    private let store: DropDrawerStore

    private var dockYRatio: CGFloat = 0.5
    var isAnimating: Bool = false
    private var handleTrackingDown: Bool = false
    private var openedByDrag: Bool = false
    private var dragSessionActive: Bool = false
    private var lastDragChangeCount: Int = -1
    private var lastHotkeyTriggerAt: TimeInterval = 0
    private var previousApp: NSRunningApplication?

    private var hotkeyKeyCode: UInt32 = UInt32(kVK_ANSI_D)
    private var hotkeyModifiers: UInt32 = UInt32(optionKey | shiftKey)

    private var dragMonitorTimer: Timer?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalHotkeyMonitor: Any?
    private var hotkeyRecordMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var workspaceObserver: Any?
    private var appActiveObserver: Any?

    // Drag tracking state for expanded header
    private var headerDragOffset: NSPoint?

    static weak var shared: EdgeDrawerController?

    public init(store: DropDrawerStore) {
        self.store = store
        super.init()
        EdgeDrawerController.shared = self
        loadPreferences()
        setupWindow()
        installObservers()
        installLocalKeyMonitor()
        installGlobalHotkeyEngine()
        startDragMonitor()
        updater.checkIfDue()
    }

    private func loadPreferences() {
        let ud = UserDefaults.standard
        if ud.object(forKey: PrefKey.edgeMode) != nil {
            isEdgeMode = ud.bool(forKey: PrefKey.edgeMode)
        } else {
            isEdgeMode = true
        }
        if let rawSide = ud.string(forKey: PrefKey.dockSide),
           let side = MacDockSide(rawValue: rawSide) {
            dockSide = side
        }
        if ud.object(forKey: PrefKey.dockYRatio) != nil {
            dockYRatio = min(max(CGFloat(ud.double(forKey: PrefKey.dockYRatio)), 0.12), 0.88)
        }
        if ud.object(forKey: PrefKey.hotkeyEnabled) != nil {
            isHotkeyEnabled = ud.bool(forKey: PrefKey.hotkeyEnabled)
        }
        if ud.object(forKey: PrefKey.hotkeyKeyCode) != nil {
            hotkeyKeyCode = UInt32(ud.integer(forKey: PrefKey.hotkeyKeyCode))
        }
        if ud.object(forKey: PrefKey.hotkeyModifiers) != nil {
            hotkeyModifiers = UInt32(ud.integer(forKey: PrefKey.hotkeyModifiers))
        }
        showDockIcon = ud.bool(forKey: PrefKey.showDockIcon)
        if let rawApp = ud.string(forKey: PrefKey.appearance),
           let app = MacAppearanceMode(rawValue: rawApp) {
            appearance = app
        }
        launchAtLogin = MacPlatformServices.isLaunchAtLoginEnabled
        hotkeyLabel = formatHotkeyDisplay(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
        refreshPermissionFlags()
    }

    private func setupWindow() {
        let panel = DrawerPanel(
            contentRect: NSRect(origin: .zero, size: expandedSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.controller = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let container = NSView(frame: NSRect(origin: .zero, size: expandedSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        let vfx = NSVisualEffectView(frame: container.bounds)
        vfx.autoresizingMask = [.width, .height]
        vfx.appearance = NSAppearance(named: .darkAqua)
        vfx.material = .hudWindow
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        vfx.layer?.masksToBounds = true
        vfx.layer?.cornerCurve = .continuous
        vfx.layer?.cornerRadius = 16
        container.addSubview(vfx)
        self.effectView = vfx

        let rootView = MacRootView(store: store, controller: self)
        let hosting = NSHostingView(rootView: rootView)
        hosting.safeAreaRegions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        panel.contentView = container
        self.window = panel

        applyAppearance(appearance, persist: false)
        applyEdgeDrawerMode(enabled: isEdgeMode, persist: false, expandImmediately: true)
    }

    // MARK: - Window Mode & Appearance

    private func updateBackdropCornerRadius(_ radius: CGFloat, tintAlpha: CGFloat = 0.44) {
        effectView.layer?.cornerRadius = radius
    }

    public func applyAppearance(_ mode: MacAppearanceMode, persist: Bool = true) {
        appearance = .dark
        let dark = NSAppearance(named: .darkAqua)
        window.appearance = dark
        effectView.appearance = dark
        effectView.material = .hudWindow
        effectView.state = .active
    }

    public func setShowDockIcon(_ shown: Bool) {
        showDockIcon = shown
        UserDefaults.standard.set(shown, forKey: PrefKey.showDockIcon)
        NSApp.setActivationPolicy(shown ? .regular : .accessory)
        if shown {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        if MacPlatformServices.setLaunchAtLogin(enabled) {
            launchAtLogin = MacPlatformServices.isLaunchAtLoginEnabled
        }
    }

    public func applyEdgeDrawerMode(enabled: Bool, persist: Bool = true, expandImmediately: Bool = false) {
        isEdgeMode = enabled
        if persist {
            UserDefaults.standard.set(enabled, forKey: PrefKey.edgeMode)
        }
        isAnimating = false
        openedByDrag = false

        if enabled {
            window.styleMask = [.borderless, .nonactivatingPanel, .fullSizeContentView]
            window.isMovable = false
            window.isMovableByWindowBackground = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            if expandImmediately {
                mode = .expanded
                updateBackdropCornerRadius(cornerRadius(for: .expanded), tintAlpha: 0.44)
                window.hasShadow = true
                let frame = frameFor(.expanded, on: activeScreen().visibleFrame)
                window.setFrame(frame, display: true, animate: false)
                window.invalidateShadow()
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else {
                mode = .collapsed
                updateBackdropCornerRadius(cornerRadius(for: .collapsed), tintAlpha: 0.34)
                window.hasShadow = false
                let frame = frameFor(.collapsed, on: activeScreen().visibleFrame)
                window.setFrame(frame, display: true, animate: false)
                window.invalidateShadow()
                window.orderFrontRegardless()
            }
        } else {
            mode = .expanded
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.title = "DropDrawer"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovable = true
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .normal
            window.collectionBehavior = [.managed, .moveToActiveSpace]
            window.hasShadow = true
            window.minSize = NSSize(width: 360, height: 480)
            updateBackdropCornerRadius(0, tintAlpha: 0.46)

            let screen = activeScreen().visibleFrame
            let target = NSRect(
                x: screen.midX - regularSize.width / 2,
                y: screen.midY - regularSize.height / 2,
                width: regularSize.width,
                height: regularSize.height
            )
            window.setFrame(target, display: true, animate: true)
            window.invalidateShadow()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    public func toggleWindowMode() {
        applyEdgeDrawerMode(enabled: !isEdgeMode, persist: true, expandImmediately: true)
    }

    public func setDockSide(_ side: MacDockSide) {
        guard dockSide != side else { return }
        dockSide = side
        UserDefaults.standard.set(side.rawValue, forKey: PrefKey.dockSide)
        if isEdgeMode {
            let screen = activeScreen().visibleFrame
            let target = frameFor(mode, on: screen)
            window.setFrame(target, display: true, animate: true)
        }
    }

    public func toggleDockSide() {
        setDockSide(dockSide == .left ? .right : .left)
    }

    public func togglePinned() {
        isPinned.toggle()
    }

    // MARK: - Show / Expand / Collapse

    public func toggleDrawer() {
        if !isEdgeMode {
            if window.isVisible && window.isKeyWindow {
                window.orderOut(nil)
                restorePreviousAppFocus()
            } else {
                capturePreviousAppIfNeeded()
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
        if mode == .expanded {
            collapse(animated: true, restoreFocus: true)
        } else {
            expand(animated: true, activateFocus: true)
        }
    }

    public func expand(animated: Bool = true, activateFocus: Bool = true) {
        if !isEdgeMode {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        transition(to: .expanded, animated: animated, activateFocus: activateFocus)
    }

    public func collapse(animated: Bool = true, restoreFocus: Bool = false) {
        guard isEdgeMode else { return }
        transition(to: .collapsed, animated: animated, restoreFocus: restoreFocus)
    }

    public func openPreferences() {
        route = .preferences
        expand(animated: true, activateFocus: true)
    }

    // MARK: - Native Dark Frosted More Menu (`···`)

    private final class MoreMenuCollector: NSObject {
        var selected: String?
        @objc func onSelect(_ sender: NSMenuItem) {
            selected = sender.representedObject as? String
        }
    }

    /// Presents a genuine native macOS darkAqua frosted `NSMenu` aligned beneath the `···` button.
    /// Avoids SwiftUI `Menu` auto-dismissal issues inside `.nonactivatingPanel` borderless panels.
    public func presentMoreMenu() {
        guard let view = window.contentView else { return }
        isModalOpen = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.isModalOpen = false }

            let collector = MoreMenuCollector()
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.appearance = NSAppearance(named: .darkAqua)

            func addItem(_ title: String, symbol: String, id: String, keyEq: String = "") {
                let item = NSMenuItem(
                    title: title,
                    action: #selector(MoreMenuCollector.onSelect(_:)),
                    keyEquivalent: keyEq
                )
                item.target = collector
                item.representedObject = id
                item.isEnabled = true
                let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg) {
                    img.isTemplate = true
                    item.image = img
                }
                menu.addItem(item)
            }

            addItem("外链管理", symbol: "link", id: "shares")
            addItem("偏好设置", symbol: "gearshape", id: "preferences")
            addItem("设备状态", symbol: "laptopcomputer.and.iphone", id: "devices")
            if self.isEdgeMode {
                addItem(
                    self.dockSide == .left ? "停靠右侧" : "停靠左侧",
                    symbol: self.dockSide == .left ? "sidebar.right" : "sidebar.left",
                    id: "toggle_dock_side"
                )
            }
            menu.addItem(.separator())
            addItem("退出登录", symbol: "rectangle.portrait.and.arrow.right", id: "logout")
            addItem("退出应用", symbol: "power", id: "quit", keyEq: "q")

            let menuWidth = max(menu.size.width, 140)
            let anchorRightX = view.bounds.width - 10
            let anchorTopOffset: CGFloat = self.isEdgeMode ? 42 : 38
            let x = min(max(8, anchorRightX - menuWidth), max(8, view.bounds.width - menuWidth - 8))
            let y = max(8, view.bounds.height - anchorTopOffset)
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: view)

            switch collector.selected {
            case "shares":
                self.route = .shares([])
            case "preferences":
                self.route = .preferences
            case "devices":
                self.route = .devices
            case "toggle_dock_side":
                self.toggleDockSide()
                self.store.showToast(self.dockSide == .left ? "已停靠到屏幕左侧" : "已停靠到屏幕右侧")
            case "logout":
                self.store.logout()
                self.route = .home
            case "quit":
                NSApp.terminate(nil)
            default:
                break
            }
        }
    }

    // MARK: - Geometry & Transitions

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return hit
        }
        return window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func cornerRadius(for state: MacDrawerMode) -> CGFloat {
        switch state {
        case .collapsed: return 6
        case .dragPill: return 13
        case .expanded: return 16
        }
    }

    private func frameFor(_ target: MacDrawerMode, on screen: NSRect) -> NSRect {
        let anchorY = screen.minY + (screen.height * dockYRatio)
        func clampedY(height: CGFloat, padding: CGFloat) -> CGFloat {
            let minY = screen.minY + padding
            let maxY = max(minY, screen.maxY - height - padding)
            return min(max(anchorY - height / 2, minY), maxY)
        }
        switch target {
        case .collapsed:
            let x = (dockSide == .left) ? screen.minX : (screen.maxX - collapsedSize.width)
            return NSRect(x: x, y: clampedY(height: collapsedSize.height, padding: 16), width: collapsedSize.width, height: collapsedSize.height)
        case .dragPill:
            let x = (dockSide == .left) ? (screen.minX + edgeMargin) : (screen.maxX - dragPillSize.width - edgeMargin)
            return NSRect(x: x, y: clampedY(height: dragPillSize.height, padding: 16), width: dragPillSize.width, height: dragPillSize.height)
        case .expanded:
            let x = (dockSide == .left) ? (screen.minX + edgeMargin) : (screen.maxX - expandedSize.width - edgeMargin)
            return NSRect(x: x, y: clampedY(height: expandedSize.height, padding: 12), width: expandedSize.width, height: expandedSize.height)
        }
    }

    private func edgeTransform(size: NSSize, scale: CGFloat, tx: CGFloat, anchorYRatio: CGFloat = 0.5) -> CATransform3D {
        let px: CGFloat = (dockSide == .left) ? 0 : size.width
        let py: CGFloat = size.height * min(max(anchorYRatio, 0.14), 0.86)
        let signedTx: CGFloat = (dockSide == .left) ? -tx : tx
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, px + signedTx, py, 0)
        t = CATransform3DScale(t, scale, scale, 1.0)
        t = CATransform3DTranslate(t, -px, -py, 0)
        return t
    }

    private static func springAnimation(from start: CATransform3D, mass: CGFloat, stiffness: CGFloat) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: start)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = mass
        spring.stiffness = stiffness
        spring.damping = 2.0 * sqrt(stiffness * mass)
        spring.duration = spring.settlingDuration
        return spring
    }

    private func transition(
        to target: MacDrawerMode,
        animated: Bool,
        activateFocus: Bool = false,
        restoreFocus: Bool = false
    ) {
        guard isEdgeMode, mode != target else { return }

        let previous = mode
        let screen = activeScreen().visibleFrame
        let targetFrame = frameFor(target, on: screen)

        if target == .expanded && activateFocus {
            capturePreviousAppIfNeeded()
        } else if previous == .expanded && target == .collapsed {
            openedByDrag = false
            if restoreFocus {
                restorePreviousAppFocus()
            } else if window.isKeyWindow {
                window.resignKey()
            }
        }

        // Because SwiftUI renders synchronously in-process, switching `mode` + resizing the panel
        // updates immediately on the very same display transaction without frame stretching.
        if target == .dragPill {
            window.contentView?.layer?.removeAllAnimations()
            mode = .dragPill
            updateBackdropCornerRadius(cornerRadius(for: .dragPill), tintAlpha: 0.36)
            window.hasShadow = true
            window.setFrame(targetFrame, display: true, animate: false)
            window.invalidateShadow()
            window.orderFrontRegardless()

            guard animated, let layer = window.contentView?.layer else {
                window.alphaValue = 1.0
                return
            }
            let startTx = edgeTransform(size: dragPillSize, scale: 0.92, tx: 10)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = startTx
            window.alphaValue = 0.0
            CATransaction.commit()

            let spring = Self.springAnimation(from: startTx, mass: 0.72, stiffness: 360)
            layer.transform = CATransform3DIdentity
            layer.add(spring, forKey: "dragPillBloom")
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                self.window.animator().alphaValue = 1.0
            }
            return
        }

        if target == .expanded {
            isAnimating = animated
            mode = .expanded
            updateBackdropCornerRadius(cornerRadius(for: .expanded), tintAlpha: 0.44)
            window.hasShadow = true
            window.setFrame(targetFrame, display: true, animate: false)
            window.invalidateShadow()
            if activateFocus {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }

            guard animated, let layer = window.contentView?.layer else {
                window.contentView?.layer?.transform = CATransform3DIdentity
                window.alphaValue = 1.0
                isAnimating = false
                return
            }

            let anchorY = (screen.minY + screen.height * dockYRatio - targetFrame.minY) / max(targetFrame.height, 1)
            let startScale: CGFloat = (previous == .dragPill) ? 0.95 : 0.92
            let startTx = edgeTransform(size: expandedSize, scale: startScale, tx: 8, anchorYRatio: anchorY)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAllAnimations()
            layer.transform = startTx
            window.alphaValue = 0.0
            CATransaction.commit()

            let spring = Self.springAnimation(from: startTx, mass: 0.82, stiffness: 330)
            layer.transform = CATransform3DIdentity
            layer.add(spring, forKey: "drawerExpand")
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.window.animator().alphaValue = 1.0
            }
            let unlock = min(max(spring.settlingDuration * 0.6, 0.18), 0.30)
            DispatchQueue.main.asyncAfter(deadline: .now() + unlock) { [weak self] in
                self?.isAnimating = false
            }
            return
        }

        // Collapse to edge handle
        if !animated {
            mode = .collapsed
            window.contentView?.layer?.transform = CATransform3DIdentity
            updateBackdropCornerRadius(cornerRadius(for: .collapsed), tintAlpha: 0.34)
            window.hasShadow = false
            window.setFrame(targetFrame, display: true, animate: false)
            window.invalidateShadow()
            window.alphaValue = 1.0
            return
        }

        isAnimating = true
        guard let layer = window.contentView?.layer else {
            mode = .collapsed
            updateBackdropCornerRadius(cornerRadius(for: .collapsed), tintAlpha: 0.34)
            window.hasShadow = false
            window.setFrame(targetFrame, display: true, animate: false)
            window.invalidateShadow()
            window.alphaValue = 1.0
            isAnimating = false
            return
        }

        let curFrame = window.frame
        let anchorY = (screen.minY + screen.height * dockYRatio - curFrame.minY) / max(curFrame.height, 1)
        let endTx = edgeTransform(size: curFrame.size, scale: 0.93, tx: 10, anchorYRatio: anchorY)
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: endTx)
        shrink.duration = 0.16
        shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
        layer.transform = endTx
        layer.add(shrink, forKey: "drawerCollapse")

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.window.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.window.contentView?.layer?.removeAllAnimations()
                self.window.contentView?.layer?.transform = CATransform3DIdentity
                CATransaction.commit()

                self.mode = .collapsed
                self.updateBackdropCornerRadius(self.cornerRadius(for: .collapsed), tintAlpha: 0.34)
                self.window.hasShadow = false
                self.window.setFrame(targetFrame, display: true, animate: false)
                self.window.invalidateShadow()

                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.10
                    self.window.animator().alphaValue = 1.0
                }, completionHandler: { [weak self] in
                    Task { @MainActor in
                        self?.isAnimating = false
                    }
                })
            }
        })
    }

    // MARK: - Interactive Edge Repositioning (Native 1-Click Collapsed Handle & Expanded Header)

    /// Native click-or-drag tracking directly from `DrawerPanel.sendEvent`:
    /// - Single click (<= 4pt movement) expands immediately even when app is in background.
    /// - Vertical drag moves along the screen edge; horizontal drag >= 32pt detaches to switch sides.
    func handleCollapsedHandleMouseDown() {
        handleTrackingDown = true
        let startMouse = NSEvent.mouseLocation
        let startOriginY = window.frame.origin.y
        var didDrag = false
        var cursorPushed = false

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { [weak self] trackedEvent, stop in
            guard let self, let ev = trackedEvent else {
                stop.pointee = true
                return
            }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y

            switch ev.type {
            case .leftMouseDragged:
                if !didDrag && hypot(dx, dy) > 4.0 {
                    didDrag = true
                    NSCursor.closedHand.push()
                    cursorPushed = true
                }
                if didDrag {
                    let screen = self.activeScreen().visibleFrame
                    let newY = min(
                        max(startOriginY + dy, screen.minY + 16),
                        screen.maxY - self.collapsedSize.height - 16
                    )
                    let newX: CGFloat
                    if abs(dx) >= 32.0 {
                        newX = min(
                            max(mouse.x - self.collapsedSize.width / 2.0, screen.minX),
                            screen.maxX - self.collapsedSize.width
                        )
                    } else {
                        newX = (self.dockSide == .left)
                            ? screen.minX
                            : (screen.maxX - self.collapsedSize.width)
                    }
                    self.window.setFrameOrigin(NSPoint(x: newX, y: newY))
                }

            case .leftMouseUp:
                stop.pointee = true
                if cursorPushed {
                    NSCursor.pop()
                }
                self.handleTrackingDown = false

                if didDrag {
                    let screen = self.activeScreen().visibleFrame
                    let newSide: MacDockSide = (mouse.x < screen.midX) ? .left : .right
                    let centerY = min(
                        max(self.window.frame.midY, screen.minY + self.collapsedSize.height / 2.0 + 16),
                        screen.maxY - self.collapsedSize.height / 2.0 - 16
                    )
                    self.dockSide = newSide
                    self.dockYRatio = min(max((centerY - screen.minY) / max(screen.height, 1.0), 0.06), 0.94)
                    UserDefaults.standard.set(self.dockSide.rawValue, forKey: PrefKey.dockSide)
                    UserDefaults.standard.set(Double(self.dockYRatio), forKey: PrefKey.dockYRatio)

                    let snapped = self.frameFor(.collapsed, on: screen)
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.16
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        self.window.animator().setFrame(snapped, display: true)
                    }
                } else {
                    self.openedByDrag = false
                    self.expand(animated: true, activateFocus: true)
                }

            default:
                break
            }
        }
        handleTrackingDown = false
    }

    public func beginHeaderDrag() {
        guard isEdgeMode, mode == .expanded else { return }
        let mouse = NSEvent.mouseLocation
        headerDragOffset = NSPoint(x: mouse.x - window.frame.origin.x, y: mouse.y - window.frame.origin.y)
    }

    public func updateHeaderDrag() {
        guard isEdgeMode, mode == .expanded, let offset = headerDragOffset else { return }
        let mouse = NSEvent.mouseLocation
        let screen = activeScreen().visibleFrame
        let newSide: MacDockSide = mouse.x < screen.midX ? .left : .right
        if newSide != dockSide {
            dockSide = newSide
        }
        let minY = screen.minY + 12
        let maxY = max(minY, screen.maxY - expandedSize.height - 12)
        let newY = min(max(mouse.y - offset.y, minY), maxY)
        let x = (dockSide == .left) ? (screen.minX + edgeMargin) : (screen.maxX - expandedSize.width - edgeMargin)
        window.setFrame(NSRect(x: x, y: newY, width: expandedSize.width, height: expandedSize.height), display: true, animate: false)
    }

    public func endHeaderDrag() {
        guard headerDragOffset != nil else { return }
        headerDragOffset = nil
        let screen = activeScreen().visibleFrame
        dockYRatio = min(max((window.frame.midY - screen.minY) / max(screen.height, 1), 0.12), 0.88)
        UserDefaults.standard.set(Double(dockYRatio), forKey: PrefKey.dockYRatio)
        UserDefaults.standard.set(dockSide.rawValue, forKey: PrefKey.dockSide)
    }

    // MARK: - Observers & Focus

    private func capturePreviousAppIfNeeded() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
    }

    private func restorePreviousAppFocus() {
        if window.isKeyWindow {
            window.resignKey()
        }
        if let app = previousApp, !app.isTerminated {
            app.activate(options: [])
        }
    }

    private func hasBlockingModal() -> Bool {
        if isModalOpen || NSApp.modalWindow != nil || MacQuickLookController.shared.isVisible {
            return true
        }
        for win in NSApp.windows where win != window && win.isVisible {
            if win is NSOpenPanel || win is NSSavePanel || win.level == .modalPanel || win.level == .popUpMenu {
                return true
            }
        }
        return false
    }

    private func installObservers() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard let self, let app else { return }
                if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self.previousApp = app
                }
            }
        }

        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshGlobalHotkeyPermissions()
                await self?.store.handleSceneActive()
            }
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.isEdgeMode,
                      self.mode == .expanded,
                      !self.isPinned,
                      !self.isAnimating,
                      !self.hasBlockingModal()
                else { return }
                let mouse = NSEvent.mouseLocation
                if !self.window.frame.contains(mouse) {
                    self.collapse(animated: true, restoreFocus: false)
                }
            }
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !isEdgeMode {
            window.orderOut(nil)
            return false
        }
        return false
    }

    // MARK: - Local Key Monitor (`Esc`, `⌘V`, `⌘O`, `⌘,`, Hotkey fallback)

    private func installLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.isRecordingHotkey { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let code = UInt32(event.keyCode)

            // Global hotkey fallback when app is active
            if self.isHotkeyEnabled && code == self.hotkeyKeyCode && self.carbonModifiers(from: flags) == self.hotkeyModifiers {
                self.triggerToggleFromHotkey()
                return nil
            }

            // Escape: pop sub-route or collapse edge drawer
            if code == UInt32(kVK_Escape) && flags.isEmpty {
                if self.route != .home {
                    self.route = .home
                    return nil
                }
                if self.isEdgeMode && self.mode == .expanded {
                    self.collapse(animated: true, restoreFocus: true)
                    return nil
                }
            }

            // ⌘, opens preferences
            if flags == .command && event.charactersIgnoringModifiers == "," && self.store.isLoggedIn {
                self.route = .preferences
                return nil
            }

            // ⌘O picks files
            if flags == .command && event.charactersIgnoringModifiers?.lowercased() == "o" && self.store.isLoggedIn {
                Task { await self.pickAndAddFiles() }
                return nil
            }

            // ⌘V pastes into drawer when NOT editing a text field
            if flags == .command && event.charactersIgnoringModifiers?.lowercased() == "v" && self.store.isLoggedIn && self.route == .home {
                let isEditingText = self.window.firstResponder is NSTextView
                if !isEditingText {
                    Task { await self.pasteClipboardIntoDrawer() }
                    return nil
                }
            }

            return event
        }
    }

    // MARK: - High-Level Actions

    public func pickAndAddFiles() async {
        let urls = await MacPlatformServices.pickFiles { [weak self] open in
            self?.isModalOpen = open
        }
        if isEdgeMode && mode == .expanded {
            window.orderFrontRegardless()
        }
        guard !urls.isEmpty else { return }
        let prepared = await MacPlatformServices.prepareDropURLs(urls)
        await store.addFiles(prepared)
    }

    public func pasteClipboardIntoDrawer() async {
        switch MacPlatformServices.readClipboard() {
        case .files(let urls):
            let prepared = await MacPlatformServices.prepareDropURLs(urls)
            await store.addFiles(prepared)
        case .image(let url):
            await store.addFiles([url], copyToManaged: false)
            MacPlatformServices.pruneClipboardFiles(excluding: Set(store.localFilePaths.values))
        case .text(let text):
            await store.addText(text)
        case .empty:
            store.showToast("剪贴板为空")
        }
    }

    public func handleDroppedURLs(_ urls: [URL]) async {
        let prepared = await MacPlatformServices.prepareDropURLs(urls)
        guard !prepared.isEmpty else { return }
        await store.addFiles(prepared)
    }

    // MARK: - Drag Monitor (System-wide file/text drag detection)

    private func startDragMonitor() {
        dragMonitorTimer?.invalidate()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickDragMonitor()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragMonitorTimer = timer
    }

    private func tickDragMonitor() {
        guard isEdgeMode, !isAnimating, !handleTrackingDown, headerDragOffset == nil else { return }
        if hasBlockingModal() { return }

        let mouse = NSEvent.mouseLocation
        let leftPressed = (NSEvent.pressedMouseButtons & 1) != 0

        let dragPb = NSPasteboard(name: .drag)
        let currentChange = dragPb.changeCount
        let hasFiles = dragPb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let hasText = !(dragPb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        if currentChange != lastDragChangeCount {
            lastDragChangeCount = currentChange
            if leftPressed && (hasFiles || hasText) {
                dragSessionActive = true
            }
        }
        if !leftPressed {
            dragSessionActive = false
        }
        let isGenuineDrag = leftPressed && dragSessionActive

        switch mode {
        case .collapsed:
            if isGenuineDrag {
                transition(to: .dragPill, animated: true)
            }
        case .dragPill:
            if !isGenuineDrag {
                transition(to: .collapsed, animated: true)
                return
            }
            if window.frame.insetBy(dx: -54, dy: -64).contains(mouse) {
                openedByDrag = true
                transition(to: .expanded, animated: true, activateFocus: false)
            }
        case .expanded:
            if openedByDrag && !isGenuineDrag && !isPinned {
                if !window.frame.insetBy(dx: -20, dy: -20).contains(mouse) {
                    openedByDrag = false
                    transition(to: .collapsed, animated: true, restoreFocus: false)
                } else {
                    openedByDrag = false
                }
            }
        }
    }

    // MARK: - Global Hotkey Engine (CGEventTap + Input Monitoring + Live Recorder)

    public func setHotkeyEnabled(_ enabled: Bool) {
        isHotkeyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PrefKey.hotkeyEnabled)
        installGlobalHotkeyEngine()
    }

    public func setHotkeyPreset(keyCode: UInt32, modifiers: UInt32) {
        if isRecordingHotkey {
            stopHotkeyRecording()
        }
        hotkeyKeyCode = keyCode
        hotkeyModifiers = modifiers
        hotkeyLabel = formatHotkeyDisplay(keyCode: keyCode, modifiers: modifiers)
        UserDefaults.standard.set(Int(keyCode), forKey: PrefKey.hotkeyKeyCode)
        UserDefaults.standard.set(Int(modifiers), forKey: PrefKey.hotkeyModifiers)
        installGlobalHotkeyEngine()
    }

    public func refreshGlobalHotkeyPermissions() {
        let prevPerm = hasGlobalHotkeyPermission
        refreshPermissionFlags()
        if hasGlobalHotkeyPermission != prevPerm || (isHotkeyEnabled && hotkeyEngine == "local_only" && hasGlobalHotkeyPermission) {
            installGlobalHotkeyEngine()
        }
    }

    public func requestAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func requestInputMonitoringPermission() {
        _ = CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    public func startHotkeyRecording() {
        stopHotkeyRecording()
        teardownGlobalHotkeyEngine()
        isRecordingHotkey = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        hotkeyRecordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let code = UInt32(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if code == UInt32(kVK_Escape) && flags.isEmpty {
                self.stopHotkeyRecording()
                return nil
            }
            let pureModifiers: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
            if pureModifiers.contains(code) { return nil }

            let hasMod = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
            guard hasMod || Self.functionKeyCodes.contains(code) else {
                NSSound.beep()
                return nil
            }

            self.hotkeyKeyCode = code
            self.hotkeyModifiers = self.carbonModifiers(from: flags)
            self.hotkeyLabel = self.formatHotkeyDisplay(keyCode: self.hotkeyKeyCode, modifiers: self.hotkeyModifiers)
            UserDefaults.standard.set(Int(self.hotkeyKeyCode), forKey: PrefKey.hotkeyKeyCode)
            UserDefaults.standard.set(Int(self.hotkeyModifiers), forKey: PrefKey.hotkeyModifiers)
            self.stopHotkeyRecording()
            return nil
        }
    }

    public func stopHotkeyRecording() {
        if let mon = hotkeyRecordMonitor {
            NSEvent.removeMonitor(mon)
            hotkeyRecordMonitor = nil
        }
        isRecordingHotkey = false
        if isHotkeyEnabled {
            installGlobalHotkeyEngine()
        }
    }

    private func refreshPermissionFlags() {
        hasGlobalHotkeyPermission = AXIsProcessTrusted() || CGPreflightListenEventAccess()
    }

    private func triggerToggleFromHotkey() {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastHotkeyTriggerAt > 0.22 else { return }
        lastHotkeyTriggerAt = now
        toggleDrawer()
    }

    private func installGlobalHotkeyEngine() {
        teardownGlobalHotkeyEngine()
        refreshPermissionFlags()
        guard isHotkeyEnabled else {
            hotkeyEngine = "disabled"
            return
        }

        if AXIsProcessTrusted() {
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            let callback: CGEventTapCallBack = { _, type, event, _ in
                guard let ctrl = EdgeDrawerController.shared else {
                    return Unmanaged.passUnretained(event)
                }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = ctrl.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }
                let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags
                let matched = MainActor.assumeIsolated { () -> Bool in
                    guard ctrl.isHotkeyEnabled, !ctrl.isRecordingHotkey else { return false }
                    return keyCode == ctrl.hotkeyKeyCode && ctrl.carbonModifiers(from: flags) == ctrl.hotkeyModifiers
                }
                if matched {
                    DispatchQueue.main.async {
                        ctrl.triggerToggleFromHotkey()
                    }
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }
            if let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: nil
            ) {
                let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                eventTap = tap
                eventTapSource = source
                hotkeyEngine = "cg_event_tap"
                return
            }
        }

        if CGPreflightListenEventAccess() {
            globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.isHotkeyEnabled, !self.isRecordingHotkey else { return }
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    if UInt32(event.keyCode) == self.hotkeyKeyCode &&
                        self.carbonModifiers(from: flags) == self.hotkeyModifiers {
                        self.triggerToggleFromHotkey()
                    }
                }
            }
            hotkeyEngine = "input_monitoring"
            return
        }

        hotkeyEngine = "local_only"
    }

    private func teardownGlobalHotkeyEngine() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let mon = globalHotkeyMonitor {
            NSEvent.removeMonitor(mon)
            globalHotkeyMonitor = nil
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    private func carbonModifiers(from cgFlags: CGEventFlags) -> UInt32 {
        var mask: UInt32 = 0
        if cgFlags.contains(.maskControl) { mask |= UInt32(controlKey) }
        if cgFlags.contains(.maskAlternate) { mask |= UInt32(optionKey) }
        if cgFlags.contains(.maskShift) { mask |= UInt32(shiftKey) }
        if cgFlags.contains(.maskCommand) { mask |= UInt32(cmdKey) }
        return mask
    }

    private static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
        UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
        UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
    ]

    private func formatHotkeyDisplay(keyCode: UInt32, modifiers: UInt32) -> String {
        var out = ""
        if (modifiers & UInt32(controlKey)) != 0 { out += "⌃" }
        if (modifiers & UInt32(optionKey)) != 0 { out += "⌥" }
        if (modifiers & UInt32(shiftKey)) != 0 { out += "⇧" }
        if (modifiers & UInt32(cmdKey)) != 0 { out += "⌘" }
        out += keyName(keyCode)
        return out
    }

    private func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key\(code)"
        }
    }

    isolated deinit {
        dragMonitorTimer?.invalidate()
        if let mon = localKeyMonitor { NSEvent.removeMonitor(mon) }
        if let mon = globalClickMonitor { NSEvent.removeMonitor(mon) }
        if let mon = globalHotkeyMonitor { NSEvent.removeMonitor(mon) }
        if let obs = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = appActiveObserver { NotificationCenter.default.removeObserver(obs) }
    }
}
