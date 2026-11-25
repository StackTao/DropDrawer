import Carbon.HIToolbox
import Cocoa
import FlutterMacOS
import ImageIO
import QuartzCore
import Security

/// Custom macOS window implementing a unified 3-state floating edge drawer (left or right, draggable vertically):
/// 1. `collapsed` (10x88): Quiet minimal edge handle; click to open, drag vertically or across screen to move/flip side.
/// 2. `drag_pill` (246x46): Compact horizontal guide pill anchored at the handle's exact edge & vertical position
///    shown only during genuine file/folder/text drags.
/// 3. `expanded` (368x560): Full cross-device drawer blooming organically out from the handle/pill position.
class MainFlutterWindow: NSWindow {
  private enum DrawerMode: String {
    case collapsed
    case dragPill = "drag_pill"
    case expanded
  }

  enum DockSide: String {
    case left
    case right
  }

  private static let dockSideKey = "dropdrawer.dockSide"
  private static let dockYRatioKey = "dropdrawer.dockYRatio"
  private static let hotkeyEnabledKey = "dropdrawer.hotkeyEnabled"
  private static let hotkeyKeyCodeKey = "dropdrawer.hotkeyKeyCode"
  private static let hotkeyModifiersKey = "dropdrawer.hotkeyModifiers"
  static weak var sharedInstance: MainFlutterWindow?

  private var channel: FlutterMethodChannel?
  private var dragMonitorTimer: Timer?
  private var globalClickMonitor: Any?
  private var eventTap: CFMachPort?
  private var eventTapSource: CFRunLoopSource?
  private var localHotkeyMonitor: Any?
  private var globalHotkeyMonitor: Any?
  private var activeHotkeyEngine: String = "local"
  private var lastHotkeyFireTime: CFTimeInterval = 0
  private var hotkeyRecordMonitor: Any?
  private var pendingHotkeyRecordResult: FlutterResult?
  private var appActiveObserver: NSObjectProtocol?
  private var isHotkeyEnabled: Bool = true
  private var hotkeyKeyCode: UInt32 = UInt32(kVK_ANSI_D)
  private var hotkeyModifiers: UInt32 = UInt32(optionKey | shiftKey)
  private var lastDragChangeCount: Int = NSPasteboard(name: .drag).changeCount
  private var dragSessionActive: Bool = false
  private var openedByDrag: Bool = false
  private var isEdgeMode: Bool = false
  private var mode: DrawerMode = .expanded
  private var dockSide: DockSide = .right
  private var dockYRatio: CGFloat = 0.5
  private var handleTrackingDown: Bool = false
  private var expandedDragOffset: NSPoint?
  private var expandedMouseDown: NSPoint?
  private var expandedMousePosition: NSPoint?
  private var isAnimating: Bool = false
  /// Reveal animation waiting for Flutter to draw the new mode (`drawerFrameReady`).
  private var pendingReveal: (mode: DrawerMode, token: Int, run: () -> Void)?
  private var revealToken: Int = 0
  private var isPinned: Bool = false
  private var isModalOpen: Bool = false
  private var isMainDrawerActive: Bool = false
  private var previousApp: NSRunningApplication?
  private var workspaceObserver: NSObjectProtocol?
  private var effectView: NSVisualEffectView?

  var currentDockSideIsLeft: Bool { dockSide == .left }
  var currentIsEdgeMode: Bool { isEdgeMode }

  private let expandedSize = NSSize(width: 368, height: 560)
  private let collapsedSize = NSSize(width: 10, height: 88)
  private let dragPillSize = NSSize(width: 246, height: 46)

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command && event.charactersIgnoringModifiers?.lowercased() == "q" {
      NSApp.terminate(nil)
      return true
    }
    if isMainDrawerActive && !isModalOpen {
      if flags == .command && event.charactersIgnoringModifiers?.lowercased() == "v" {
        channel?.invokeMethod("onPasteShortcut", arguments: nil)
        return true
      }
      if flags.isEmpty && event.keyCode == 53 && isEdgeMode && mode == .expanded {
        isPinned = false
        transitionTo(.collapsed, animated: true, restoreFocus: true)
        return true
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  @objc func paste(_ sender: Any?) {
    if isMainDrawerActive && !isModalOpen {
      channel?.invokeMethod("onPasteShortcut", arguments: nil)
    }
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown && isEdgeMode && mode == .collapsed && !isAnimating {
      handleCollapsedHandleMouseDown()
      return
    }
    if isEdgeMode && mode == .expanded {
      switch event.type {
      case .leftMouseDown:
        let point = convertPoint(toScreen: event.locationInWindow)
        expandedMouseDown = point
        expandedMousePosition = point
      case .leftMouseDragged, .leftMouseUp:
        expandedMousePosition = convertPoint(toScreen: event.locationInWindow)
      default:
        break
      }
    }
    if event.type == .leftMouseDown && isEdgeMode && mode == .expanded {
      if !NSApp.isActive {
        NSApp.activate(ignoringOtherApps: true)
      }
      if !self.isKeyWindow {
        self.makeKey()
      }
    }
    super.sendEvent(event)
  }

  /// Native click-or-drag tracking for the collapsed edge handle:
  /// - Click (<= 4pt movement) expands the drawer.
  /// - Vertical drag moves the handle along the edge; horizontal drag across screen switches left/right side.
  private func handleCollapsedHandleMouseDown() {
    handleTrackingDown = true
    let startMouse = NSEvent.mouseLocation
    let startOriginY = self.frame.origin.y
    var didDrag = false
    var cursorPushed = false

    self.trackEvents(
      matching: [.leftMouseDragged, .leftMouseUp],
      timeout: NSEvent.foreverDuration,
      mode: .eventTracking
    ) { [weak self] trackedEvent, stop in
      guard let self = self, let ev = trackedEvent else {
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
          // Keep glued to current edge for pure vertical slides; detach if pulled >= 32pt horizontally.
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
          self.setFrameOrigin(NSPoint(x: newX, y: newY))
        }

      case .leftMouseUp:
        stop.pointee = true
        if cursorPushed {
          NSCursor.pop()
        }
        self.handleTrackingDown = false

        if didDrag {
          let screen = self.activeScreen().visibleFrame
          let newSide: DockSide = (mouse.x < screen.midX) ? .left : .right
          let centerY = min(
            max(self.frame.midY, screen.minY + self.collapsedSize.height / 2.0 + 16),
            screen.maxY - self.collapsedSize.height / 2.0 - 16
          )
          let newRatio = min(
            max((centerY - screen.minY) / max(screen.height, 1.0), 0.06),
            0.94
          )
          self.dockSide = newSide
          self.dockYRatio = newRatio
          self.saveDockPreferences()
          self.notifyDrawerState()

          let snapped = self.frameFor(.collapsed, on: screen)
          NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(snapped, display: true)
          }
        } else {
          self.openedByDrag = false
          self.transitionTo(.expanded, animated: true, activateFocus: true)
        }

      default:
        break
      }
    }
    self.handleTrackingDown = false
  }

