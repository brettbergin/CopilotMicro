import AppKit
import CopilotMicroCore
import CopilotMicroStorage
import SwiftUI

@MainActor
struct ManagerView: View {
    @ObservedObject var store: EmulatorStore

    var body: some View {
        NavigationSplitView {
            List(ManagerArea.allCases, selection: $store.selectedArea) { area in
                Label(area.title, systemImage: area.systemImage)
                    .tag(area)
                    .accessibilityLabel(area.title)
            }
            .navigationTitle(BuildIdentity.productName)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            VStack(spacing: 0) {
                DemoBanner(store: store)
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
                    Picker("Demo scenario", selection: scenarioBinding) {
                        ForEach(EmulatorScenario.allCases) { scenario in
                            Text(scenario.title).tag(scenario)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .accessibilityLabel("Demo scenario")
                }
            }
        }
        .frame(minWidth: 980, minHeight: 650)
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selectedArea {
        case .overview:
            OverviewView(store: store)
        case .controls:
            ControlsView(store: store)
        case .lighting:
            LightingView(store: store)
        case .connection:
            ConnectionSettingsView(store: store)
        case .configuration:
            ConfigurationView(store: store)
        case .updates:
            UpdatesView(store: store)
        case .diagnostics:
            DiagnosticsView(store: store)
        }
    }

    private var scenarioBinding: Binding<EmulatorScenario> {
        Binding(get: { store.scenario }, set: { store.selectScenario($0) })
    }
}

@MainActor
final class ManagerWindow {
    let store: EmulatorStore
    let window: NSWindow
    let hostingView: NSHostingView<ManagerView>

    init(
        configuration: EmulatorConfiguration,
        localConfigurationStore: LocalConfigurationStore? = nil,
        diagnosticStore: DiagnosticStore? = nil,
        initialStorageError: String? = nil
    ) {
        store = EmulatorStore(
            configuration: configuration,
            localConfigurationStore: localConfigurationStore,
            diagnosticStore: diagnosticStore,
            initialStorageError: initialStorageError
        )
        hostingView = NSHostingView(rootView: ManagerView(store: store))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_060, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Copilot Micro - Demo"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 900, height: 600)
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

private struct DemoBanner: View {
    @ObservedObject var store: EmulatorStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "testtube.2")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Interactive demo only")
                    .font(.headline)
                Text("No device, CLI, terminal automation, extension, permissions or network connection is active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(store.lighting.textualState)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .accessibilityLabel("Simulated session state: \(store.lighting.textualState)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.09))
    }
}

private struct OverviewView: View {
    @ObservedObject var store: EmulatorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(
                title: "Overview",
                subtitle: "Walk the intended experience without connecting to hardware or Copilot CLI."
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                StatusCard(
                    title: "Creator Micro 2 Pro",
                    value: "Simulated",
                    detail: "USB/Bluetooth and battery unavailable",
                    symbol: "keyboard"
                )
                StatusCard(
                    title: "Copilot CLI",
                    value: "Not connected",
                    detail: "Selected demo session: \(store.selectedSession.title)",
                    symbol: "terminal"
                )
                StatusCard(
                    title: "Preferred terminal",
                    value: "Not configured",
                    detail: "Ghostty, iTerm2 and Terminal.app are planned",
                    symbol: "macwindow"
                )
            }

            GroupBox("Simulated selected session") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.selectedSession.title)
                                .font(.title3.weight(.semibold))
                            Text(store.selectedSession.detail)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatePill(projection: store.lighting)
                    }
                    Text(store.statusDetail)
                    Picker("Scenario", selection: scenarioBinding) {
                        ForEach(EmulatorScenario.allCases) { scenario in
                            Text(scenario.title).tag(scenario)
                        }
                    }
                    .pickerStyle(.menu)
                    HStack {
                        Button(store.isPaused ? "Resume demo" : "Pause demo") {
                            store.togglePause()
                        }
                        if store.scenario == .completed, !store.completionAcknowledged {
                            Button("Acknowledge with verified interaction") {
                                store.acknowledgeCompletion()
                            }
                        }
                    }
                }
                .padding(8)
            }

            NoticeBox(
                title: "Live capability gap",
                detail: store.prominentIssue,
                symbol: "exclamationmark.triangle"
            )

            EventList(entries: Array(store.eventLog.prefix(5)), emptyText: "No demo events yet.")
        }
    }

    private var scenarioBinding: Binding<EmulatorScenario> {
        Binding(get: { store.scenario }, set: { store.selectScenario($0) })
    }
}

