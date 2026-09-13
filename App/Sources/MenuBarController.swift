import AppKit

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let manager: ManagerWindow
    let menu = NSMenu()
    let mainMenu = NSMenu()
    private(set) var statusItem: NSStatusItem?
    private(set) var didFinishLaunching = false
    private let deviceItem = NSMenuItem()
    private let inputItem = NSMenuItem()
    private let lightingItem = NSMenuItem()
    private let issueItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let reconnectItem = NSMenuItem()

    init(hardwareEnabled: Bool) {
        manager = ManagerWindow(hardwareEnabled: hardwareEnabled)
        super.init()
        configureMainMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let title = NSMenuItem(title: "Copilot Micro", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        for item in [deviceItem, inputItem, lightingItem, issueItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        reconnectItem.title = "Reconnect Device"
        reconnectItem.target = self
        reconnectItem.action = #selector(reconnect)
        menu.addItem(reconnectItem)
        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)
        menu.addItem(item(title: "Open Manager", action: #selector(openManager), key: "m"))
        menu.addItem(item(title: "Open Lighting", action: #selector(openLighting), key: "l"))
        menu.addItem(item(title: "Open Diagnostics", action: #selector(openDiagnostics), key: "d"))
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit Copilot Micro", action: #selector(quit), key: "q"))

        manager.store.onPresentationChange = { [weak self] in
            self?.refreshMenu()
        }
        refreshMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "CM"
        item.button?.toolTip = "Copilot Micro"
        item.button?.setAccessibilityLabel("Copilot Micro device controller")
        item.menu = menu
        statusItem = item
        manager.store.start()
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.store.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if case .permissionRequired = manager.store.connectionState {
            manager.store.reconnect()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func hasExpectedMenuActions() -> Bool {
        guard let open = menu.item(withTitle: "Open Manager"),
            let lighting = menu.item(withTitle: "Open Lighting"),
            let diagnostics = menu.item(withTitle: "Open Diagnostics"),
            let quit = menu.item(withTitle: "Quit Copilot Micro")
        else {
            return false
        }
        return open.action == #selector(openManager)
            && open.target === self && open.isEnabled
            && lighting.action == #selector(openLighting)
            && lighting.target === self && lighting.isEnabled
            && diagnostics.action == #selector(openDiagnostics)
            && diagnostics.target === self && diagnostics.isEnabled
            && reconnectItem.action == #selector(reconnect)
            && reconnectItem.target === self
            && reconnectItem.isEnabled == manager.store.hardwareEnabled
            && pauseItem.action == #selector(togglePause)
            && pauseItem.target === self
            && pauseItem.isEnabled == manager.store.hardwareEnabled
            && !deviceItem.isEnabled && !inputItem.isEnabled
            && !lightingItem.isEnabled && !issueItem.isEnabled
            && quit.action == #selector(self.quit)
            && quit.target === self && quit.isEnabled
    }

    func hasExpectedMainMenuActions() -> Bool {
        guard let applicationMenu = mainMenu.item(withTitle: "Copilot Micro")?.submenu,
            let editMenu = mainMenu.item(withTitle: "Edit")?.submenu,
            let quit = applicationMenu.item(withTitle: "Quit Copilot Micro"),
            quit.action == #selector(self.quit),
            quit.target === self,
            quit.keyEquivalent == "q"
        else {
            return false
        }
        let expected: [(String, Selector, String)] = [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
        return expected.allSatisfy { title, action, key in
            guard let item = editMenu.item(withTitle: title) else {
                return false
            }
            return item.action == action && item.target == nil && item.keyEquivalent == key
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
    }

    private func configureMainMenu() {
        let applicationMenu = NSMenu()
        applicationMenu.addItem(item(title: "Quit Copilot Micro", action: #selector(quit), key: "q"))
        addTopLevelMenu(title: "Copilot Micro", submenu: applicationMenu)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(responderItem(title: "Undo", action: Selector(("undo:")), key: "z"))
        let redo = responderItem(title: "Redo", action: Selector(("redo:")), key: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(responderItem(title: "Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(responderItem(title: "Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(responderItem(title: "Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(
            responderItem(title: "Select All", action: #selector(NSText.selectAll(_:)), key: "a")
        )
        addTopLevelMenu(title: "Edit", submenu: editMenu)
    }

    private func addTopLevelMenu(title: String, submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        mainMenu.addItem(item)
    }

    private func item(title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func responderItem(title: String, action: Selector, key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    @objc private func openManager() {
        manager.show()
    }

    @objc private func openLighting() {
        manager.show(area: .lighting)
    }

    @objc private func openDiagnostics() {
        manager.show(area: .diagnostics)
    }

    @objc private func reconnect() {
        manager.store.reconnect()
    }

    @objc private func togglePause() {
        manager.store.togglePause()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func refreshMenu() {
        let store = manager.store
        deviceItem.title = "Device: \(store.connectionState.label)"
        inputItem.title = "Last input: \(store.lastInput)"
        lightingItem.title =
            "Key lighting: \(store.lightingApplied ? store.lightingColor.displayName : "Off")"
        issueItem.title =
            store.connectionState.isConnected
            ? "CLI actions: disabled pending target guards"
            : "Issue: \(store.connectionState.detail)"
        pauseItem.title = store.isPaused ? "Resume Device" : "Pause Device"
        pauseItem.keyEquivalent = "p"
        reconnectItem.isEnabled = store.hardwareEnabled
        pauseItem.isEnabled = store.hardwareEnabled
        statusItem?.button?.toolTip =
            "Copilot Micro: \(store.connectionState.label). \(store.lastInput)"
    }
}
