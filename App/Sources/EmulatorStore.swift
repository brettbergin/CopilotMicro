import AppKit
import Combine
import CopilotMicroCore
import CopilotMicroStorage
import Foundation
import UniformTypeIdentifiers

enum ManagerArea: String, CaseIterable, Identifiable {
    case overview
    case controls
    case lighting
    case connection
    case configuration
    case updates
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .overview:
            "Overview"
        case .controls:
            "Controls"
        case .lighting:
            "Lighting"
        case .connection:
            "Connection and Settings"
        case .configuration:
            "Configuration"
        case .updates:
            "Updates"
        case .diagnostics:
            "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            "rectangle.grid.2x2"
        case .controls:
            "keyboard"
        case .lighting:
            "lightbulb"
        case .connection:
            "cable.connector"
        case .configuration:
            "doc.badge.gearshape"
        case .updates:
            "arrow.triangle.2.circlepath"
        case .diagnostics:
            "waveform.path.ecg"
        }
    }
}

enum EmulatorScenario: String, CaseIterable, Identifiable {
    case disconnected
    case unknown
    case defaultIdle
    case planWorking
    case autopilotBackground
    case permission
    case question
    case completed
    case error

    var id: Self { self }

    var title: String {
        switch self {
        case .disconnected:
            "Disconnected"
        case .unknown:
            "State unknown"
        case .defaultIdle:
            "Default idle"
        case .planWorking:
            "Plan working"
        case .autopilotBackground:
            "Autopilot background"
        case .permission:
            "Needs permission"
        case .question:
            "Needs input"
        case .completed:
            "Completed while visible"
        case .error:
            "Error"
        }
    }

    var explanation: String {
        switch self {
        case .disconnected:
            "No simulated CLI binding. All key lights are off."
        case .unknown:
            "A binding exists, but authoritative state is not synchronized."
        case .defaultIdle:
            "The simulated selected session is idle in default mode."
        case .planWorking:
            "Foreground work is active in plan mode."
        case .autopilotBackground:
            "Background work remains active in autopilot mode."
        case .permission:
            "An exact simulated permission request is visible and unresolved."
        case .question:
            "A simulated non-permission question needs a response."
        case .completed:
            "Clean work completed while the selected session was already visible."
        case .error:
            "The simulated selected session has an unresolved host error."
        }
    }
}

struct EmulatorLogEntry: Identifiable, Equatable {
    let id: Int
    let title: String
    let detail: String
}

struct EmulatorSession: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

enum LocalStorageState: Equatable {
    case disabledForSmoke
    case loading
    case ready
    case recoveryRequired(String)
    case unavailable(String)

    var label: String {
        switch self {
        case .disabledForSmoke:
            "Disabled for smoke validation"
        case .loading:
            "Loading"
        case .ready:
            "Saved locally"
        case .recoveryRequired:
            "Recovery required"
        case .unavailable:
            "Unavailable"
        }
    }

    var canEdit: Bool {
        switch self {
        case .disabledForSmoke, .ready:
            true
        case .loading, .recoveryRequired, .unavailable:
            false
        }
    }
}

@MainActor
final class EmulatorStore: ObservableObject {
    let configuration: EmulatorConfiguration
    let sessions: [EmulatorSession] = [
        EmulatorSession(id: "session-1", title: "Current project", detail: "github-app-micro2"),
        EmulatorSession(id: "session-2", title: "API cleanup", detail: "simulated archived context"),
        EmulatorSession(id: "session-3", title: "Docs refresh", detail: "simulated idle session"),
    ]

    @Published var selectedArea: ManagerArea = .overview
    @Published private(set) var scenario: EmulatorScenario = .disconnected
    @Published private(set) var isPaused = false
    @Published private(set) var brightness = Brightness.defaultValue.value
    @Published private(set) var reducedMotion = false
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var selectedControl: PhysicalControlID = .sessions
    @Published private(set) var assignments: [PhysicalControlID: ActionID]
    @Published private(set) var selectedSessionIndex = 0
    @Published private(set) var highlightedSessionIndex = 0
    @Published private(set) var sessionPickerOpen = false
    @Published private(set) var completionAcknowledged = false
    @Published private(set) var eventLog: [EmulatorLogEntry] = []
    @Published private(set) var storageState: LocalStorageState
    @Published private(set) var configurationNotice: String?
    @Published private(set) var pendingImport: ConfigurationImportPlan?
    @Published private(set) var configurationMutationInProgress = false
    @Published private(set) var diagnosticUsage: DiagnosticUsage?
    @Published private(set) var diagnosticNotice: String?