private struct ControlsView: View {
    @ObservedObject var store: EmulatorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(
                title: "Controls",
                subtitle: "Select a drawn key to edit its local assignment. Selection never executes the action."
            )

            HStack(alignment: .top, spacing: 26) {
                PadView(store: store, editingEnabled: true)
                    .frame(maxWidth: 560)

                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Selected control") {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Physical position", value: store.selectedControl.displayName)
                            Picker("Assigned action", selection: assignmentBinding) {
                                ForEach(ActionID.allCases, id: \.self) { action in
                                    Text(action.displayName).tag(action)
                                }
                                .disabled(!store.canEditConfiguration)
                            }
                            Text(
                                "Editing changes the demo configuration only. It does not run the action or write device flash."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            HStack {
                                Button("Simulate selected press") {
                                    store.simulateSelectedControl()
                                }
                                .keyboardShortcut(.return, modifiers: [.command])
                                Button("Reset all defaults") {
                                    store.resetAssignments()
                                }
                                .disabled(!store.canEditConfiguration)
                            }
                        }
                        .padding(8)
                    }

                    GroupBox("Physical input simulator") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("These controls are separate from the assignment editor.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Dial left") {
                                    store.simulateDial(delta: -1)
                                }
                                Button("Dial right") {
                                    store.simulateDial(delta: 1)
                                }
                            }
                            HStack {
                                Button("Up") {
                                    store.simulateJoystick(.north)
                                }
                                Button("Down") {
                                    store.simulateJoystick(.south)
                                }
                                Button("Confirm") {
                                    store.simulateJoystick(.east)
                                }
                                Button("Back") {
                                    store.simulateJoystick(.west)
                                }
                            }
                            Button("Wide key: contacts 10 and 11") {
                                store.simulateWideKeyPress()
                            }
                            if store.sessionPickerOpen {
                                LabeledContent("Highlighted", value: store.highlightedSession.title)
                                Text("Selected remains \(store.selectedSession.title) until Confirm.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                    }
                }
                .frame(minWidth: 320, maxWidth: 390)
            }
        }
    }

    private var assignmentBinding: Binding<ActionID> {
        Binding(
            get: { store.assignments[store.selectedControl] ?? .focusComposer },
            set: { store.assign($0, to: store.selectedControl) }
        )
    }
}

private struct LightingView: View {
    @ObservedObject var store: EmulatorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(
                title: "Lighting",
                subtitle:
                    "Preview the deterministic all-key projection. It is not evidence of physical hardware output."
            )

            HStack(alignment: .top, spacing: 28) {
                PadView(store: store, editingEnabled: false)
                    .frame(maxWidth: 560)
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Preview settings") {
                        VStack(alignment: .leading, spacing: 14) {
                            LabeledContent("Textual state", value: store.lighting.textualState)
                            Slider(value: brightnessBinding, in: 0...1) {
                                Text("Brightness")
                            } minimumValueLabel: {
                                Text("0")
                            } maximumValueLabel: {
                                Text("100")
                            }
                            .disabled(!store.canEditConfiguration)
                            Text("Brightness \(Int(store.brightness * 100)) percent")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Toggle("Reduce motion", isOn: reducedMotionBinding)
                                .disabled(!store.canEditConfiguration)
                            Text("At zero brightness, the textual state remains available.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                    }
                    GroupBox("Scenario") {
                        Picker("Scenario", selection: scenarioBinding) {
                            ForEach(EmulatorScenario.allCases) { scenario in
                                Text(scenario.title).tag(scenario)
                            }
                        }
                        .labelsHidden()
                        .padding(8)
                    }
                }
                .frame(minWidth: 300, maxWidth: 360)
            }

            GroupBox("State legend") {
                VStack(spacing: 10) {
                    LightingLegendRow(color: .white, title: "Default", detail: "Steady white")
                    LightingLegendRow(color: .blue, title: "Plan", detail: "Steady blue")
                    LightingLegendRow(color: .purple, title: "Autopilot", detail: "Steady purple")
                    LightingLegendRow(
                        color: .orange, title: "Needs input", detail: "Amber pulse, steady with reduced motion")
                    LightingLegendRow(
                        color: .green, title: "Completed", detail: "Steady until verified acknowledgement")
                    LightingLegendRow(color: .red, title: "Error", detail: "Steady red")
                    LightingLegendRow(color: .black, title: "Disconnected or unknown", detail: "Key lights off")
                }
                .padding(8)
            }
        }
    }

    private var brightnessBinding: Binding<Double> {
        Binding(get: { store.brightness }, set: { store.setBrightness($0) })
    }

    private var reducedMotionBinding: Binding<Bool> {
        Binding(get: { store.reducedMotion }, set: { store.setReducedMotion($0) })
    }

    private var scenarioBinding: Binding<EmulatorScenario> {
        Binding(get: { store.scenario }, set: { store.selectScenario($0) })
    }
}

