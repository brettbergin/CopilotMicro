import AppKit
import CopilotMicroCore

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    let manager: ManagerWindow
    let menu = NSMenu()
    let mainMenu = NSMenu()
    private(set) var statusItem: NSStatusItem?
    private(set) var didFinishLaunching = false

    init(configuration: EmulatorConfiguration) {
        manager = ManagerWindow(configuration: configuration)
        super.init()
        configureMainMenu()
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "Copilot Micro - Emulator only", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(item(title: "Open Manager", action: #selector(openManager), key: "m"))

        let scope = NSMenuItem(title: "Live controls unavailable in this foundation", action: nil, keyEquivalent: "")
        scope.isEnabled = false
        menu.addItem(scope)
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit Copilot Micro", action: #selector(quit), key: "q"))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "CM"
        item.button?.toolTip = "Copilot Micro - Emulator only"
        item.button?.setAccessibilityLabel("Copilot Micro, emulator only")
        item.menu = menu
        statusItem = item
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func hasExpectedMenuActions() -> Bool {
        guard let open = menu.item(withTitle: "Open Manager"),
            let quit = menu.item(withTitle: "Quit Copilot Micro")
        else {
            return false
        }
        return open.action == #selector(openManager)
            && open.target === self && open.isEnabled
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