    var onPresentationChange: (@MainActor () -> Void)?

    private let localConfigurationStore: LocalConfigurationStore?
    private let diagnosticStore: DiagnosticStore?
    private let identifiers: EmulatorIdentifiers?
    private var storedConfiguration = StoredConfiguration()
    private var persistenceRevision: UInt64 = 0
    private var nextLogID = 1
    private var simulatedMilliseconds: UInt64 = 0
    private var keyNormalizer = KeyInputNormalizer(wideKeyCoalescingMilliseconds: 50)

    init(
        configuration: EmulatorConfiguration,
        localConfigurationStore: LocalConfigurationStore? = nil,
        diagnosticStore: DiagnosticStore? = nil,
        initialStorageError: String? = nil
    ) {
        self.configuration = configuration
        self.localConfigurationStore = localConfigurationStore
        self.diagnosticStore = diagnosticStore
        storedConfiguration = StoredConfiguration()
        assignments = storedConfiguration.bindings
        brightness = storedConfiguration.lighting.brightness
        reducedMotion = storedConfiguration.lighting.reducedMotion
        notificationsEnabled = storedConfiguration.preferences.notificationsEnabled
        if let initialStorageError {
            storageState = .unavailable(initialStorageError)
        } else if localConfigurationStore != nil {
            storageState = .loading
        } else {
            storageState = .disabledForSmoke
        }
        identifiers = try? EmulatorIdentifiers()
        appendLog(
            "Demo environment ready",
            "No HID device, Copilot CLI session, extension, terminal automation, permission or network service was opened."
        )
        if localConfigurationStore != nil {
            Task { [weak self] in
                await self?.loadStoredConfiguration()
            }
        }
    }

    var selectedSession: EmulatorSession {
        sessions[selectedSessionIndex]
    }

    var highlightedSession: EmulatorSession {
        sessions[highlightedSessionIndex]
    }

    var liveServicesDisabled: Bool {
        configuration.mode == .emulator && !configuration.liveIntegrationsEnabled
    }

    var canEditConfiguration: Bool {
        storageState.canEdit && !configurationMutationInProgress
    }

    var canManagePortableConfiguration: Bool {
        storageState == .ready && !configurationMutationInProgress
    }

    var storageStatusDetail: String {
        switch storageState {
        case .disabledForSmoke:
            "Smoke validation uses no application-support files."
        case .loading:
            "Reading the versioned local configuration."
        case .ready:
            "Version 1 settings are stored atomically with user-only permissions."
        case .recoveryRequired(let message), .unavailable(let message):
            message
        }
    }

    var runtimeState: SessionRuntimeState {
        guard let identifiers else {
            return SessionRuntimeState(isPaused: isPaused)
        }

        let base: SessionRuntimeState
        switch scenario {
        case .disconnected:
            base = SessionRuntimeState(isPaused: isPaused)
        case .unknown:
            base = SessionRuntimeState(
                binding: identifiers.binding,
                connection: .synchronizing,
                isPaused: isPaused,
                mode: .unknown,
                work: .unknown
            )
        case .defaultIdle:
            base = readyState(mode: .standard, work: .idle)
        case .planWorking:
            base = readyState(mode: .plan, work: .foregroundActive)
        case .autopilotBackground:
            base = readyState(mode: .autopilot, work: .backgroundActive)
        case .permission:
            base = readyState(
                mode: .standard,
                work: .idle,
                pendingAttention: [
                    PendingAttention(requestID: identifiers.permissionID, kind: .permission)
                ]
            )
        case .question:
            base = readyState(
                mode: .standard,
                work: .idle,
                pendingAttention: [
                    PendingAttention(requestID: identifiers.questionID, kind: .question)
                ]
            )
        case .completed:
            base = readyState(
                mode: .standard,
                work: .idle,
                completion: completionAcknowledged
                    ? nil : CompletionMarker(id: identifiers.completionID, binding: identifiers.binding)
            )
        case .error:
            base = readyState(
                mode: .standard,
                work: .idle,
                failure: SessionFailure(id: identifiers.errorID, category: .host)
            )
        }
        return base
    }