  private func saveDockPreferences() {
    UserDefaults.standard.set(dockSide.rawValue, forKey: Self.dockSideKey)
    UserDefaults.standard.set(Double(dockYRatio), forKey: Self.dockYRatioKey)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = .clear

    self.contentViewController = flutterViewController
    flutterViewController.view.wantsLayer = true

    let container = NSVisualEffectView(frame: flutterViewController.view.bounds)
    container.autoresizingMask = [.width, .height]
    container.appearance = NSAppearance(named: .darkAqua)
    container.material = .hudWindow
    container.blendingMode = .behindWindow
    container.state = .active
    container.wantsLayer = true
    container.layer?.cornerRadius = 14
    container.layer?.masksToBounds = true
    flutterViewController.view.addSubview(container, positioned: .below, relativeTo: nil)
    self.effectView = container

    if let savedSide = UserDefaults.standard.string(forKey: Self.dockSideKey),
       let parsed = DockSide(rawValue: savedSide) {
      self.dockSide = parsed
    }
    if let savedRatio = UserDefaults.standard.object(forKey: Self.dockYRatioKey) as? Double {
      self.dockYRatio = CGFloat(min(max(savedRatio, 0.06), 0.94))
    }
    if UserDefaults.standard.object(forKey: Self.hotkeyEnabledKey) != nil {
      self.isHotkeyEnabled = UserDefaults.standard.bool(forKey: Self.hotkeyEnabledKey)
    }
    if UserDefaults.standard.object(forKey: Self.hotkeyKeyCodeKey) != nil {
      self.hotkeyKeyCode = UInt32(UserDefaults.standard.integer(forKey: Self.hotkeyKeyCodeKey))
    }
    if UserDefaults.standard.object(forKey: Self.hotkeyModifiersKey) != nil {
      self.hotkeyModifiers = UInt32(UserDefaults.standard.integer(forKey: Self.hotkeyModifiersKey))
    }

    self.appearance = NSAppearance(named: .darkAqua)
    self.title = "DropDrawer"
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    self.backgroundColor = .clear
    self.isOpaque = false
    self.hasShadow = true
    self.minSize = NSSize(width: 360, height: 460)

    let screen = activeScreen().visibleFrame
    let hasSavedSession = !(UserDefaults.standard.string(forKey: "flutter.auth_token")?.isEmpty ?? true)
    if hasSavedSession {
      // Pre-place silently (alpha=0) at the docked edge and orderFrontRegardless so FlutterViewController
      // immediately boots the Dart engine without ever flashing an off-position window.
      self.styleMask = [.borderless, .fullSizeContentView]
      self.isMovableByWindowBackground = false
      self.level = .floating
      self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      self.effectView?.layer?.cornerRadius = cornerRadiusFor(.expanded)
      self.alphaValue = 0.0
      self.setFrame(frameFor(.expanded, on: screen), display: true, animate: false)
      self.orderFrontRegardless()

      // Safety net: if Flutter takes unexpectedly long, ensure the window becomes visible.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
        guard let self = self else { return }
        if self.alphaValue < 0.5 && !self.isAnimating {
          self.alphaValue = 1.0
          self.makeKeyAndOrderFront(nil)
        }
      }
    } else {
      self.isMovableByWindowBackground = true
      let initialFrame = NSRect(
        x: screen.midX - 190,
        y: screen.midY - 260,
        width: 380,
        height: 520
      )
      self.setFrame(initialFrame, display: true, animate: false)
      self.makeKeyAndOrderFront(nil)
    }

