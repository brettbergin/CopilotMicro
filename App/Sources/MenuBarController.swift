import AppKit
import CopilotMicroCore

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    let manager: ManagerWindow
    let menu = NSMenu()
    private(set) var statusItem: NSStatusItem?

    init(configuration: EmulatorConfiguration) {
        manager = ManagerWindow(configuration: configuration)
        super.init()
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
              let quit = menu.item(withTitle: "Quit Copilot Micro") else {
            return false
        }
        return open.action == #selector(openManager)
            && open.target === self && open.isEnabled
            && quit.action == #selector(self.quit)
            && quit.target === self && quit.isEnabled
    }

    private func item(title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openManager() {
        manager.show()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