    var lighting: LightingProjection {
        let normalized = brightness.isFinite ? min(max(brightness, 0), 1) : 0
        let value = (try? Brightness(clamping: normalized)) ?? .defaultValue
        return LightingProjector.project(
            runtimeState,
            preferences: LightingPreferences(brightness: value, reducedMotion: reducedMotion)
        )
    }

    var statusDetail: String {
        if isPaused {
            return "Demo paused. Physical actions and state lighting are stopped."
        }
        return scenario.explanation
    }

    var prominentIssue: String {
        "Live CLI and Creator Micro 2 Pro integrations are unavailable in this demo build."
    }

    func selectScenario(_ scenario: EmulatorScenario) {
        self.scenario = scenario
        completionAcknowledged = false
        sessionPickerOpen = false
        appendLog("Scenario changed", scenario.explanation)
        presentationDidChange()
    }

    func setBrightness(_ value: Double) {
        guard canEditConfiguration else {
            return
        }
        brightness = min(max(value.isFinite ? value : 0, 0), 1)
        storedConfiguration.lighting.brightness = brightness
        persistConfiguration(operation: "brightness")
        presentationDidChange()
    }

    func setReducedMotion(_ enabled: Bool) {
        guard canEditConfiguration else {
            return
        }
        reducedMotion = enabled
        storedConfiguration.lighting.reducedMotion = enabled
        appendLog(
            enabled ? "Reduced motion enabled" : "Reduced motion disabled",
            enabled
                ? "Busy and attention states use steady colors in the preview."
                : "Busy blink and attention pulse are enabled in the preview."
        )
        persistConfiguration(operation: "reduced-motion")
        presentationDidChange()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard canEditConfiguration else {
            return
        }
        notificationsEnabled = enabled
        storedConfiguration.preferences.notificationsEnabled = enabled
        appendLog(
            enabled ? "Notifications enabled" : "Notifications disabled",
            "This preference is stored locally. Notification delivery is not implemented yet."
        )
        persistConfiguration(operation: "notifications")
        presentationDidChange()
    }

    func togglePause() {
        isPaused.toggle()
        appendLog(
            isPaused ? "Demo paused" : "Demo resumed",
            isPaused
                ? "Simulated physical actions are discarded; no original mapping is restored."
                : "New simulated gestures are accepted again."
        )
        presentationDidChange()
    }

    func selectControl(_ control: PhysicalControlID) {
        selectedControl = control
        presentationDidChange()
    }

    func assign(_ action: ActionID, to control: PhysicalControlID) {
        guard canEditConfiguration else {
            appendLog("Assignment blocked", storageStatusDetail)
            return
        }
        assignments[control] = action
        storedConfiguration.bindings = assignments
        appendLog(
            "Assignment edited",
            "\(control.displayName) now shows \(action.displayName). No action was executed."
        )
        persistConfiguration(operation: "assignment")
        presentationDidChange()
    }

    func resetAssignments() {
        guard canEditConfiguration else {
            appendLog("Reset blocked", storageStatusDetail)
            return
        }
        assignments = StoredConfiguration.defaultBindings
        storedConfiguration.bindings = assignments
        appendLog("Assignments reset", "The local demo mapping was reset. No device was written.")
        persistConfiguration(operation: "reset-assignments")
        presentationDidChange()
    }

    func simulateSelectedControl() {
        simulateAction(assignments[selectedControl] ?? .focusComposer)
    }

    @discardableResult
    func simulateWideKeyPress() -> Int {
        let sequence: [(Int, Bool)] = [(10, true), (11, true), (10, false), (11, false)]
        var pressCount = 0
        for (rawContact, isPressed) in sequence {
            simulatedMilliseconds += 1
            guard let contact = try? MatrixContactID(rawValue: rawContact) else {
                appendLog("Wide key simulation failed", "The demo matrix contact was invalid.")
                return pressCount
            }
            if keyNormalizer.process(
                contact: contact,
                isPressed: isPressed,
                atMilliseconds: simulatedMilliseconds
            ) == .pressed(.submit) {
                pressCount += 1
                simulateAction(assignments[.submit] ?? .submitComposer)
            }
        }
        appendLog(
            "Wide key contacts coalesced",
            "\(pressCount) simulated press was emitted from contacts 10 and 11."
        )
        presentationDidChange()
        return pressCount
    }

