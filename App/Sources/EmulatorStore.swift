import Combine
import CopilotMicroCore
import Foundation

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
    @Published private(set) var selectedControl: PhysicalControlID = .sessions
    @Published private(set) var assignments: [PhysicalControlID: ActionID]
    @Published private(set) var selectedSessionIndex = 0
    @Published private(set) var highlightedSessionIndex = 0
    @Published private(set) var sessionPickerOpen = false
    @Published private(set) var completionAcknowledged = false
    @Published private(set) var eventLog: [EmulatorLogEntry] = []

    var onPresentationChange: (@MainActor () -> Void)?

    private let identifiers: EmulatorIdentifiers?
    private var nextLogID = 1
    private var simulatedMilliseconds: UInt64 = 0
    private var keyNormalizer = KeyInputNormalizer(wideKeyCoalescingMilliseconds: 50)

    init(configuration: EmulatorConfiguration) {
        self.configuration = configuration
        assignments = Dictionary(
            uniqueKeysWithValues: PhysicalLayout.creatorMicro2Pro.map { ($0.id, $0.defaultAction) }
        )
        identifiers = try? EmulatorIdentifiers()
        appendLog(
            "Demo environment ready",
            "No HID device, Copilot CLI session, extension, terminal automation, permission or network service was opened."
        )
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
        brightness = min(max(value.isFinite ? value : 0, 0), 1)
        presentationDidChange()
    }

    func setReducedMotion(_ enabled: Bool) {
        reducedMotion = enabled
        appendLog(
            enabled ? "Reduced motion enabled" : "Reduced motion disabled",
            enabled
                ? "Busy and attention states use steady colors in the preview."
                : "Busy blink and attention pulse are enabled in the preview."
        )
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
        assignments[control] = action
        appendLog(
            "Assignment edited",
            "\(control.displayName) now shows \(action.displayName). No action was executed."
        )
        presentationDidChange()
    }

    func resetAssignments() {
        assignments = Dictionary(
            uniqueKeysWithValues: PhysicalLayout.creatorMicro2Pro.map { ($0.id, $0.defaultAction) }
        )
        appendLog("Assignments reset", "The local demo mapping was reset. No device was written.")
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
