import AppKit
import CopilotMicroCore

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let manager: ManagerWindow
    let menu = NSMenu()
    let mainMenu = NSMenu()
    private(set) var statusItem: NSStatusItem?
    private(set) var didFinishLaunching = false
    private let deviceItem = NSMenuItem()
    private let terminalItem = NSMenuItem()
    private let sessionItem = NSMenuItem()
    private let stateItem = NSMenuItem()
    private let issueItem = NSMenuItem()
    private let pauseItem = NSMenuItem()

    init(configuration: EmulatorConfiguration) {
        manager = ManagerWindow(configuration: configuration)
        super.init()
        configureMainMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let title = NSMenuItem(title: "Copilot Micro - Interactive demo", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        for item in [deviceItem, terminalItem, sessionItem, stateItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        issueItem.isEnabled = false
        menu.addItem(issueItem)
        menu.addItem(.separator())
        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)
        let openCopilot = NSMenuItem(title: "Open Copilot (unavailable in demo)", action: nil, keyEquivalent: "")
        openCopilot.isEnabled = false
        menu.addItem(openCopilot)
        menu.addItem(item(title: "Open Manager", action: #selector(openManager), key: "m"))
        menu.addItem(item(title: "Open Diagnostics", action: #selector(openDiagnostics), key: "d"))
        let launchAtLogin = NSMenuItem(title: "Launch at Login (unavailable)", action: nil, keyEquivalent: "")
        launchAtLogin.state = .off
        launchAtLogin.isEnabled = false
        menu.addItem(launchAtLogin)
        let updates = NSMenuItem(title: "Updates unavailable", action: nil, keyEquivalent: "")
        updates.isEnabled = false
        menu.addItem(updates)
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
        item.button?.toolTip = "Copilot Micro - Interactive demo"
        item.button?.setAccessibilityLabel("Copilot Micro, interactive demo")
        item.menu = menu
        statusItem = item
        refreshMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func hasExpectedMenuActions() -> Bool {
        guard let open = menu.item(withTitle: "Open Manager"),
            let diagnostics = menu.item(withTitle: "Open Diagnostics"),
            let quit = menu.item(withTitle: "Quit Copilot Micro")
        else {
            return false
        }
        return open.action == #selector(openManager)
            && open.target === self && open.isEnabled
            && diagnostics.action == #selector(openDiagnostics)
            && diagnostics.target === self && diagnostics.isEnabled
            && pauseItem.action == #selector(togglePause)
            && pauseItem.target === self && pauseItem.isEnabled
            && !deviceItem.isEnabled && !terminalItem.isEnabled
            && !sessionItem.isEnabled && !stateItem.isEnabled && !issueItem.isEnabled
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

    @objc private func openDiagnostics() {
        manager.show(area: .diagnostics)
    }

    @objc private func togglePause() {
        manager.store.togglePause()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func refreshMenu() {
        let store = manager.store
        deviceItem.title = "Device: Creator Micro 2 Pro (simulated)"
        terminalItem.title = "Terminal: not configured"
        sessionItem.title = "Session: \(store.selectedSession.title) (simulated)"
        stateItem.title = "State: \(store.lighting.textualState)"
        issueItem.title = "Issue: live CLI and HID unavailable"
        pauseItem.title = store.isPaused ? "Resume Demo" : "Pause Demo"
        pauseItem.keyEquivalent = "p"
        statusItem?.button?.toolTip =
            "Copilot Micro demo: \(store.lighting.textualState). Live integrations unavailable."
    }
}