    Self.sharedInstance = self
    startLocalHotkeyFallbackMonitor()
    installGlobalHotkeyEngine()
    appActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.refreshHotkeyPermissionAndEngine()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)
    setupMethodChannel(controller: flutterViewController)
    startPreviousAppTracker()
    startGlobalOutsideClickMonitor()
    startDragMonitor()

    super.awakeFromNib()
  }

  private func startPreviousAppTracker() {
    let myPid = ProcessInfo.processInfo.processIdentifier
    if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != myPid {
      self.previousApp = front
    }
    workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app.processIdentifier != myPid
      else { return }
      self?.previousApp = app
    }
  }

  private func startGlobalOutsideClickMonitor() {
    globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      guard let self = self else { return }
      guard self.isEdgeMode, self.mode == .expanded, !self.isPinned, !self.isAnimating,
            self.expandedDragOffset == nil else { return }
      if self.isModalOpen || self.hasBlockingModalPanel() { return }

      let mouse = NSEvent.mouseLocation
      if !self.frame.contains(mouse) {
        self.transitionTo(.collapsed, animated: true, restoreFocus: false)
      }
    }
  }

  private func capturePreviousAppIfNeeded() {
    let myPid = ProcessInfo.processInfo.processIdentifier
    if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != myPid {
      self.previousApp = front
    }
  }

  private func restorePreviousAppFocus() {
    if self.isKeyWindow {
      self.resignKey()
    }
    if NSApp.isActive, let prev = previousApp, !prev.isTerminated {
      prev.activate(options: [])
    }
  }

  private func setupMethodChannel(controller: FlutterViewController) {
    let ch = FlutterMethodChannel(
      name: "com.dropdrawer/drawer_window",
      binaryMessenger: controller.engine.binaryMessenger
    )
    self.channel = ch

    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "setEdgeDrawerMode":
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? true
        self.applyEdgeDrawerMode(enabled: enabled)
        result(true)
      case "expandDrawer":
        self.openedByDrag = false
        self.transitionTo(.expanded, animated: true, activateFocus: true)
        result(true)
      case "drawerFrameReady":
        let modeName = (call.arguments as? [String: Any])?["mode"] as? String
        self.flutterDrewFrame(modeName: modeName)
        result(true)
      case "collapseDrawer":
        self.isPinned = false
        self.openedByDrag = false
        self.transitionTo(.collapsed, animated: true, restoreFocus: true)
        result(true)
      case "dragExpandedDrawer":
        if let phase = call.arguments as? String {
          self.dragExpandedDrawer(phase)
        }
        result(true)
      case "setPinned":
        let pinned = (call.arguments as? [String: Any])?["pinned"] as? Bool ?? false
        self.isPinned = pinned
        self.notifyDrawerState()
        result(true)
      case "setDockSide":
        let sideStr = (call.arguments as? [String: Any])?["side"] as? String ?? "right"
        self.setDockSide(sideStr == "left" ? .left : .right)
        result(true)
      case "setModalOpen":
        let open = (call.arguments as? [String: Any])?["open"] as? Bool ?? false
        self.isModalOpen = open
        result(true)
      case "setMainDrawerActive":
        let active = (call.arguments as? [String: Any])?["active"] as? Bool ?? false
        self.isMainDrawerActive = active
        result(true)
      case "revealInFinder":
        if let path = (call.arguments as? [String: Any])?["path"] as? String {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        result(true)
      case "pickFiles":
        self.presentNativeFilePicker(result: result)
      case "pickDirectory":
        self.presentNativeDirectoryPicker(result: result)
      case "openDirectory":
        if let path = (call.arguments as? [String: Any])?["path"] as? String {
          try? FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
          )
          NSWorkspace.shared.open(URL(fileURLWithPath: path))
          result(true)
        } else {
          result(false)
        }
      case "generateThumbnail":
        if let path = (call.arguments as? [String: Any])?["path"] as? String {
          result(self.generateImageThumbnailBase64(path: path))
        } else {
          result(nil)
        }
      case "getSystemSettings":
        self.refreshHotkeyPermissionAndEngine()
        result([
          "hotkeyEnabled": self.isHotkeyEnabled,
          "hotkeyLabel": self.formatHotkeyDisplay(
            keyCode: self.hotkeyKeyCode,
            modifiers: self.hotkeyModifiers
          ),
          "hasGlobalHotkeyPermission": self.hasGlobalHotkeyPermission(),
          "hotkeyEngine": self.activeHotkeyEngine,
          "launchAtLogin": self.isLaunchAtLoginEnabled(),
          "showDockIcon": AppDelegate.isDockIconShown,
          "dockSide": self.dockSide.rawValue,
        ])
      case "setShowDockIcon":
        let shown = (call.arguments as? [String: Any])?["shown"] as? Bool ?? false
        AppDelegate.setDockIconShown(shown)
        self.notifyDrawerState()
        result(true)
      case "quitApp":
        result(true)
        DispatchQueue.main.async {
          NSApp.terminate(nil)
        }
      case "showMoreMenu":
        let args = call.arguments as? [String: Any]
        let anchorX = args?["x"] as? Double ?? 350.0
        let anchorY = args?["y"] as? Double ?? 42.0
        let username = args?["username"] as? String ?? ""
        self.presentNativeMoreMenu(
          anchorRightX: CGFloat(anchorX),
          anchorBottomY: CGFloat(anchorY),
          username: username,
          result: result
        )
      case "requestAccessibilityPermission":
        self.requestAccessibilityPermission()
        result(self.hasGlobalHotkeyPermission())
      case "requestInputMonitoringPermission":
        self.requestInputMonitoringPermission()
        result(self.hasGlobalHotkeyPermission())
      case "setHotkeyEnabled":
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? true
        self.setHotkeyEnabled(enabled)
        result(true)
      case "setHotkeyPreset":
        let args = call.arguments as? [String: Any]
        let keyCode = UInt32(args?["keyCode"] as? Int ?? Int(kVK_ANSI_D))
        let modNames = args?["modifiers"] as? [String] ?? []
        let mods = self.carbonModifiers(fromNames: modNames)
        let ok = self.updateHotkey(keyCode: keyCode, modifiers: mods)
        result([
          "ok": ok,
          "label": self.formatHotkeyDisplay(keyCode: self.hotkeyKeyCode, modifiers: self.hotkeyModifiers),
        ])
      case "startHotkeyRecording":
        self.startHotkeyRecording(result: result)
      case "cancelHotkeyRecording":
        self.stopHotkeyRecording(cancelled: true)
        result(true)
      case "setLaunchAtLogin":
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
        result(self.setLaunchAtLogin(enabled: enabled))
      case "readClipboard":
        result(self.readNativeClipboard())
      case "copyFileToClipboard":
        if let path = (call.arguments as? [String: Any])?["path"] as? String {
          result(self.copyNativeFilesToClipboard(paths: [path]))
        } else {
          result(false)
        }
      case "copyFilesToClipboard":
        if let paths = (call.arguments as? [String: Any])?["paths"] as? [String] {
          result(self.copyNativeFilesToClipboard(paths: paths))
        } else {
          result(false)
        }
      case "openExternalUrl":
        if let urlStr = (call.arguments as? [String: Any])?["url"] as? String,
           let url = URL(string: urlStr) {
          result(NSWorkspace.shared.open(url))
        } else {
          result(false)
        }
      case "openUpdatePackage":
        guard let path = (call.arguments as? [String: Any])?["path"] as? String,
              path.hasSuffix(".dmg"),
              FileManager.default.fileExists(atPath: path) else {
          result("unavailable")
          return
        }
        result(NSWorkspace.shared.open(URL(fileURLWithPath: path)) ? "opened" : "unavailable")
      case "installUpdate":
        guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
          result("unavailable")
          return
        }
        // Mounting and copying take a few seconds; keep the UI responsive.
        DispatchQueue.global(qos: .userInitiated).async {
          let outcome = UpdateInstaller.prepare(diskImage: URL(fileURLWithPath: path))
          DispatchQueue.main.async {
            result(outcome)
            if outcome == "installing" {
              // Let Flutter show "正在安装" before the app quits; the helper
              // swaps the bundle once this process has exited.
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSApp.terminate(nil)
              }
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func activeScreen(at point: NSPoint? = nil) -> NSScreen {
    let mouse = point ?? NSEvent.mouseLocation
    if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
      return hit
    }
    return NSScreen.screens.first ?? NSScreen.main!
  }

  private func dragExpandedDrawer(_ phase: String) {
    guard isEdgeMode, mode == .expanded, !isAnimating, !isModalOpen else {
      expandedDragOffset = nil
      return
    }
    let mouse = expandedMousePosition ?? NSEvent.mouseLocation
    if phase == "start" {
      let start = expandedMouseDown ?? mouse
      expandedDragOffset = NSPoint(x: start.x - frame.minX, y: start.y - frame.minY)
      openedByDrag = false
      return
    }
    guard let offset = expandedDragOffset else { return }
    if phase == "update" || phase == "end" {
      let area = activeScreen(at: mouse).visibleFrame
      let x = min(max(mouse.x - offset.x, area.minX), max(area.minX, area.maxX - frame.width))
      let y = min(max(mouse.y - offset.y, area.minY), area.maxY - frame.height)
      setFrameOrigin(NSPoint(x: x, y: y))
    }
    if phase == "end" {
      expandedDragOffset = nil
      let area = (screen ?? activeScreen(at: mouse)).visibleFrame
      dockSide = frame.midX < area.midX ? .left : .right
      dockYRatio = min(max((frame.midY - area.minY) / area.height, 0.06), 0.94)
      saveDockPreferences()
      notifyDrawerState()
    }
  }

  private func clampedOriginY(height: CGFloat, margin: CGFloat, in screen: NSRect) -> CGFloat {
    let desired = screen.minY + (screen.height * dockYRatio) - (height / 2.0)
    let minY = screen.minY + margin
    let maxY = max(minY, screen.maxY - height - margin)
    return min(max(desired, minY), maxY)
  }

  /// All three states are anchored to the user's chosen dockSide (left/right) and dockYRatio.
  private func frameFor(_ targetMode: DrawerMode, on screen: NSRect) -> NSRect {
    switch targetMode {
    case .collapsed:
      let x = (dockSide == .left) ? screen.minX : (screen.maxX - collapsedSize.width)
      return NSRect(
        x: x,
        y: clampedOriginY(height: collapsedSize.height, margin: 16, in: screen),
        width: collapsedSize.width,
        height: collapsedSize.height
      )
    case .dragPill:
      let x = (dockSide == .left)
        ? (screen.minX + 14)
        : (screen.maxX - dragPillSize.width - 14)
      return NSRect(
        x: x,
        y: clampedOriginY(height: dragPillSize.height, margin: 16, in: screen),
        width: dragPillSize.width,
        height: dragPillSize.height
      )
    case .expanded:
      let x = (dockSide == .left)
        ? (screen.minX + 12)
        : (screen.maxX - expandedSize.width - 12)
      return NSRect(
        x: x,
        y: clampedOriginY(height: expandedSize.height, margin: 12, in: screen),
        width: expandedSize.width,
        height: expandedSize.height
      )
    }
  }

  func setDockSide(_ side: DockSide) {
    dockSide = side
    saveDockPreferences()
    notifyDrawerState()
    if isEdgeMode && !isAnimating {
      let screen = activeScreen().visibleFrame
      let target = frameFor(mode, on: screen)
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.18
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        self.animator().setFrame(target, display: true)
      }
    }
  }

  func toggleDockSide() {
    setDockSide(dockSide == .right ? .left : .right)
  }

  private func cornerRadiusFor(_ targetMode: DrawerMode) -> CGFloat {
    switch targetMode {
    case .collapsed: return 5
    case .dragPill: return 13
    case .expanded: return 16
    }
  }

  func applyEdgeDrawerMode(enabled: Bool) {
    expandedDragOffset = nil
    isEdgeMode = enabled
    isAnimating = false
    openedByDrag = false
    self.contentView?.layer?.removeAllAnimations()
    self.contentView?.layer?.transform = CATransform3DIdentity
    self.alphaValue = 1.0

    if enabled {
      self.styleMask = [.borderless, .fullSizeContentView]
      self.isMovableByWindowBackground = false
      self.level = .floating
      self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      self.hasShadow = true
      self.isPinned = false
      self.mode = .expanded
      self.effectView?.layer?.cornerRadius = cornerRadiusFor(.expanded)

      let screen = activeScreen().visibleFrame
      self.setFrame(frameFor(.expanded, on: screen), display: true, animate: false)
      self.makeKeyAndOrderFront(nil)
      notifyDrawerState()
    } else {
      self.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
      self.titlebarAppearsTransparent = true
      self.titleVisibility = .hidden
      self.isMovableByWindowBackground = true
      self.level = .normal
      self.collectionBehavior = [.managed]
      self.hasShadow = true
      self.mode = .expanded
      self.minSize = NSSize(width: 360, height: 460)
      self.effectView?.layer?.cornerRadius = 14
      let screen = activeScreen().visibleFrame
      let frame = NSRect(
        x: screen.midX - 190,
        y: screen.midY - 260,
        width: 380,
        height: 520
      )
      self.setFrame(frame, display: true, animate: false)
      self.makeKeyAndOrderFront(nil)
      notifyDrawerState()
    }
  }

  func toggleEdgeDrawer() {
    NSLog("[DropDrawer] toggleEdgeDrawer isEdgeMode=%d mode=%@ isVisible=%d", isEdgeMode ? 1 : 0, mode.rawValue, self.isVisible ? 1 : 0)
    if !isEdgeMode {
      if self.isVisible && NSApp.isActive {
        self.orderOut(nil)
        restorePreviousAppFocus()
      } else {
        capturePreviousAppIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        self.makeKeyAndOrderFront(nil)
      }
      return
    }
    if mode == .expanded {
      isPinned = false
      openedByDrag = false
      transitionTo(.collapsed, animated: true, restoreFocus: true)
    } else {
      openedByDrag = false
      transitionTo(.expanded, animated: true, activateFocus: true)
    }
  }

  /// Called by AppDelegate after applicationDidFinishLaunching.
  func ensureGlobalHotkeyRegistered() {
    Self.sharedInstance = self
    refreshHotkeyPermissionAndEngine()
  }

  private func hasGlobalHotkeyPermission() -> Bool {
    return AXIsProcessTrusted() || CGPreflightListenEventAccess()
  }

  private func refreshHotkeyPermissionAndEngine() {
    let hadEngine = activeHotkeyEngine
    installGlobalHotkeyEngine()
    if hadEngine != activeHotkeyEngine {
      notifyDrawerState()
    }
  }

  private func requestAccessibilityPermission() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
    }
    refreshHotkeyPermissionAndEngine()
  }

  private func requestInputMonitoringPermission() {
    _ = CGRequestListenEventAccess()
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
      NSWorkspace.shared.open(url)
    }
    refreshHotkeyPermissionAndEngine()
  }

  private func triggerToggleFromHotkey(source: String) {
    let now = CACurrentMediaTime()
    if now - lastHotkeyFireTime < 0.25 {
      return
    }
    lastHotkeyFireTime = now
    NSLog("[DropDrawer] Hotkey triggered via %@", source)
    toggleEdgeDrawer()
  }

  private func startLocalHotkeyFallbackMonitor() {
    if let existing = localHotkeyMonitor {
      NSEvent.removeMonitor(existing)
    }
    localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self = self else { return event }
      guard self.isHotkeyEnabled, self.hotkeyRecordMonitor == nil else { return event }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      if UInt32(event.keyCode) == self.hotkeyKeyCode &&
         self.carbonModifiers(from: flags) == self.hotkeyModifiers {
        self.triggerToggleFromHotkey(source: "localMonitor")
        return nil
      }
      return event
    }
  }

  private func carbonModifiers(from cgFlags: CGEventFlags) -> UInt32 {
    var mask: UInt32 = 0
    if cgFlags.contains(.maskControl) { mask |= UInt32(controlKey) }
    if cgFlags.contains(.maskAlternate) { mask |= UInt32(optionKey) }
    if cgFlags.contains(.maskShift) { mask |= UInt32(shiftKey) }
    if cgFlags.contains(.maskCommand) { mask |= UInt32(cmdKey) }
    return mask
  }

  private func edgeScaleTransform(
    size: NSSize,
    sx: CGFloat,
    sy: CGFloat,
    tx: CGFloat = 0,
    anchorYRatio: CGFloat = 0.5
  ) -> CATransform3D {
    let px: CGFloat = (dockSide == .left) ? 0.0 : size.width
    let py: CGFloat = size.height * min(max(anchorYRatio, 0.14), 0.86)
    let signedTx: CGFloat = (dockSide == .left) ? -tx : tx
    var t = CATransform3DIdentity
    t = CATransform3DTranslate(t, px + signedTx, py, 0)
    t = CATransform3DScale(t, sx, sy, 1.0)
    t = CATransform3DTranslate(t, -px, -py, 0)
    return t
  }

  /// A spring with damping ratio 1: settles quickly without overshooting, so the
  /// drawer never visibly bounces past its final size.
  private static func criticallyDampedSpring(
    from start: CATransform3D, mass: CGFloat, stiffness: CGFloat
  ) -> CASpringAnimation {
    let spring = CASpringAnimation(keyPath: "transform")
    spring.fromValue = NSValue(caTransform3D: start)
    spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    spring.mass = mass
    spring.stiffness = stiffness
    spring.damping = 2.0 * sqrt(stiffness * mass)
    spring.duration = spring.settlingDuration
    return spring
  }

  /// Runs `reveal` once Flutter reports a frame drawn for `targetMode`, so the
  /// previous mode's layout is never shown in the resized window. Falls back
  /// after a short timeout (older Dart side, or a dropped message).
  private func revealWhenFlutterDrew(_ targetMode: DrawerMode, reveal: @escaping () -> Void) {
    revealToken += 1
    let token = revealToken
    pendingReveal = (targetMode, token, reveal)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
      self?.runPendingReveal(token: token)
    }
  }

  private func flutterDrewFrame(modeName: String?) {
    guard let pending = pendingReveal, pending.mode.rawValue == modeName else { return }
    // Give the raster thread one display frame to present what Dart just built.
    let token = pending.token
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
      self?.runPendingReveal(token: token)
    }
  }

  private func runPendingReveal(token: Int) {
    guard let pending = pendingReveal, pending.token == token else { return }
    pendingReveal = nil
    pending.run()
  }

  private func relativeAnchorYRatio(for frame: NSRect, on screen: NSRect) -> CGFloat {
    let anchorY = screen.minY + (screen.height * dockYRatio)
    return (anchorY - frame.minY) / max(frame.height, 1.0)
  }

  private func transitionTo(
    _ target: DrawerMode,
    animated: Bool,
    activateFocus: Bool = false,
    restoreFocus: Bool = false
  ) {
    guard isEdgeMode else { return }
    if mode == target { return }

    expandedDragOffset = nil
    let previous = mode
    let screen = activeScreen().visibleFrame
    let targetFrame = frameFor(target, on: screen)

    if target == .expanded && activateFocus {
      capturePreviousAppIfNeeded()
    } else if previous == .expanded && target == .collapsed {
      openedByDrag = false
      if restoreFocus {
        restorePreviousAppFocus()
      } else if self.isKeyWindow {
        self.resignKey()
      }
    }

    // Show right-center drag guide pill with crisp spring bloom from the right edge handle.
    if target == .dragPill {
      self.contentView?.layer?.removeAllAnimations()
      self.mode = .dragPill
      self.effectView?.layer?.cornerRadius = cornerRadiusFor(.dragPill)
      self.hasShadow = true

      // Uniform scale only: non-uniform scaling squashes text and icons.
      let startTx = edgeScaleTransform(size: dragPillSize, sx: 0.9, sy: 0.9, tx: 10)
      self.alphaValue = 0.0
      self.setFrame(targetFrame, display: true, animate: false)
      self.orderFrontRegardless()
      // Tell Flutter only after the resize so its first new-mode frame has the new size.
      self.notifyDrawerState()

      guard let layer = self.contentView?.layer else {
        self.alphaValue = 1.0
        return
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.transform = startTx
      CATransaction.commit()

      revealWhenFlutterDrew(.dragPill) { [weak self] in
        guard let self = self else { return }
        let spring = Self.criticallyDampedSpring(from: startTx, mass: 0.75, stiffness: 340)
        layer.transform = CATransform3DIdentity
        layer.add(spring, forKey: "dragPillBloom")

        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0.12
          self.animator().alphaValue = 1.0
        }
      }
      return
    }

    // Expand directly into our own full cross-device drawer at right-center!
    if target == .expanded {
      isAnimating = animated
      mode = .expanded
      self.effectView?.layer?.cornerRadius = cornerRadiusFor(.expanded)
      self.hasShadow = true

      let presentWindow = {
        if activateFocus {
          NSApp.activate(ignoringOtherApps: true)
          self.makeKeyAndOrderFront(nil)
        } else {
          self.orderFrontRegardless()
        }
      }

      if !animated {
        self.contentView?.layer?.transform = CATransform3DIdentity
        self.alphaValue = 1.0
        self.setFrame(targetFrame, display: true, animate: false)
        presentWindow()
        notifyDrawerState()
        return
      }

      self.alphaValue = 0.0
      self.setFrame(targetFrame, display: true, animate: false)
      presentWindow()
      notifyDrawerState()

      guard let layer = self.contentView?.layer else {
        self.alphaValue = 1.0
        self.isAnimating = false
        return
      }

      // Grow from the edge (or the guide pill) with a uniform scale; scaling the
      // axes differently squashes the drawer's text and cards mid-animation.
      let anchorRatio = relativeAnchorYRatio(for: targetFrame, on: screen)
      let startScale: CGFloat = previous == .dragPill ? 0.94 : 0.9
      let startTx = edgeScaleTransform(
        size: expandedSize, sx: startScale, sy: startScale, tx: 8, anchorYRatio: anchorRatio)

      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.removeAllAnimations()
      layer.transform = startTx
      CATransaction.commit()

      revealWhenFlutterDrew(.expanded) { [weak self] in
        guard let self = self else { return }
        let spring = Self.criticallyDampedSpring(from: startTx, mass: 0.85, stiffness: 310)
        layer.transform = CATransform3DIdentity
        layer.add(spring, forKey: "drawerSpringExpand")

        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0.14
          ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
          self.animator().alphaValue = 1.0
        }

        let unlockDelay = min(max(spring.settlingDuration * 0.65, 0.20), 0.34)
        DispatchQueue.main.asyncAfter(deadline: .now() + unlockDelay) { [weak self] in
          self?.isAnimating = false
        }
      }
      return
    }

    // Collapse back to quiet right-center edge handle.
    if !animated {
      mode = .collapsed
      self.contentView?.layer?.transform = CATransform3DIdentity
      self.effectView?.layer?.cornerRadius = cornerRadiusFor(.collapsed)
      self.hasShadow = false
      self.setFrame(targetFrame, display: true, animate: false)
      self.alphaValue = 1.0
      notifyDrawerState()
      return
    }

    isAnimating = true
    guard let layer = self.contentView?.layer else {
      mode = .collapsed
      isAnimating = false
      self.effectView?.layer?.cornerRadius = cornerRadiusFor(.collapsed)
      self.hasShadow = false
      self.setFrame(targetFrame, display: true, animate: false)
      self.alphaValue = 1.0
      notifyDrawerState()
      return
    }

    let anchorRatio = relativeAnchorYRatio(for: self.frame, on: screen)
    let endTx = edgeScaleTransform(
      size: self.frame.size,
      sx: 0.92,
      sy: 0.92,
      tx: 12,
      anchorYRatio: anchorRatio
    )
    let shrink = CABasicAnimation(keyPath: "transform")
    shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
    shrink.toValue = NSValue(caTransform3D: endTx)
    shrink.duration = 0.19
    shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
    layer.transform = endTx
    layer.add(shrink, forKey: "drawerShrinkCollapse")

    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.18
      ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
      self.animator().alphaValue = 0.0
    }, completionHandler: { [weak self] in
      guard let self = self else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.removeAllAnimations()
      layer.transform = CATransform3DIdentity
      CATransaction.commit()

      self.mode = .collapsed
      self.effectView?.layer?.cornerRadius = self.cornerRadiusFor(.collapsed)
      self.hasShadow = false
      self.setFrame(targetFrame, display: true, animate: false)
      self.notifyDrawerState()

      self.revealWhenFlutterDrew(.collapsed) { [weak self] in
        NSAnimationContext.runAnimationGroup({ ctx in
          ctx.duration = 0.10
          self?.animator().alphaValue = 1.0
        }, completionHandler: { [weak self] in
          self?.isAnimating = false
        })
      }
    })
  }

  private final class MenuSelectionCollector: NSObject {
    var selected: String?
    @objc func onSelect(_ sender: NSMenuItem) {
      selected = sender.representedObject as? String
    }
  }

  /// Presents a genuine native macOS frosted NSMenu aligned cleanly beneath the `···` toolbar button.
  private func presentNativeMoreMenu(
    anchorRightX: CGFloat,
    anchorBottomY: CGFloat,
    username: String,
    result: @escaping FlutterResult
  ) {
    guard let view = self.contentView else {
      result(nil)
      return
    }
    self.isModalOpen = true

    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        result(nil)
        return
      }
      let collector = MenuSelectionCollector()
      let menu = NSMenu()
      menu.autoenablesItems = false
      menu.appearance = NSAppearance(named: .darkAqua)

      func addItem(_ title: String, symbol: String, id: String, keyEq: String = "") {
        let item = NSMenuItem(
          title: title,
          action: #selector(MenuSelectionCollector.onSelect(_:)),
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
      addItem(
        self.dockSide == .left ? "停靠右侧" : "停靠左侧",
        symbol: self.dockSide == .left ? "sidebar.right" : "sidebar.left",
        id: "toggle_dock_side"
      )
      menu.addItem(NSMenuItem.separator())
      addItem("退出登录", symbol: "rectangle.portrait.and.arrow.right", id: "logout")
      addItem("退出应用", symbol: "power", id: "quit", keyEq: "q")

      let menuWidth = max(menu.size.width, 136)
      let x = min(max(8, anchorRightX - menuWidth), max(8, view.bounds.width - menuWidth - 8))
      let y = max(8, view.bounds.height - anchorBottomY)
      menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: view)

      self.isModalOpen = false
      result(collector.selected)
    }
  }

  private func presentNativeFilePicker(result: @escaping FlutterResult) {
    self.isModalOpen = true

    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        result([String]())
        return
      }
      NSApp.activate(ignoringOtherApps: true)
      let panel = NSOpenPanel()
      panel.title = "选择要放入抽屉的文件或文件夹"
      panel.prompt = "放入抽屉"
      panel.allowsMultipleSelection = true
      panel.canChooseFiles = true
      panel.canChooseDirectories = true
      panel.resolvesAliases = true
      panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)

      panel.begin { [weak self] response in
        self?.isModalOpen = false
        if response == .OK {
          let paths = panel.urls.map { $0.standardizedFileURL.path }
          result(paths)
        } else {
          result([String]())
        }
        if let self = self, self.isEdgeMode && self.mode == .expanded {
          self.orderFrontRegardless()
        }
      }
    }
  }

  private func presentNativeDirectoryPicker(result: @escaping FlutterResult) {
    self.isModalOpen = true

    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        result(nil)
        return
      }
      NSApp.activate(ignoringOtherApps: true)
      let panel = NSOpenPanel()
      panel.title = "选择默认下载保存目录"
      panel.prompt = "选择此目录"
      panel.allowsMultipleSelection = false
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.resolvesAliases = true
      panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)

      panel.begin { [weak self] response in
        self?.isModalOpen = false
        if response == .OK, let url = panel.url {
          result(url.standardizedFileURL.path)
        } else {
          result(nil)
        }
        if let self = self, self.isEdgeMode && self.mode == .expanded {
          self.orderFrontRegardless()
        }
      }
    }
  }

  /// Generates a compact 160px JPEG base64 thumbnail using native ImageIO (supports PNG/JPG/HEIC/WEBP/GIF).
  private func generateImageThumbnailBase64(path: String) -> String? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: 160,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
      return nil
    }
    let rep = NSBitmapImageRep(cgImage: cgImg)
    guard let jpegData = rep.representation(
      using: .jpeg,
      properties: [.compressionFactor: 0.72]
    ) else {
      return nil
    }
    return jpegData.base64EncodedString()
  }

  private func launchAgentPlistURL() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
      .appendingPathComponent("com.dropdrawer.app.plist")
  }

  private func isLaunchAtLoginEnabled() -> Bool {
    return FileManager.default.fileExists(atPath: launchAgentPlistURL().path)
  }

  private func setLaunchAtLogin(enabled: Bool) -> Bool {
    let plistUrl = launchAgentPlistURL()
    do {
      if enabled {
        try FileManager.default.createDirectory(
          at: plistUrl.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        let bundlePath = Bundle.main.bundlePath
        let plist: [String: Any] = [
          "Label": "com.dropdrawer.app",
          "ProgramArguments": ["/usr/bin/open", "-a", bundlePath],
          "RunAtLoad": true,
          "KeepAlive": false,
        ]
        let data = try PropertyListSerialization.data(
          fromPropertyList: plist,
          format: .xml,
          options: 0
        )
        try data.write(to: plistUrl, options: .atomic)
      } else if FileManager.default.fileExists(atPath: plistUrl.path) {
        try FileManager.default.removeItem(at: plistUrl)
      }
      notifyDrawerState()
      return true
    } catch {
      return false
    }
  }

  private func setHotkeyEnabled(_ enabled: Bool) {
    isHotkeyEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Self.hotkeyEnabledKey)
    installGlobalHotkeyEngine()
    notifyDrawerState()
  }

  private func carbonModifiers(fromNames names: [String]) -> UInt32 {
    var mask: UInt32 = 0
    for n in names {
      switch n.lowercased() {
      case "control", "ctrl": mask |= UInt32(controlKey)
      case "option", "alt": mask |= UInt32(optionKey)
      case "shift": mask |= UInt32(shiftKey)
      case "command", "cmd", "meta": mask |= UInt32(cmdKey)
      default: break
      }
    }
    return mask
  }

  private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var mask: UInt32 = 0
    if flags.contains(.control) { mask |= UInt32(controlKey) }
    if flags.contains(.option) { mask |= UInt32(optionKey) }
    if flags.contains(.shift) { mask |= UInt32(shiftKey) }
    if flags.contains(.command) { mask |= UInt32(cmdKey) }
    return mask
  }

  private func updateHotkey(keyCode: UInt32, modifiers: UInt32) -> Bool {
    hotkeyKeyCode = keyCode
    hotkeyModifiers = modifiers
    UserDefaults.standard.set(Int(keyCode), forKey: Self.hotkeyKeyCodeKey)
    UserDefaults.standard.set(Int(modifiers), forKey: Self.hotkeyModifiersKey)
    installGlobalHotkeyEngine()
    notifyDrawerState()
    return true
  }

  /// Captures the next valid key combination locally (bypassing menus & active global hotkey).
  private func startHotkeyRecording(result: @escaping FlutterResult) {
    stopHotkeyRecording(cancelled: true)
    teardownGlobalHotkeyEngine()
    pendingHotkeyRecordResult = result

    NSApp.activate(ignoringOtherApps: true)
    self.makeKeyAndOrderFront(nil)

    hotkeyRecordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self = self else { return event }
      let keyCode = UInt32(event.keyCode)
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

      // Escape cancels recording without changing hotkey.
      if keyCode == UInt32(kVK_Escape) && flags.isEmpty {
        self.stopHotkeyRecording(cancelled: true)
        return nil
      }

      // Ignore pure modifier keys.
      let pureModifierCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
      if pureModifierCodes.contains(keyCode) {
        return nil
      }

      let hasPrimaryModifier = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
      let isFunctionKey = Self.functionKeyCodes.contains(keyCode)
      guard hasPrimaryModifier || isFunctionKey else {
        NSSound.beep()
        return nil
      }

      let carbonMods = self.carbonModifiers(from: flags)
      let ok = self.updateHotkey(keyCode: keyCode, modifiers: carbonMods)
      let label = self.formatHotkeyDisplay(keyCode: keyCode, modifiers: carbonMods)

      let cb = self.pendingHotkeyRecordResult
      self.pendingHotkeyRecordResult = nil
      if let mon = self.hotkeyRecordMonitor {
        NSEvent.removeMonitor(mon)
        self.hotkeyRecordMonitor = nil
      }
      cb?([
        "recorded": true,
        "ok": ok,
        "label": label,
      ])
      return nil
    }
  }

  private func stopHotkeyRecording(cancelled: Bool) {
    if let mon = hotkeyRecordMonitor {
      NSEvent.removeMonitor(mon)
      hotkeyRecordMonitor = nil
    }
    if let cb = pendingHotkeyRecordResult {
      pendingHotkeyRecordResult = nil
      cb([
        "recorded": false,
        "cancelled": cancelled,
        "label": formatHotkeyDisplay(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers),
      ])
    }
    if cancelled && isHotkeyEnabled {
      installGlobalHotkeyEngine()
    }
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
    out += keyCodeToDisplayName(keyCode)
    return out
  }

  private func keyCodeToDisplayName(_ code: UInt32) -> String {
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
    case kVK_ANSI_Minus: return "-"
    case kVK_ANSI_Equal: return "="
    case kVK_ANSI_LeftBracket: return "["
    case kVK_ANSI_RightBracket: return "]"
    case kVK_ANSI_Backslash: return "\\"
    case kVK_ANSI_Semicolon: return ";"
    case kVK_ANSI_Quote: return "'"
    case kVK_ANSI_Comma: return ","
    case kVK_ANSI_Period: return "."
    case kVK_ANSI_Slash: return "/"
    case kVK_ANSI_Grave: return "`"
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    case kVK_UpArrow: return "↑"
    case kVK_DownArrow: return "↓"
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

  /// Installs the most reliable native global hotkey engine available on modern macOS:
  /// 1. CGEventTap (when Accessibility is granted) — intercepts and consumes shortcut globally across all apps & Spaces.
  /// 2. NSEvent Global Monitor (when Input Monitoring is granted) — listens globally across all apps.
  /// 3. Local Monitor — always active when DropDrawer is focused.
  private func installGlobalHotkeyEngine() {
    teardownGlobalHotkeyEngine()
    guard isHotkeyEnabled else {
      activeHotkeyEngine = "disabled"
      return
    }

    let label = formatHotkeyDisplay(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)

    // 1. Prefer CGEventTap (works reliably on macOS 15–27 and consumes the keystroke cleanly).
    if AXIsProcessTrusted() {
      let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
      let callback: CGEventTapCallBack = { _, type, event, _ -> Unmanaged<CGEvent>? in
        guard let win = MainFlutterWindow.sharedInstance else {
          return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
          if let tap = win.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
          }
          return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, win.isHotkeyEnabled, win.hotkeyRecordMonitor == nil else {
          return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = win.carbonModifiers(from: event.flags)
        if keyCode == win.hotkeyKeyCode && mods == win.hotkeyModifiers {
          DispatchQueue.main.async {
            win.triggerToggleFromHotkey(source: "cgEventTap")
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
        self.eventTap = tap
        self.eventTapSource = source
        self.activeHotkeyEngine = "cg_event_tap"
        NSLog("[DropDrawer] Global hotkey active via CGEventTap (%@)", label)
        return
      }
    }

    // 2. Fallback to NSEvent Global Monitor when Input Monitoring is granted.
    if CGPreflightListenEventAccess() {
      globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self = self else { return }
        guard self.isHotkeyEnabled, self.hotkeyRecordMonitor == nil else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if UInt32(event.keyCode) == self.hotkeyKeyCode &&
           self.carbonModifiers(from: flags) == self.hotkeyModifiers {
          DispatchQueue.main.async {
            self.triggerToggleFromHotkey(source: "globalMonitor")
          }
        }
      }
      self.activeHotkeyEngine = "input_monitoring"
      NSLog("[DropDrawer] Global hotkey active via InputMonitoring (%@)", label)
      return
    }

    // 3. No global permission yet — local monitor still works while DropDrawer is focused.
    self.activeHotkeyEngine = "local_only"
    NSLog("[DropDrawer] Hotkey (%@) in local_only mode (grant Accessibility/InputMonitoring for global)", label)
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

  private func readNativeClipboard() -> [String: Any] {
    let pb = NSPasteboard.general

    if let urls = pb.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] {
      let existingPaths = urls.compactMap { rawUrl -> String? in
        let path = rawUrl.standardizedFileURL.path
        return FileManager.default.fileExists(atPath: path) ? path : nil
      }
      if !existingPaths.isEmpty {
        return ["kind": "files", "paths": existingPaths]
      }
    }

    var pngData: Data? = pb.data(forType: .png)
    if pngData == nil, let image = NSImage(pasteboard: pb) {
      if let tiff = image.tiffRepresentation,
         let bitmap = NSBitmapImageRep(data: tiff) {
        pngData = bitmap.representation(using: .png, properties: [:])
      }
    }
    if let data = pngData, !data.isEmpty {
      if let savedPath = saveClipboardPng(data: data) {
        return ["kind": "image", "paths": [savedPath]]
      }
    }

    if let text = pb.string(forType: .string),
       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return ["kind": "text", "text": text]
    }

    return ["kind": "empty"]
  }

  private func saveClipboardPng(data: Data) -> String? {
    let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let dir = baseDir.appendingPathComponent("DropDrawer/clipboard_images", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let fmt = DateFormatter()
      fmt.dateFormat = "yyyyMMdd_HHmmss"
      let filename = "clip_\(fmt.string(from: Date())).png"
      let fileUrl = dir.appendingPathComponent(filename)
      try data.write(to: fileUrl, options: .atomic)
      return fileUrl.path
    } catch {
      return nil
    }
  }

  private func copyNativeFilesToClipboard(paths: [String]) -> Bool {
    let urls = paths.compactMap { path -> NSURL? in
      FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) as NSURL : nil
    }
    guard !urls.isEmpty else { return false }
    let pb = NSPasteboard.general
    pb.clearContents()
    return pb.writeObjects(urls)
  }

  private func notifyDrawerState() {
    channel?.invokeMethod("onDrawerStateChanged", arguments: [
      "edgeMode": isEdgeMode,
      "expanded": mode == .expanded,
      "pinned": isPinned,
      "mode": mode.rawValue,
      "dockSide": dockSide.rawValue,
      "hotkeyEnabled": isHotkeyEnabled,
      "hotkeyLabel": formatHotkeyDisplay(
        keyCode: hotkeyKeyCode,
        modifiers: hotkeyModifiers
      ),
      "hasGlobalHotkeyPermission": hasGlobalHotkeyPermission(),
      "hotkeyEngine": activeHotkeyEngine,
      "launchAtLogin": isLaunchAtLoginEnabled(),
      "showDockIcon": AppDelegate.isDockIconShown,
    ])
  }

  private func startDragMonitor() {
    dragMonitorTimer?.invalidate()
    let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
      self?.tickDragMonitor()
    }
    RunLoop.main.add(timer, forMode: .common)
    dragMonitorTimer = timer
  }

  private func hasBlockingModalPanel() -> Bool {
    if NSApp.modalWindow != nil { return true }
    for win in NSApp.windows where win != self && win.isVisible {
      if win is NSOpenPanel || win is NSSavePanel || win.level == .modalPanel {
        return true
      }
    }
    return false
  }

  private func tickDragMonitor() {
    guard isEdgeMode, !isAnimating, !handleTrackingDown, expandedDragOffset == nil else { return }
    if isModalOpen || hasBlockingModalPanel() { return }

    let screen = activeScreen().visibleFrame
    let mouse = NSEvent.mouseLocation
    let leftPressed = (NSEvent.pressedMouseButtons & 1) != 0

    let dragPb = NSPasteboard(name: .drag)
    let currentChange = dragPb.changeCount
    let dragPbHasFiles = dragPb.canReadObject(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    )
    let dragPbHasText =
      !(dragPb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

    if currentChange != lastDragChangeCount {
      lastDragChangeCount = currentChange
      if leftPressed && (dragPbHasFiles || dragPbHasText) {
        dragSessionActive = true
      }
    }
    if !leftPressed {
      dragSessionActive = false
    }

    let isGenuineDrag = leftPressed && dragSessionActive

    switch mode {
    case .collapsed:
      let expected = frameFor(.collapsed, on: screen)
      if abs(self.frame.origin.x - expected.origin.x) > 40 {
        self.setFrame(expected, display: true, animate: false)
      }
      if isGenuineDrag {
        // Show our right-center compact horizontal guide pill at the drawer's own position.
        transitionTo(.dragPill, animated: true)
      }

    case .dragPill:
      if !isGenuineDrag {
        transitionTo(.collapsed, animated: true)
        return
      }
      // Once the drag gets close to our right-center guide pill, bloom directly into our full drawer!
      let triggerRect = self.frame.insetBy(dx: -48, dy: -60)
      if triggerRect.contains(mouse) {
        openedByDrag = true
        transitionTo(.expanded, animated: true, activateFocus: false)
      }

    case .expanded:
      // If opened by drag and user drags far away and releases outside the drawer, fold back cleanly.
      if openedByDrag && !isGenuineDrag && !isPinned {
        if !self.frame.insetBy(dx: -20, dy: -20).contains(mouse) {
          openedByDrag = false
          transitionTo(.collapsed, animated: true, restoreFocus: false)
        } else {
          // Dropped inside our drawer: stay open so user sees their item added (click outside to dismiss).
          openedByDrag = false
        }
      }
    }
  }

  deinit {
    stopHotkeyRecording(cancelled: true)
    teardownGlobalHotkeyEngine()
    if let obs = appActiveObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    if let mon = localHotkeyMonitor {
      NSEvent.removeMonitor(mon)
      localHotkeyMonitor = nil
    }
    dragMonitorTimer?.invalidate()
    if let obs = workspaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(obs)
    }
    if let mon = globalClickMonitor {
      NSEvent.removeMonitor(mon)
    }
  }
}

