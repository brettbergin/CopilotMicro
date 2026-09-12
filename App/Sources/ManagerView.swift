import AppKit
import CopilotMicroCore
import SwiftUI

@MainActor
struct ManagerView: View {
    let configuration: EmulatorConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(BuildIdentity.productName)
                .font(.largeTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Emulator only")
                .font(.headline)
                .accessibilityLabel("Emulator only. No live connections.")
            Text("Native foundation for the Creator Micro 2 Pro manager.")
            GroupBox("This build") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Environment", value: configuration.mode.rawValue)
                    LabeledContent("Device", value: "Unavailable: live HID not implemented")
                    LabeledContent("Copilot CLI", value: "Unavailable: bridge not implemented")
                }
                .padding(8)
            }
            Text("Controls and lighting simulation are not implemented yet.")
            Text("No device is opened, no CLI is launched or attached, and no permissions are requested.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("Foundation \(BuildIdentity.version) - internal ad-hoc build")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 380, alignment: .topLeading)
    }
}

@MainActor
final class ManagerWindow {
    let window: NSWindow
    let hostingView: NSHostingView<ManagerView>

    init(configuration: EmulatorConfiguration) {
        hostingView = NSHostingView(rootView: ManagerView(configuration: configuration))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Copilot Micro - Emulator only"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 600, height: 380)
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
}