private struct ConnectionSettingsView: View {
    @ObservedObject var store: EmulatorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(
                title: "Connection and Settings",
                subtitle: "Live dependencies remain visible and unavailable instead of being simulated as connected."
            )
            GroupBox("Environment") {
                VStack(spacing: 12) {
                    SettingRow("Assembly", value: "Emulator only", status: .available)
                    SettingRow("Preferred terminal", value: "Not configured", status: .unavailable)
                    SettingRow("Copilot CLI", value: "Bridge not installed", status: .unavailable)
                    SettingRow("Creator Micro 2 Pro", value: "HID not opened", status: .unavailable)
                }
                .padding(8)
            }
            GroupBox("Behavior") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Launch at login", isOn: .constant(false))
                        .disabled(true)
                    Text("Unavailable until persistent settings are implemented.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Show notifications", isOn: notificationsBinding)
                        .disabled(!store.canEditConfiguration)
                    Text("The preference is stored locally. Delivery remains unavailable in this milestone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(store.isPaused ? "Resume demo" : "Pause demo") {
                        store.togglePause()
                    }
                }
                .padding(8)
            }
            NoticeBox(
                title: "Pause scope",
                detail:
                    "Pause discards simulated hardware-triggered actions and turns off state lighting. It does not restore a keymap.",
                symbol: "pause.circle"
            )
        }
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { store.notificationsEnabled },
            set: { store.setNotificationsEnabled($0) }
        )
    }
}

private struct ConfigurationView: View {
    @ObservedObject var store: EmulatorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(
                title: "Configuration",
                subtitle: "One personal configuration is stored locally with private, recoverable writes."
            )
            GroupBox("Current demo mapping") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Assigned controls", value: "\(store.assignments.count)")
                    LabeledContent("Persistence", value: store.storageState.label)
                    Text(store.storageStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reset local demo assignments") {
                        store.resetAssignments()
                    }
                    .disabled(!store.canEditConfiguration)
                    if case .recoveryRequired = store.storageState {
                        Button("Preserve malformed file and restore safe defaults") {
                            store.recoverConfigurationWithDefaults()
                        }
                    }
                }
                .padding(8)
            }
            GroupBox("Portable JSON") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        "Import validates every control and preference, previews changes and requires confirmation."
                    )
                    HStack {
                        Button("Import JSON") {
                            store.choosePortableImport()
                        }
                        Button("Export JSON") {
                            store.choosePortableExport()
                        }
                    }
                    .disabled(!store.canManagePortableConfiguration)
                    Text(
                        "Exports exclude terminal paths, CLI hints, recent directories, backups, live IDs and diagnostics."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let notice = store.configurationNotice {
                        Text(notice)
                            .font(.caption)
                    }
                    if let plan = store.pendingImport {
                        ImportPreview(plan: plan)
                        HStack {
                            Button("Apply imported settings") {
                                store.confirmImport()
                            }
                            .disabled(!plan.hasChanges)
                            Button("Cancel") {
                                store.cancelImport()
                            }
                        }
                    }
                }
                .padding(8)
            }
            GroupBox("Original device map") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Backup", value: "Not created; no device was opened")
                    Button("Restore original map") {}
                        .disabled(true)
                    Text("A live write will require a validated backup, preview, explicit consent and read-back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
        }
    }
}