    func simulateDial(delta: Int) {
        guard acceptGesture(named: delta < 0 ? "Dial counterclockwise" : "Dial clockwise") else {
            return
        }
        if !sessionPickerOpen {
            sessionPickerOpen = true
            highlightedSessionIndex = selectedSessionIndex
        }
        highlightedSessionIndex = min(max(highlightedSessionIndex + delta, 0), sessions.count - 1)
        appendLog(
            "Session highlight moved",
            "\(highlightedSession.title) is highlighted but not selected."
        )
        presentationDidChange()
    }

    func simulateJoystick(_ direction: JoystickDirection) {
        guard acceptGesture(named: "Joystick \(direction.rawValue)") else {
            return
        }
        switch direction {
        case .north:
            simulateDial(delta: -1, gestureAlreadyAccepted: true)
        case .south:
            simulateDial(delta: 1, gestureAlreadyAccepted: true)
        case .east:
            if scenario == .permission {
                selectScenario(.defaultIdle)
                appendLog("Approve once simulated", "Only permission-demo-1 was resolved.")
            } else if sessionPickerOpen {
                selectedSessionIndex = highlightedSessionIndex
                sessionPickerOpen = false
                appendLog("Session selection confirmed", selectedSession.title)
            } else {
                appendLog("Confirm rejected", "No verified picker or permission context is active.")
            }
        case .west:
            if scenario == .permission {
                selectScenario(.defaultIdle)
                appendLog("Permission rejection simulated", "Only permission-demo-1 was resolved.")
            } else if sessionPickerOpen {
                highlightedSessionIndex = selectedSessionIndex
                sessionPickerOpen = false
                appendLog("Picker closed", "The selected session did not change.")
            } else {
                appendLog("Back rejected", "No verified picker context is active.")
            }
        }
        presentationDidChange()
    }

    func acknowledgeCompletion() {
        guard scenario == .completed, !completionAcknowledged else {
            appendLog("Acknowledgement ignored", "There is no unacknowledged clean completion.")
            return
        }
        completionAcknowledged = true
        appendLog("Completion acknowledged", "A verified simulated interaction returned lighting to idle.")
        presentationDidChange()
    }

    func clearDiagnostics() {
        eventLog.removeAll()
        appendLog("Demo diagnostics cleared", "Only the bounded in-memory demo event list was removed.")
        presentationDidChange()
    }

