import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate, NSMenuDelegate {
  private static let showDockIconKey = "dropdrawer.showDockIcon"
  static var allowImmediateTerminate = false
  private var statusItem: NSStatusItem?
  private var statusMenu: NSMenu?

  static var isDockIconShown: Bool {
    UserDefaults.standard.bool(forKey: showDockIconKey)
  }

  static func setDockIconShown(_ shown: Bool) {
    UserDefaults.standard.set(shown, forKey: showDockIconKey)
    NSApp.setActivationPolicy(shown ? .regular : .accessory)
    if shown {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(Self.isDockIconShown ? .regular : .accessory)
    super.applicationDidFinishLaunching(notification)
    setupStatusBarItem()
    DispatchQueue.main.async {
      MainFlutterWindow.sharedInstance?.ensureGlobalHotkeyRegistered()
    }
  }

  private func setupStatusBarItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.autosaveName = "DropDrawerStatusItem"
    item.isVisible = true
    if let button = item.button {
      let icon = NSImage(named: "StatusIcon")
      icon?.isTemplate = true
      icon?.accessibilityDescription = "DropDrawer"
      button.image = icon
      button.toolTip = "DropDrawer"
    }

    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    self.statusMenu = menu
    self.statusItem = item
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let win = MainFlutterWindow.sharedInstance
    let isEdge = win?.currentIsEdgeMode ?? true
    let isLeft = win?.currentDockSideIsLeft ?? false

    let toggleItem = NSMenuItem(
      title: "展开 / 收起",
      action: #selector(toggleDrawer),
      keyEquivalent: ""
    )
    toggleItem.target = self
    menu.addItem(toggleItem)

    let modeItem = NSMenuItem(
      title: isEdge ? "常规窗口" : "边缘抽屉",
      action: #selector(toggleWindowMode),
      keyEquivalent: ""
    )
    modeItem.target = self
    menu.addItem(modeItem)

    let sideItem = NSMenuItem(
      title: isLeft ? "停靠右侧" : "停靠左侧",
      action: #selector(toggleDockSide),
      keyEquivalent: ""
    )
    sideItem.target = self
    menu.addItem(sideItem)

    menu.addItem(NSMenuItem.separator())

    let quitItem = NSMenuItem(
      title: "退出应用",
      action: #selector(quitApp),
      keyEquivalent: "q"
    )
    quitItem.target = self
    menu.addItem(quitItem)
  }

  @objc private func toggleDrawer() {
    MainFlutterWindow.sharedInstance?.toggleEdgeDrawer()
  }

  @objc private func toggleWindowMode() {
    if let win = MainFlutterWindow.sharedInstance {
      win.applyEdgeDrawerMode(enabled: !win.currentIsEdgeMode)
    }
  }

  @objc private func toggleDockSide() {
    MainFlutterWindow.sharedInstance?.toggleDockSide()
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if Self.allowImmediateTerminate {
      return .terminateNow
    }
    let activeCount = MainFlutterWindow.sharedInstance?.activeTransferCount ?? 0
    if activeCount <= 0 {
      return .terminateNow
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "还有 \(activeCount) 项传输正在进行"
    alert.informativeText = "退出软件会中断当前传输，下次打开软件时未完成的云盘上传会自动续传。是否仍要退出？"
    alert.addButton(withTitle: "后台继续")
    alert.addButton(withTitle: "仍要退出")
    let response = alert.runModal()
    if response == .alertSecondButtonReturn {
      return .terminateNow
    }
    return .terminateCancel
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