private struct UpdatesView: View {
    @ObservedObject var store: EmulatorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(
                title: "Updates",
                subtitle: "Update discovery and installation are not active in the emulator."
            )
            GroupBox("Installed build") {
                VStack(spacing: 12) {
                    LabeledContent("Version", value: BuildIdentity.version)
                    LabeledContent("Architecture", value: "Apple Silicon")
                    LabeledContent("Signing", value: "Ad-hoc internal build")
                    LabeledContent("Update source", value: "Not configured")
                }
                .padding(8)
            }
            Button("Check for updates") {}
                .disabled(true)
            NoticeBox(
                title: "Installation disabled",
                detail: "No release endpoint, authentication scope or verification key has been qualified.",
                symbol: "lock.shield"
            )
        }
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var store: EmulatorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(
                title: "Diagnostics",
                subtitle:
                    "Demo activity stays in memory; structured operational diagnostics stay local and bounded."
            )
            HStack {
                LabeledContent("Stored demo events", value: "\(store.eventLog.count) of 40 maximum")
                Spacer()
                Button("Clear") {
                    store.clearDiagnostics()
                }
            }
            EventList(entries: store.eventLog, emptyText: "No demo events.")
            GroupBox("Private local diagnostics") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent(
                        "Retention",
                        value: store.diagnosticUsage.map {
                            "\($0.segmentCount) of \($0.maximumSegmentCount) segments, \($0.bytes) bytes"
                        } ?? "No stored segments"
                    )
                    Text("Each segment is limited to 5 MiB. No telemetry or automatic upload is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        "Export includes timestamps, component, operation, bounded outcome/error categories and redacted messages."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Export redacted diagnostics") {
                            store.chooseDiagnosticExport()
                        }
                        Button("Clear private diagnostics") {
                            store.clearPrivateDiagnostics()
                        }
                    }
                    if let notice = store.diagnosticNotice {
                        Text(notice)
                            .font(.caption)
                    }
                }
                .padding(8)
            }
        }
    }
}

private struct ImportPreview: View {
    let plan: ConfigurationImportPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import preview")
                .font(.headline)
            if !plan.hasChanges {
                Text("No portable settings would change.")
                    .foregroundStyle(.secondary)
            }
            ForEach(plan.bindingChanges, id: \.control) { change in
                Text(
                    "\(change.control.displayName): \(change.currentAction.displayName) -> \(change.importedAction.displayName)"
                )
            }
            if plan.brightnessChanged {
                Text(
                    "Brightness: \(percent(plan.baseConfiguration.lighting.brightness)) -> \(percent(plan.portableConfiguration.lighting.brightness))"
                )
            }
            if plan.reducedMotionChanged {
                Text(
                    "Reduced motion: \(yesNo(plan.baseConfiguration.lighting.reducedMotion)) -> \(yesNo(plan.portableConfiguration.lighting.reducedMotion))"
                )
            }
            if plan.notificationsChanged {
                Text(
                    "Notifications: \(yesNo(plan.baseConfiguration.preferences.notificationsEnabled)) -> \(yesNo(plan.portableConfiguration.preferences.notificationsEnabled))"
                )
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value * 100))%"
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "On" : "Off"
    }
}

private struct PageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
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
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Text(value)
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .padding(6)
        }
    }
}

private struct StatePill: View {
    let projection: LightingProjection

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .overlay {
                    Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1)
                }
            Text(projection.textualState)
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(projection.textualState)
    }

    private var color: Color {
        switch projection.color {
        case .off:
            .clear
        case .white:
            .white
        case .blue:
            .blue
        case .purple:
            .purple
        case .red:
            .red
        case .amber:
            .orange
        case .green:
            .green
        }
    }
}

private struct NoticeBox: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EventList: View {
    let entries: [EmulatorLogEntry]
    let emptyText: String

    var body: some View {
        GroupBox("Recent demo activity") {
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title)
                                .font(.callout.weight(.semibold))
                            Text(entry.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        if entry.id != entries.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

private enum SettingStatus {
    case available
    case unavailable
}

private struct SettingRow: View {
    let title: String
    let value: String
    let status: SettingStatus

    init(_ title: String, value: String, status: SettingStatus) {
        self.title = title
        self.value = value
        self.status = status
    }

    var body: some View {
        HStack {
            Image(systemName: status == .available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(status == .available ? .green : .secondary)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LightingLegendRow: View {
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 28, height: 12)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                }
            Text(title)
                .frame(width: 140, alignment: .leading)
            Text(detail)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(detail)")
    }
}
