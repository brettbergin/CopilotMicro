import AppKit
import CopilotMicroCore
import SwiftUI

@MainActor
struct ManagerView: View {
    @ObservedObject var store: LiveDeviceStore
    @ObservedObject var bridgeStore: LiveBridgeStore

    var body: some View {
        NavigationSplitView {
            List(ManagerArea.allCases, selection: $store.selectedArea) { area in
                Label(area.title, systemImage: area.systemImage)
                    .tag(area)
                    .accessibilityLabel(area.title)
            }
            .navigationTitle(BuildIdentity.productName)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                DeviceBanner(store: store)
                Divider()
                ScrollView {
                    detail
                        .frame(maxWidth: 1_080, alignment: .topLeading)
                        .padding(28)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(store.selectedArea.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reconnect") {
                        store.reconnect()
                    }
                    .disabled(!store.hardwareEnabled)
                }
            }
        }
        .frame(minWidth: 940, minHeight: 620)
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selectedArea {
        case .overview:
            OverviewView(store: store, bridgeStore: bridgeStore)
        case .controls:
            ControlsView(store: store)
        case .lighting:
            LightingView(store: store)
        case .diagnostics:
            DiagnosticsView(store: store, bridgeStore: bridgeStore)
        }
    }
}

@MainActor
final class ManagerWindow {
    let store: LiveDeviceStore
    let bridgeStore: LiveBridgeStore
    let window: NSWindow
    let hostingView: NSHostingView<ManagerView>

    init(
        hardwareEnabled: Bool,
        bridgeEnabled: Bool,
        bridgeExtensionPackageURL: URL
    ) {
        store = LiveDeviceStore(hardwareEnabled: hardwareEnabled)
        bridgeStore = LiveBridgeStore(
            bridgeEnabled: bridgeEnabled,
            bridgeExtensionPackageURL: bridgeExtensionPackageURL
        )
        hostingView = NSHostingView(
            rootView: ManagerView(store: store, bridgeStore: bridgeStore)
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_020, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Copilot Micro"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.setFrameAutosaveName("CopilotMicroManager")
    }

    func show(area: ManagerArea? = nil) {
        if let area {
            store.selectedArea = area
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
}

private struct DeviceBanner: View {
    @ObservedObject var store: LiveDeviceStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: store.statusSymbol)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.connectionState.label)
                    .font(.headline)
                Text(store.connectionState.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if case .permissionRequired = store.connectionState {
                Button("Open Input Monitoring") {
                    store.openInputMonitoringSettings()
                }
            }
            Button(store.isPaused ? "Resume" : "Pause") {
                store.togglePause()
            }
            .disabled(!store.hardwareEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(statusColor.opacity(0.09))
    }

    private var statusColor: Color {
        switch store.connectionState {
        case .connected:
            .green
        case .discovering:
            .blue
        case .permissionRequired:
            .orange
        case .failed:
            .red
        case .inactive, .suppressedForSmoke, .disconnected:
            .secondary
        }
    }
}

private struct OverviewView: View {
    @ObservedObject var store: LiveDeviceStore
    @ObservedObject var bridgeStore: LiveBridgeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(
                title: "Creator Micro 2",
                subtitle: "Live hardware status from the device's vendor HID interface."
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                StatusCard(
                    title: "Device",
                    value: store.connectionState.label,
                    detail: "\(store.product) \(store.productID)",
                    symbol: "keyboard"
                )
                StatusCard(
                    title: "Transport",
                    value: store.transport,
                    detail: "Firmware \(store.firmwareVersion)",
                    symbol: "cable.connector"
                )
                StatusCard(
                    title: "Input Monitoring",
                    value: store.inputMonitoring.rawValue.capitalized,
                    detail: "Required for physical key and control events",
                    symbol: "hand.raised"
                )
                StatusCard(
                    title: "CLI bridge",
                    value: bridgeStore.connectionState.label,
                    detail: bridgeStore.connectionState.detail,
                    symbol: "point.3.connected.trianglepath.dotted"
                )
                StatusCard(
                    title: "Bridge extension",
                    value: bridgeStore.installationState.label,
                    detail: bridgeStore.installationState.detail,
                    symbol: "shippingbox"
                )
                StatusCard(
                    title: "Copilot launch",
                    value: bridgeStore.launchState.label,
                    detail: bridgeStore.launchState.detail,
                    symbol: "terminal"
                )
            }

            GroupBox("Live input") {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("Last event", value: store.lastInput)
                    PadView(store: store)
                        .frame(maxWidth: 620)
                }
                .padding(8)
            }

            if !store.connectionState.isConnected {
                NoticeBox(
                    title: "Device is not ready",
                    detail: store.connectionState.detail,
                    symbol: "exclamationmark.triangle"
                )
            }
        }
    }
}

private struct ControlsView: View {
    @ObservedObject var store: LiveDeviceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(
                title: "Controls",
                subtitle:
                    "Press the physical keys, turn the dial, or move the joystick. This view reflects real HID events."
            )

            HStack(alignment: .top, spacing: 26) {
                PadView(store: store)
                    .frame(maxWidth: 620)

                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Current input") {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Last event", value: store.lastInput)
                            LabeledContent(
                                "Pressed keys",
                                value:
                                    store.pressedControls.isEmpty
                                    ? "None"
                                    : store.pressedControls
                                        .map(\.displayName)
                                        .sorted()
                                        .joined(separator: ", ")
                            )
                            LabeledContent(
                                "Joystick",
                                value: store.activeJoystick?.rawValue.capitalized ?? "Neutral"
                            )
                            LabeledContent(
                                "Dial",
                                value: store.dialDirection?.displayName.capitalized ?? "Idle"
                            )
                        }
                        .padding(8)
                    }

                    NoticeBox(
                        title: "CLI actions are intentionally disabled",
                        detail:
                            "Hardware input is live. Copilot CLI actions remain blocked until exact terminal and session targeting guards are complete.",
                        symbol: "lock.shield"
                    )
                }
                .frame(minWidth: 300, maxWidth: 360)
            }

            EventList(entries: Array(store.eventLog.prefix(12)))
        }
    }
}