/// Replaces the running app with the one inside a verified update disk image.
///
/// The new bundle must satisfy the running app's designated requirement (same
/// bundle identifier, same signing certificate). That rejects a tampered
/// package even when its download checksum matches, and it keeps macOS
/// privacy permissions such as Accessibility, which are tied to that identity.
/// An ad-hoc signed app has no stable identity, so it cannot update itself.
private enum UpdateInstaller {
  static func prepare(diskImage: URL) -> String {
    guard diskImage.pathExtension == "dmg",
          FileManager.default.fileExists(atPath: diskImage.path) else {
      return "unavailable"
    }
    let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
    let parent = current.deletingLastPathComponent()
    guard FileManager.default.isWritableFile(atPath: parent.path),
          FileManager.default.isWritableFile(atPath: current.path) else {
      return "not_writable"
    }

    let mountPoint = FileManager.default.temporaryDirectory
      .appendingPathComponent("dropdrawer-update-mount-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
    } catch {
      return "unavailable"
    }
    guard run("/usr/bin/hdiutil", ["attach", diskImage.path, "-nobrowse", "-readonly",
                                   "-noautoopen", "-mountpoint", mountPoint.path]) else {
      try? FileManager.default.removeItem(at: mountPoint)
      return "unavailable"
    }
    defer {
      _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
      try? FileManager.default.removeItem(at: mountPoint)
    }

    let contents = (try? FileManager.default.contentsOfDirectory(
      at: mountPoint, includingPropertiesForKeys: nil)) ?? []
    guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
      return "unavailable"
    }
    guard satisfiesOwnRequirement(newApp) else { return "signature_mismatch" }

