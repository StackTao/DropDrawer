import AppKit
import DropDrawerCore

@main
@MainActor
final class DropDrawerMacAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var store: DropDrawerStore!
    private var controller: EdgeDrawerController!

    static func main() {
        let app = NSApplication.shared
        let delegate = DropDrawerMacAppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let showDock = UserDefaults.standard.bool(forKey: "dd.mac.showDockIcon")
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)

        setupMainMenu()

        let storage = SessionStorage(keychainService: "com.dropdrawer.mac.session")
        store = DropDrawerStore(storage: storage)
        controller = EdgeDrawerController(store: store)
        setupStatusBarItem()

        Task {
            await store.bootstrap()
            MacPlatformServices.pruneClipboardFiles(excluding: Set(store.localFilePaths.values))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.expand(animated: true, activateFocus: true)
        return true
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard store.isLoggedIn, !urls.isEmpty else { return }
        controller.expand(animated: true, activateFocus: true)
        Task {
            await controller.handleDroppedURLs(urls)
        }
    }

    // MARK: - Standard App & Edit Menu (enables ⌘C / ⌘V / ⌘X / ⌘A in TextFields)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "偏好设置…", action: #selector(openPreferencesAction), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DropDrawer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Bar Status Item

    private func setupStatusBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "DropDrawerMacNativeStatusItem"
        item.isVisible = true
        if let button = item.button {
            if let icon = NSImage(named: "StatusIcon") {
                icon.isTemplate = true
                icon.accessibilityDescription = "DropDrawer"
                button.image = icon
            } else {
                let sym = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "DropDrawer")
                sym?.isTemplate = true
                button.image = sym
            }
            button.toolTip = "DropDrawer"
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusMenu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleTitle = controller.isEdgeMode
            ? (controller.mode == .expanded ? "收起抽屉" : "展开抽屉")
            : (controller.window.isVisible ? "隐藏窗口" : "显示窗口")
        let toggleItem = NSMenuItem(
            title: controller.isHotkeyEnabled ? "\(toggleTitle)  (\(controller.hotkeyLabel))" : toggleTitle,
            action: #selector(toggleDrawerAction),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        if store.isLoggedIn {
            let pickItem = NSMenuItem(title: "选取文件放入抽屉…", action: #selector(pickFilesAction), keyEquivalent: "")
            pickItem.target = self
            menu.addItem(pickItem)

            let pasteItem = NSMenuItem(title: "粘贴剪贴板内容", action: #selector(pasteAction), keyEquivalent: "")
            pasteItem.target = self
            menu.addItem(pasteItem)
        }

        menu.addItem(.separator())

        let modeItem = NSMenuItem(
            title: controller.isEdgeMode ? "切换为常规窗口" : "切换为边缘抽屉",
            action: #selector(toggleWindowModeAction),
            keyEquivalent: ""
        )
        modeItem.target = self
        menu.addItem(modeItem)

        if controller.isEdgeMode {
            let sideItem = NSMenuItem(
                title: controller.dockSide == .left ? "停靠到屏幕右侧" : "停靠到屏幕左侧",
                action: #selector(toggleDockSideAction),
                keyEquivalent: ""
            )
            sideItem.target = self
            menu.addItem(sideItem)

            let pinItem = NSMenuItem(
                title: "固定展开抽屉",
                action: #selector(togglePinAction),
                keyEquivalent: ""
            )
            pinItem.target = self
            pinItem.state = controller.isPinned ? .on : .off
            menu.addItem(pinItem)
        }

        menu.addItem(.separator())

        if store.isLoggedIn {
            let prefItem = NSMenuItem(title: "偏好设置…", action: #selector(openPreferencesAction), keyEquivalent: ",")
            prefItem.target = self
            menu.addItem(prefItem)
        }

        let quitItem = NSMenuItem(title: "退出 DropDrawer", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggleDrawerAction() {
        controller.toggleDrawer()
    }

    @objc private func pickFilesAction() {
        controller.expand(animated: true, activateFocus: true)
        Task { await controller.pickAndAddFiles() }
    }

    @objc private func pasteAction() {
        controller.expand(animated: true, activateFocus: true)
        Task { await controller.pasteClipboardIntoDrawer() }
    }

    @objc private func toggleWindowModeAction() {
        controller.toggleWindowMode()
    }

    @objc private func toggleDockSideAction() {
        controller.toggleDockSide()
    }

    @objc private func togglePinAction() {
        controller.togglePinned()
    }

    @objc private func openPreferencesAction() {
        guard store.isLoggedIn else { return }
        controller.openPreferences()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