    func choosePortableImport() {
        guard storageState == .ready else {
            configurationNotice = storageStatusDetail
            return
        }
        pendingImport = nil
        let panel = NSOpenPanel()
        panel.title = "Import Copilot Micro Configuration"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            Task { @MainActor [weak self] in
                await self?.prepareImport(from: url)
            }
        }
    }

    func cancelImport() {
        pendingImport = nil
        configurationNotice = "Import canceled. The active configuration was not changed."
        presentationDidChange()
    }

    func confirmImport() {
        guard let localConfigurationStore, let plan = pendingImport else {
            return
        }
        guard canManagePortableConfiguration else {
            configurationNotice = storageStatusDetail
            return
        }
        guard storedConfiguration == plan.baseConfiguration else {
            pendingImport = nil
            reportConfigurationOperationError(
                .staleImportPreview,
                operation: "import"
            )
            return
        }
        pendingImport = nil
        let revision = nextPersistenceRevision()
        configurationMutationInProgress = true
        Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.configurationMutationInProgress = false
            }
            do {
                let imported = try await localConfigurationStore.applyImport(
                    plan,
                    revision: revision
                )
                guard self.persistenceRevision == revision else {
                    self.configurationNotice =
                        "The import was superseded by newer local settings."
                    self.presentationDidChange()
                    return
                }
                self.applyStoredConfiguration(imported)
                self.configurationNotice =
                    "Imported settings were saved. The previous configuration remains recoverable."
                self.appendLog(
                    "Portable configuration imported",
                    "Validated settings were applied after explicit confirmation."
                )
                self.recordDiagnostic(
                    component: .configuration,
                    operation: "import",
                    outcome: .succeeded
                )
                self.presentationDidChange()
            } catch let error as ConfigurationError {
                self.reportConfigurationOperationError(error, operation: "import")
            } catch {
                self.reportConfigurationOperationError(.fileSystem, operation: "import")
            }
        }
    }

    func choosePortableExport() {
        guard let localConfigurationStore, storageState == .ready else {
            configurationNotice = storageStatusDetail
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Copilot Micro Configuration"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "copilot-micro-configuration.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                do {
                    try await localConfigurationStore.writePortable(
                        self.storedConfiguration,
                        to: url
                    )
                    self.configurationNotice =
                        "Portable configuration exported. Machine paths and private diagnostics were excluded."
                    self.appendLog(
                        "Portable configuration exported",
                        "Only allowlisted portable settings were written."
                    )
                    self.recordDiagnostic(
                        component: .configuration,
                        operation: "export",
                        outcome: .succeeded
                    )
                    self.presentationDidChange()
                } catch let error as ConfigurationError {
                    self.reportConfigurationOperationError(error, operation: "export")
                } catch {
                    self.reportConfigurationOperationError(.fileSystem, operation: "export")
                }
            }
        }
    }

    func recoverConfigurationWithDefaults() {
        guard let localConfigurationStore else {
            return
        }
        let revision = nextPersistenceRevision()
        Task { [weak self] in
            do {
                let recovered =
                    try await localConfigurationStore
                    .replaceWithDefaultsPreservingOriginal(revision: revision)
                self?.applyStoredConfiguration(recovered)
                self?.storageState = .ready
                self?.configurationNotice =
                    "Safe defaults were restored. The malformed original remains in local recovery storage."
                self?.appendLog(
                    "Configuration recovered",
                    "Defaults were activated without discarding the malformed original."
                )
                self?.recordDiagnostic(
                    component: .configuration,
                    operation: "recover",
                    outcome: .succeeded
                )
                self?.presentationDidChange()
            } catch let error as ConfigurationError {
                self?.handleConfigurationFailure(error, recoveryRequired: true)
            } catch {
                self?.handleConfigurationFailure(.fileSystem, recoveryRequired: true)
            }
        }
    }

    func chooseDiagnosticExport() {
        guard let diagnosticStore else {
            diagnosticNotice = "Private diagnostics are disabled for smoke validation."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Redacted Copilot Micro Diagnostics"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "copilot-micro-diagnostics.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            Task { @MainActor [weak self] in
                do {
                    try await diagnosticStore.writeExport(to: url)
                    self?.diagnosticNotice =
                        "Redacted diagnostics exported locally. Nothing was uploaded."
                    await self?.refreshDiagnosticUsage()
                } catch let error as DiagnosticError {
                    self?.diagnosticNotice = error.userMessage
                } catch {
                    self?.diagnosticNotice = DiagnosticError.fileSystem.userMessage
                }
            }
        }
    }

    func clearPrivateDiagnostics() {
        guard let diagnosticStore else {
            diagnosticNotice = "Private diagnostics are disabled for smoke validation."
            return
        }
        Task { [weak self] in
            do {
                try await diagnosticStore.clear()
                self?.diagnosticNotice =
                    "Private diagnostics were cleared. Configuration recovery files were preserved."
                await self?.refreshDiagnosticUsage()
            } catch let error as DiagnosticError {
                self?.diagnosticNotice = error.userMessage
            } catch {
                self?.diagnosticNotice = DiagnosticError.fileSystem.userMessage
            }
        }
    }

    private func loadStoredConfiguration() async {
        guard let localConfigurationStore else {
            return
        }
        do {
            let loaded = try await localConfigurationStore.load()
            applyStoredConfiguration(loaded)
            storageState = .ready
            configurationNotice = "Local configuration loaded."
            appendLog(
                "Local configuration loaded",
                "Version 1 settings are active. Live integrations remain disabled."
            )
            recordDiagnostic(
                component: .configuration,
                operation: "load",
                outcome: .succeeded
            )
            await refreshDiagnosticUsage()
            presentationDidChange()
        } catch let error as ConfigurationError {
            handleConfigurationFailure(error, recoveryRequired: error != .fileSystem)
        } catch {
            handleConfigurationFailure(.fileSystem, recoveryRequired: false)
        }
    }

    private func prepareImport(from url: URL) async {
        guard let localConfigurationStore else {
            return
        }
        do {
            let revision = nextPersistenceRevision()
            _ = try await localConfigurationStore.save(
                storedConfiguration,
                revision: revision
            )
            pendingImport = try await localConfigurationStore.previewImport(
                from: url,
                against: storedConfiguration
            )
            configurationNotice =
                pendingImport?.hasChanges == true
                ? "Review every change before applying the import."
                : "The imported portable settings match the active configuration."
            recordDiagnostic(
                component: .configuration,
                operation: "preview-import",
                outcome: .succeeded
            )
            presentationDidChange()
        } catch let error as ConfigurationError {
            reportConfigurationOperationError(error, operation: "preview-import")
        } catch {
            reportConfigurationOperationError(.fileSystem, operation: "preview-import")
        }
    }

    private func applyStoredConfiguration(_ configuration: StoredConfiguration) {
        storedConfiguration = configuration
        assignments = configuration.bindings
        brightness = configuration.lighting.brightness
        reducedMotion = configuration.lighting.reducedMotion
        notificationsEnabled = configuration.preferences.notificationsEnabled
    }

    private func persistConfiguration(operation: String) {
        guard let localConfigurationStore, storageState == .ready else {
            return
        }
        let snapshot = storedConfiguration
        let revision = nextPersistenceRevision()
        Task { [weak self] in
            do {
                guard
                    try await localConfigurationStore.save(
                        snapshot,
                        revision: revision
                    )
                else {
                    return
                }
                self?.configurationNotice = "Changes saved locally."
                self?.recordDiagnostic(
                    component: .configuration,
                    operation: operation,
                    outcome: .succeeded
                )
                self?.presentationDidChange()
            } catch let error as ConfigurationError {
                self?.handleConfigurationFailure(error, recoveryRequired: false)
            } catch {
                self?.handleConfigurationFailure(.fileSystem, recoveryRequired: false)
            }
        }
    }

    private func nextPersistenceRevision() -> UInt64 {
        let (next, overflow) = persistenceRevision.addingReportingOverflow(1)
        persistenceRevision = overflow ? 1 : next
        return persistenceRevision
    }

    private func handleConfigurationFailure(
        _ error: ConfigurationError,
        recoveryRequired: Bool
    ) {
        storageState =
            recoveryRequired
            ? .recoveryRequired(error.userMessage)
            : .unavailable(error.userMessage)
        configurationNotice = error.userMessage
        appendLog("Configuration error", error.userMessage)
        recordDiagnostic(
            component: .configuration,
            operation: recoveryRequired ? "load" : "save",
            outcome: .failed,
            errorCategory: error == .messageTooLarge ? .invalidInput : .fileSystem,
            message: error.userMessage
        )
        presentationDidChange()
    }

    private func reportConfigurationOperationError(
        _ error: ConfigurationError,
        operation: String
    ) {
        configurationNotice = error.userMessage
        appendLog("Configuration operation rejected", error.userMessage)
        recordDiagnostic(
            component: .configuration,
            operation: operation,
            outcome: .failed,
            errorCategory: error == .fileSystem ? .fileSystem : .invalidInput,
            message: error.userMessage
        )
        presentationDidChange()
    }

    private func recordDiagnostic(
        component: DiagnosticComponent,
        operation: String,
        outcome: DiagnosticOutcome,
        errorCategory: DiagnosticErrorCategory? = nil,
        message: String? = nil
    ) {
        guard let diagnosticStore else {
            return
        }
        let event: DiagnosticEvent
        do {
            event = try DiagnosticEvent(
                timestamp: Date(),
                component: component,
                operation: operation,
                capabilityVersion: "storage-v1",
                outcome: outcome,
                errorCategory: errorCategory,
                message: message
            )
        } catch let error as DiagnosticError {
            diagnosticNotice = error.userMessage
            return
        } catch {
            diagnosticNotice = DiagnosticError.invalidEvent.userMessage
            return
        }
        Task { [weak self] in
            do {
                try await diagnosticStore.append(event)
                await self?.refreshDiagnosticUsage()
            } catch let error as DiagnosticError {
                self?.diagnosticNotice = error.userMessage
            } catch {
                self?.diagnosticNotice = DiagnosticError.fileSystem.userMessage
            }
        }
    }

    private func refreshDiagnosticUsage() async {
        guard let diagnosticStore else {
            diagnosticUsage = nil
            return
        }
        do {
            diagnosticUsage = try await diagnosticStore.usage()
        } catch let error as DiagnosticError {
            diagnosticNotice = error.userMessage
        } catch {
            diagnosticNotice = DiagnosticError.fileSystem.userMessage
        }
    }

    static func validateDemoJourney(configuration: EmulatorConfiguration) -> Bool {
        let store = EmulatorStore(configuration: configuration)
        guard store.liveServicesDisabled, ManagerArea.allCases.count == 7,
            store.assignments.count == PhysicalControlID.allCases.count
        else {
            return false
        }
        store.selectScenario(.planWorking)
        guard store.lighting.semanticState == .working, store.lighting.color == .blue,
            store.lighting.animation == .blink
        else {
            return false
        }
        store.setReducedMotion(true)
        guard store.lighting.animation == .steady else {
            return false
        }
        store.selectScenario(.completed)
        guard store.lighting.semanticState == .completed else {
            return false
        }
        store.acknowledgeCompletion()
        guard store.lighting.semanticState == .idle else {
            return false
        }
        guard store.simulateWideKeyPress() == 1 else {
            return false
        }
        let scenario = store.scenario
        store.assign(.focusComposer, to: .sessions)
        return store.scenario == scenario
            && store.assignments[.sessions] == .focusComposer
            && store.eventLog.count <= 40
    }

    private func readyState(
        mode: SessionMode,
        work: WorkState,
        pendingAttention: Set<PendingAttention> = [],
        failure: SessionFailure? = nil,
        completion: CompletionMarker? = nil
    ) -> SessionRuntimeState {
        guard let identifiers else {
            return SessionRuntimeState(isPaused: isPaused)
        }
        return SessionRuntimeState(
            binding: identifiers.binding,
            connection: .ready,
            isPaused: isPaused,
            contextRevision: 1,
            mode: .known(mode),
            work: work,
            pendingAttention: pendingAttention,
            failure: failure,
            unacknowledgedCompletion: completion
        )
    }

    private func simulateAction(_ action: ActionID) {
        guard acceptGesture(named: action.displayName) else {
            return
        }
        switch action {
        case .openSessionList:
            sessionPickerOpen = true
            highlightedSessionIndex = selectedSessionIndex
            appendLog("Native session list simulated", "Use Dial or Joystick to move the highlight.")
        case .previousSession:
            selectSession(offset: -1)
        case .nextSession:
            selectSession(offset: 1)
        case .cycleMode:
            switch scenario {
            case .defaultIdle:
                selectScenario(.planWorking)
            case .planWorking:
                selectScenario(.autopilotBackground)
            default:
                selectScenario(.defaultIdle)
            }
        case .cancelForeground:
            if scenario == .planWorking || scenario == .autopilotBackground {
                selectScenario(.defaultIdle)
                appendLog("Foreground cancellation simulated", "The result is idle, not completed.")
            } else {
                appendLog("Cancel rejected", "No simulated foreground task is active.")
            }
        case .submitComposer:
            selectScenario(.planWorking)
            appendLog("Draft submission simulated", "One existing demo draft was submitted once.")
        case .focusComposer:
            appendLog("Composer focus simulated", "Focus only; no text was submitted.")
        case .approvePermissionOnce:
            if scenario == .permission {
                simulateJoystick(.east)
            } else {
                appendLog("Approval rejected", "No exact visible permission request is active.")
            }
        case .rejectPermission:
            if scenario == .permission {
                simulateJoystick(.west)
            } else {
                appendLog("Rejection rejected", "No exact visible permission request is active.")
            }
        case .confirmPicker:
            simulateJoystick(.east)
        case .backPicker:
            simulateJoystick(.west)
        case .createSession, .archiveSession, .selectModel, .selectEffort, .voice:
            appendLog(
                "\(action.displayName) simulated",
                "The demo records the request but cannot claim a live CLI result."
            )
        }
        presentationDidChange()
    }

    private func selectSession(offset: Int) {
        selectedSessionIndex = min(max(selectedSessionIndex + offset, 0), sessions.count - 1)
        highlightedSessionIndex = selectedSessionIndex
        appendLog("Selected session changed", selectedSession.title)
    }

    private func simulateDial(delta: Int, gestureAlreadyAccepted: Bool) {
        if !gestureAlreadyAccepted {
            simulateDial(delta: delta)
            return
        }
        if !sessionPickerOpen {
            sessionPickerOpen = true
            highlightedSessionIndex = selectedSessionIndex
        }
        highlightedSessionIndex = min(max(highlightedSessionIndex + delta, 0), sessions.count - 1)
        appendLog(
            "Session highlight moved",
            "\(highlightedSession.title) is highlighted but not selected."
        )
    }

    private func acceptGesture(named name: String) -> Bool {
        guard !isPaused else {
            appendLog("\(name) discarded", "Demo pause prevents simulated physical actions.")
            presentationDidChange()
            return false
        }
        return true
    }

    private func appendLog(_ title: String, _ detail: String) {
        eventLog.insert(EmulatorLogEntry(id: nextLogID, title: title, detail: detail), at: 0)
        nextLogID += 1
        if eventLog.count > 40 {
            eventLog.removeLast(eventLog.count - 40)
        }
    }

    private func presentationDidChange() {
        onPresentationChange?()
    }
}