    // Stage next to the current bundle so the final swap is a same-volume rename.
    let staged = parent.appendingPathComponent(".DropDrawer-update-\(UUID().uuidString).app")
    guard run("/usr/bin/ditto", [newApp.path, staged.path]) else {
      try? FileManager.default.removeItem(at: staged)
      return "unavailable"
    }
    guard satisfiesOwnRequirement(staged), launchSwap(staged: staged, target: current) else {
      try? FileManager.default.removeItem(at: staged)
      return "unavailable"
    }
    return "installing"
  }

  private static func satisfiesOwnRequirement(_ app: URL) -> Bool {
    var selfCode: SecCode?
    var selfStatic: SecStaticCode?
    var requirement: SecRequirement?
    guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
          SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
          SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess,
          let requirement else {
      return false
    }
    var candidate: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess,
          let candidate else {
      return false
    }
    return SecStaticCodeCheckValidity(candidate, [], requirement) == errSecSuccess
  }

  /// Starts a detached helper that waits for this process to exit, swaps the
  /// bundles (restoring the old one if the swap fails) and relaunches the app.
  private static func launchSwap(staged: URL, target: URL) -> Bool {
    let backup = target.deletingLastPathComponent()
      .appendingPathComponent(".DropDrawer-previous-\(UUID().uuidString).app")
    let script = """
      while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
      if /bin/mv "$3" "$4"; then
        if /bin/mv "$2" "$3"; then
          /bin/rm -rf "$4"
        else
          /bin/mv "$4" "$3"
          /bin/rm -rf "$2"
        fi
      else
        /bin/rm -rf "$2"
      fi
      /usr/bin/open "$3"
      """
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = ["-c", script, "dropdrawer-update",
                        String(ProcessInfo.processInfo.processIdentifier),
                        staged.path, target.path, backup.path]
    helper.standardInput = FileHandle.nullDevice
    helper.standardOutput = FileHandle.nullDevice
    helper.standardError = FileHandle.nullDevice
    do {
      try helper.run()
      return true
    } catch {
      return false
    }
  }

  private static func run(_ tool: String, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }
}