private struct LightingView: View {
    @ObservedObject var store: LiveDeviceStore

    private let colors: [LightingColor] = [
        .white,
        .blue,
        .purple,
        .amber,
        .green,
        .red,
        .off,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(
                title: "Lighting",
                subtitle:
                    "Set the 13 key LEDs and ambient underglow to one matching live state."
            )

            HStack(alignment: .top, spacing: 28) {
                PadView(store: store)
                    .frame(maxWidth: 620)

                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Key lighting") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Color")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82))], spacing: 8) {
                                ForEach(colors, id: \.rawValue) { color in
                                    Button(color.displayName) {
                                        store.setLightingColor(color)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(store.lightingColor == color ? .accentColor : nil)
                                }
                            }
                            Slider(value: $store.brightness, in: 0...1) {
                                Text("Brightness")
                            } minimumValueLabel: {
                                Text("0")
                            } maximumValueLabel: {
                                Text("100")
                            }
                            Text("Brightness \(Int(store.brightness * 100)) percent")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Apply to device") {
                                store.applyLighting()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.canControlLighting)
                        }
                        .padding(8)
                    }

                    Text(store.lightingStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    NoticeBox(
                        title: "Runtime lighting only",
                        detail:
                            "The app updates both lighting zones together without writing keymap flash.",
                        symbol: "checkmark.shield"
                    )
                }
                .frame(minWidth: 310, maxWidth: 370)
            }
        }
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var store: LiveDeviceStore
    @ObservedObject var bridgeStore: LiveBridgeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(
                title: "Diagnostics",
                subtitle: "Bounded in-memory device status and normalized input events."
            )

            GroupBox("Device details") {
                VStack(spacing: 12) {
                    LabeledContent("Connection", value: store.connectionState.label)
                    LabeledContent("Product", value: store.product)
                    LabeledContent("Product ID", value: store.productID)
                    LabeledContent("Transport", value: store.transport)
                    LabeledContent("Firmware", value: store.firmwareVersion)
                    LabeledContent("Active layer index", value: store.activeLayer)
                    LabeledContent("Keymap SHA-256", value: store.keymapSHA256)
                    LabeledContent("Raw HID reports", value: "\(store.rawReportCount)")
                    LabeledContent("Decoded notifications", value: "\(store.notificationCount)")
                    LabeledContent(
                        "Radial notifications",
                        value: "\(store.radialNotificationCount)"
                    )
                    LabeledContent("Last radial sample", value: store.lastRadialSample)
                    LabeledContent(
                        "Invalid notifications",
                        value: "\(store.invalidNotificationCount)"
                    )
                }

                GroupBox("Copilot CLI bridge") {
                    VStack(spacing: 12) {
                        LabeledContent("State", value: bridgeStore.connectionState.label)
                        LabeledContent("Detail", value: bridgeStore.connectionState.detail)
                        LabeledContent(
                            "Extension",
                            value: bridgeStore.installationState.label
                        )
                        LabeledContent(
                            "Extension detail",
                            value: bridgeStore.installationState.detail
                        )
                        LabeledContent("Open Copilot", value: bridgeStore.launchState.label)
                        LabeledContent("Launch detail", value: bridgeStore.launchState.detail)
                    }
                    .padding(8)
                }
                .padding(8)
            }

            HStack {
                Button("Reconnect device") {
                    store.reconnect()
                }
                Button("Restart CLI bridge") {
                    bridgeStore.restart()
                }
                .disabled(!bridgeStore.bridgeEnabled)
                Button("Install CLI bridge...") {
                    reviewBridgeInstallation()
                }
                .disabled(!bridgeStore.installationState.canInstall)
                Button("Open Copilot in Ghostty...") {
                    chooseProjectAndOpenCopilot()
                }
                .disabled(!bridgeStore.canOpenCopilot)
                Button("Clear event list") {
                    store.clearEvents()
                }
            }

            EventList(entries: store.eventLog)
        }
    }

    private func reviewBridgeInstallation() {
        guard
            bridgeStore.installationState.canInstall,
            let destinationURL = bridgeStore.installationState.destinationURL
        else {
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install Copilot CLI Bridge?"
        alert.informativeText =
            "Install the read-only observer at \(destinationURL.path)? It registers no "
            + "tools, hooks, permission handler, or stateful actions. Existing unrelated "
            + "or modified files are never overwritten."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        bridgeStore.installExtension()
    }

    private func chooseProjectAndOpenCopilot() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project for Copilot CLI"
        panel.prompt = "Open Copilot"
        panel.message =
            "Copilot Micro will create a new Ghostty window for this directory. "
            + "It will not type into an existing terminal."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let projectDirectoryURL = panel.url else {
            return
        }
        bridgeStore.openCopilot(
            projectDirectoryURL: projectDirectoryURL.standardizedFileURL
        )
    }
}

private struct PageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.bold())
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StatusCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct NoticeBox: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EventList: View {
    let entries: [LiveDeviceEvent]

    var body: some View {
        GroupBox("Recent hardware events") {
            if entries.isEmpty {
                Text("No hardware events observed yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } else {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(entry.timestamp, style: .time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title)
                                    .font(.callout.weight(.semibold))
                                Text(entry.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        if entry.id != entries.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }
}