private struct EmulatorIdentifiers {
    let binding: LiveBinding
    let permissionID: RequestID
    let questionID: RequestID
    let completionID: CompletionID
    let errorID: ErrorID

    init() throws {
        binding = try LiveBinding(
            instanceID: CLIInstanceID(rawValue: "emulator-cli-instance"),
            sessionID: SessionID(rawValue: "session-1"),
            generation: ConnectionGeneration(rawValue: "emulator-generation-1")
        )
        permissionID = try RequestID(rawValue: "permission-demo-1")
        questionID = try RequestID(rawValue: "question-demo-1")
        completionID = try CompletionID(rawValue: "completion-demo-1")
        errorID = try ErrorID(rawValue: "error-demo-1")
    }
}

extension WorkState {
    fileprivate static var foregroundActive: WorkState {
        (try? WorkState(foregroundActive: true, backgroundCount: 0, queuedCount: 0)) ?? .unknown
    }

    fileprivate static var backgroundActive: WorkState {
        (try? WorkState(foregroundActive: false, backgroundCount: 1, queuedCount: 0)) ?? .unknown
    }
}

extension PhysicalControlID {
    var displayName: String {
        switch self {
        case .sessions:
            "Sessions"
        case .newSession:
            "New session"
        case .previous:
            "Previous"
        case .next:
            "Next"
        case .archive:
            "Archive"
        case .mode:
            "Mode"
        case .model:
            "Model"
        case .effort:
            "Effort"
        case .voice:
            "Voice"
        case .cancel:
            "Cancel"
        case .submit:
            "Submit"
        case .focus:
            "Focus"
        }
    }
}

extension ActionID {
    var displayName: String {
        switch self {
        case .openSessionList:
            "Open Sessions"
        case .createSession:
            "New Session"
        case .previousSession:
            "Previous Session"
        case .nextSession:
            "Next Session"
        case .archiveSession:
            "Archive Session"
        case .cycleMode:
            "Cycle Mode"
        case .selectModel:
            "Choose Model"
        case .selectEffort:
            "Choose Effort"
        case .voice:
            "CLI Voice"
        case .cancelForeground:
            "Cancel Foreground Work"
        case .submitComposer:
            "Submit Composer"
        case .focusComposer:
            "Focus Composer"
        case .confirmPicker:
            "Confirm Picker"
        case .backPicker:
            "Back from Picker"
        case .approvePermissionOnce:
            "Approve Once"
        case .rejectPermission:
            "Reject Permission"
        }
    }
}
