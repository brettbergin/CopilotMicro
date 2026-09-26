import Combine
import CopilotMicroBridge
import CopilotMicroStorage
import CopilotMicroTerminal
import Foundation

enum LiveBridgeInstallationState: Equatable {
    case suppressedForSmoke
    case checking
    case notInstalled(URL)
    case installing(URL)
    case installed(version: String, destinationURL: URL)
    case updateAvailable(installedVersion: String, packagedVersion: String, destinationURL: URL)
    case blocked(reason: String, destinationURL: URL)
    case failed(String)

    var label: String {
        switch self {
        case .suppressedForSmoke:
            "Suppressed for smoke test"
        case .checking:
            "Checking"
        case .notInstalled:
            "Not installed"
        case .installing:
            "Installing"
        case .installed(let version, _):
            "Installed \(version)"
        case .updateAvailable(_, let packagedVersion, _):
            "Update \(packagedVersion) available"
        case .blocked:
            "Installation blocked"
        case .failed:
            "Installation failed"
        }
    }

    var detail: String {
        switch self {
        case .suppressedForSmoke:
            "No user extension directories are inspected or changed during smoke tests."
        case .checking:
            "Inspecting the owned user-scoped Copilot CLI extension path."
        case .notInstalled(let destinationURL):
            "Ready to install after confirmation at \(destinationURL.path)."
        case .installing(let destinationURL):
            "Installing the reviewed observer at \(destinationURL.path)."
        case .installed(_, let destinationURL):
            "The app-owned observer matches its recorded hashes at \(destinationURL.path)."
        case .updateAvailable(let installedVersion, let packagedVersion, let destinationURL):
            "Owned version \(installedVersion) can be replaced by \(packagedVersion) at \(destinationURL.path)."
        case .blocked(let reason, let destinationURL):
            "\(reason) The app will not change \(destinationURL.path)."
        case .failed(let reason):
            reason
        }
    }

    var destinationURL: URL? {
        switch self {
        case .notInstalled(let destinationURL), .installing(let destinationURL),
            .installed(_, let destinationURL), .updateAvailable(_, _, let destinationURL),
            .blocked(_, let destinationURL):
            destinationURL
        case .suppressedForSmoke, .checking, .failed:
            nil
        }
    }

    var canInstall: Bool {
        switch self {
        case .notInstalled, .updateAvailable:
            true
        case .suppressedForSmoke, .checking, .installing, .installed, .blocked, .failed:
            false
        }
    }

    var isInstalled: Bool {
        if case .installed = self {
            return true
        }
        return false
    }
}

enum LiveCopilotLaunchState: Equatable {
    case inactive
    case opening
    case waitingForRegistration
    case associated
    case failed(String)

    var label: String {
        switch self {
        case .inactive:
            "Not launched by this app"
        case .opening:
            "Opening Ghostty"
        case .waitingForRegistration:
            "Waiting for CLI registration"
        case .associated:
            "CLI associated"
        case .failed:
            "Open Copilot failed"
        }
    }

    var detail: String {
        switch self {
        case .inactive:
            "Choose a project explicitly before the app opens a new Copilot CLI window."
        case .opening:
            "Creating a new Ghostty window with a one-time surface token."
        case .waitingForRegistration:
            "The terminal surface opened; waiting for the installed observer to authenticate."
        case .associated:
            "The authenticated CLI instance is bound to the exact app-created Ghostty surface."
        case .failed(let reason):
            reason
        }
    }
}

enum LiveBridgeConnectionState: Equatable {
    case inactive
    case suppressedForSmoke
    case starting
    case listening
    case connected(SessionBridgeAssociationOutcome)
    case disconnected
    case failed(SessionBridgeRuntimeFailure)

    var label: String {
        switch self {
        case .inactive:
            "Not started"
        case .suppressedForSmoke:
            "Suppressed for smoke test"
        case .starting:
            "Starting"
        case .listening:
            "Listening"
        case .connected(let association):
            switch association {
            case .bound, .reconnected:
                "CLI associated"
            case .pending:
                "CLI association pending"
            case .notRequested:
                "CLI connected, unassociated"
            case .tokenClaimedByAnotherInstance, .unknownToken:
                "CLI association rejected"
            }
        case .disconnected:
            "CLI disconnected"
        case .failed:
            "Bridge failed"
        }
    }

    var detail: String {
        switch self {
        case .inactive:
            "The local Copilot CLI bridge listener has not started."
        case .suppressedForSmoke:
            "Bridge filesystem and socket access are disabled for automated smoke tests."
        case .starting:
            "Preparing the owner-restricted local bridge runtime."
        case .listening:
            "Waiting for the owned Copilot CLI extension to connect."
        case .connected(let association):
            switch association {
            case .bound, .reconnected:
                "The authenticated CLI registration is bound to its app-created terminal surface."
            case .pending:
                "The authenticated CLI registered before its terminal surface finished opening."
            case .notRequested:
                "The authenticated CLI is observable but is not associated with a terminal surface."
            case .tokenClaimedByAnotherInstance:
                "The surface token was already claimed by another CLI instance."
            case .unknownToken:
                "The CLI supplied a surface token that this app did not reserve."
            }
        case .disconnected:
            "The authenticated CLI bridge transport disconnected."
        case .failed(let failure):
            switch failure {
            case .alreadyStarted:
                "A local bridge listener is already active."
            case .bootstrapUnavailable:
                "The private bridge bootstrap material could not be prepared."
            case .listenerUnavailable:
                "The private bridge socket could not be started."
            }
        }
    }

    var isListeningOrConnected: Bool {
        switch self {
        case .listening, .connected:
            true
        case .inactive, .suppressedForSmoke, .starting, .disconnected, .failed:
            false
        }
    }
}

@MainActor
final class LiveBridgeStore: ObservableObject {
    let bridgeEnabled: Bool
    let ghosttyAssociations: GhosttyTargetBindingStore

    @Published private(set) var connectionState: LiveBridgeConnectionState
    @Published private(set) var installationState: LiveBridgeInstallationState
    @Published private(set) var launchState = LiveCopilotLaunchState.inactive
    @Published private(set) var terminalInstallations: [TerminalApplicationDescriptor] = []
    @Published private(set) var cliInstallations: [CLIExecutableDescriptor] = []
    @Published private(set) var selectedTerminal: TerminalPreference?
    @Published private(set) var selectedCLI: CLIExecutablePreference?
    @Published private(set) var terminalSelectionIssue: String?
    @Published private(set) var terminalSelectionBusy = false
    var onPresentationChange: (@MainActor () -> Void)?

    private let runtime: SessionBridgeRuntime
    private let extensionInstaller: BridgeExtensionInstaller
    private let configurationStore: LocalConfigurationStore?
    private var startupTask: Task<Void, Never>?
    private var started = false
    private var startIdentifier: UUID?
    private var installationOperationIdentifier: UUID?
    private var launchOperationIdentifier: UUID?
    private var launchTimeoutTask: Task<Void, Never>?
    private var selectionOperationIdentifier: UUID?

    init(
        bridgeEnabled: Bool,
        bridgeExtensionPackageURL: URL,
        runtime: SessionBridgeRuntime = SessionBridgeRuntime(),
        ghosttyAssociations: GhosttyTargetBindingStore = GhosttyTargetBindingStore(),
        copilotHomeURL: URL = BridgeExtensionInstaller.defaultCopilotHomeURL(),
        applicationSupportRootURL: URL? = nil
    ) {
        self.bridgeEnabled = bridgeEnabled
        self.runtime = runtime
        self.ghosttyAssociations = ghosttyAssociations
        let rootURL =
            applicationSupportRootURL
            ?? (try? IPCBridgeRuntime.defaultRootURL())
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/Copilot Micro",
                isDirectory: true
            )
        extensionInstaller = BridgeExtensionInstaller(
            packageDirectoryURL: bridgeExtensionPackageURL,
            copilotHomeURL: copilotHomeURL,
            applicationSupportRootURL: rootURL
        )
        if let configurationRoot = applicationSupportRootURL
            ?? (try? LocalConfigurationStore.defaultRootURL())
        {
            configurationStore = LocalConfigurationStore(rootURL: configurationRoot)
        } else {
            configurationStore = nil
            terminalSelectionIssue = "The local configuration directory is unavailable."
        }
        connectionState = bridgeEnabled ? .inactive : .suppressedForSmoke
        installationState = bridgeEnabled ? .checking : .suppressedForSmoke
    }

    deinit {
        startupTask?.cancel()
        runtime.stop()
    }

    var runtimeStarted: Bool {
        runtime.isStarted
    }

    func start() {
        guard bridgeEnabled, !started else { return }
        started = true
        let startIdentifier = UUID()
        self.startIdentifier = startIdentifier
        connectionState = .starting
        presentationDidChange()
        refreshInstallationStatus()
        refreshTerminalChoices()
        let runtime = runtime
        let associations = ghosttyAssociations
        let store = self
        startupTask = Task.detached {
            do {
                _ = try await runtime.start(
                    rootURL: IPCBridgeRuntime.defaultRootURL(),
                    associationHandler: { registration in
                        guard let token = registration.surfaceAssociationToken else {
                            return .notRequested
                        }
                        switch await associations.claim(
                            token,
                            for: registration.instanceID
                        ) {
                        case .pending:
                            return .pending
                        case .bound:
                            return .bound
                        case .reconnected:
                            return .reconnected
                        case .tokenClaimedByAnotherInstance:
                            return .tokenClaimedByAnotherInstance
                        case .unknownToken:
                            return .unknownToken
                        }
                    },
                    eventHandler: { event in
                        await store.receive(
                            event,
                            startIdentifier: startIdentifier
                        )
                    }
                )
            } catch let failure as SessionBridgeRuntimeFailure {
                await store.fail(
                    failure,
                    startIdentifier: startIdentifier
                )
            } catch {
                await store.fail(
                    .listenerUnavailable,
                    startIdentifier: startIdentifier
                )
            }
        }
    }

    func stop() {
        guard bridgeEnabled else { return }
        started = false
        startIdentifier = nil
        startupTask?.cancel()
        startupTask = nil
        launchOperationIdentifier = nil
        launchTimeoutTask?.cancel()
        launchTimeoutTask = nil
        selectionOperationIdentifier = nil
        terminalSelectionBusy = false
        runtime.stop()
        connectionState = .inactive
        launchState = .inactive
        presentationDidChange()
    }

    func restart() {
        guard bridgeEnabled else { return }
        stop()
        start()
    }

    var canOpenCopilot: Bool {
        guard bridgeEnabled, runtime.isStarted, installationState.isInstalled else {
            return false
        }
        guard !terminalSelectionBusy, terminalSelectionIssue == nil,
            case .available(let terminal) = terminalSelection,
            terminal.terminal == .ghostty,
            case .available = cliSelection
        else {
            return false
        }
        switch launchState {
        case .inactive, .failed:
            break
        case .opening, .waitingForRegistration, .associated:
            return false
        }
        switch connectionState {
        case .listening, .disconnected:
            return true
        case .inactive, .suppressedForSmoke, .starting, .connected, .failed:
            return false
        }
    }

    var terminalSelection: TerminalPreferenceResolution {
        TerminalPreferenceResolver.resolve(selectedTerminal, in: terminalInstallations)
    }

    var cliSelection: CLIExecutablePreferenceResolution {
        TerminalPreferenceResolver.resolve(selectedCLI, in: cliInstallations)
    }

    func refreshTerminalChoices() {
        guard bridgeEnabled, let configurationStore else { return }
        let identifier = UUID()
        selectionOperationIdentifier = identifier
        terminalSelectionBusy = true
        presentationDidChange()
        let store = self
        Task.detached {
            do {
                let configuration = try await configurationStore.load()
                let terminal = configuration.terminal
                let selectedTerminal: TerminalPreference?
                if let bundleID = terminal.preferredBundleIdentifier,
                    let path = terminal.preferredApplicationPath
                {
                    selectedTerminal = try TerminalPreference(
                        bundleIdentifier: bundleID,
                        applicationPath: path
                    )
                } else {
                    selectedTerminal = nil
                }
                let selectedCLI = try terminal.cliExecutableHint.map {
                    try CLIExecutablePreference(executablePath: $0)
                }
                let applications = TerminalApplicationDiscovery().discover(
                    userSelectedApplicationURLs: selectedTerminal.map {
                        [URL(fileURLWithPath: $0.applicationPath)]
                    } ?? []
                )
                let executables = CLIExecutableDiscovery().discover(
                    userSelectedExecutableURLs: selectedCLI.map {
                        [URL(fileURLWithPath: $0.executablePath)]
                    } ?? []
                )
                await store.receiveTerminalChoices(
                    applications: applications.installations,
                    executables: executables.executables,
                    selectedTerminal: selectedTerminal,
                    selectedCLI: selectedCLI,
                    identifier: identifier
                )
            } catch {
                await store.failTerminalSelection(error, identifier: identifier)
            }
        }
    }

    func selectTerminal(at applicationURL: URL) {
        selectPath(applicationURL, isTerminal: true)
    }

    func selectCLI(at executableURL: URL) {
        selectPath(executableURL, isTerminal: false)
    }

    private func selectPath(_ url: URL, isTerminal: Bool) {
        guard bridgeEnabled, !terminalSelectionBusy, let configurationStore else { return }
        let identifier = UUID()
        selectionOperationIdentifier = identifier
        terminalSelectionBusy = true
        terminalSelectionIssue = nil
        presentationDidChange()
        let store = self
        Task.detached {
            do {
                if isTerminal {
                    _ = try await configurationStore.selectTerminal(at: url)
                } else {
                    _ = try await configurationStore.selectCLI(at: url)
                }
                await store.finishSelection(identifier: identifier)
            } catch {
                await store.failTerminalSelection(error, identifier: identifier)
            }
        }
    }

    private func finishSelection(identifier: UUID) {
        guard selectionOperationIdentifier == identifier else { return }
        refreshTerminalChoices()
    }

    private func receiveTerminalChoices(
        applications: [TerminalApplicationDescriptor],
        executables: [CLIExecutableDescriptor],
        selectedTerminal: TerminalPreference?,
        selectedCLI: CLIExecutablePreference?,
        identifier: UUID
    ) {
        guard selectionOperationIdentifier == identifier else { return }
        selectionOperationIdentifier = nil
        terminalInstallations = applications
        cliInstallations = executables
        self.selectedTerminal = selectedTerminal
        self.selectedCLI = selectedCLI
        terminalSelectionIssue = nil
        terminalSelectionBusy = false
        presentationDidChange()
    }

    private func failTerminalSelection(_ error: Error, identifier: UUID) {
        guard selectionOperationIdentifier == identifier else { return }
        selectionOperationIdentifier = nil
        terminalSelectionBusy = false
        switch error {
        case let error as ConfigurationError:
            terminalSelectionIssue = error.userMessage
        case let error as TerminalApplicationValidationError:
            terminalSelectionIssue = error.localizedDescription
        case let error as CLIExecutableValidationError:
            terminalSelectionIssue = error.localizedDescription
        case let error as TerminalPreferenceError:
            terminalSelectionIssue = error.localizedDescription
        default:
            terminalSelectionIssue = "The terminal selection could not be saved safely."
        }
        presentationDidChange()
    }

    func installExtension() {
        guard bridgeEnabled, installationState.canInstall else { return }
        let operationIdentifier = UUID()
        installationOperationIdentifier = operationIdentifier
        if let destinationURL = installationState.destinationURL {
            installationState = .installing(destinationURL)
        }
        presentationDidChange()
        let installer = extensionInstaller
        let store = self
        Task.detached {
            do {
                let status = try await installer.install(authorization: .userConfirmed)
                await store.receiveInstallationStatus(
                    status,
                    operationIdentifier: operationIdentifier
                )
            } catch {
                await store.failInstallation(
                    error,
                    operationIdentifier: operationIdentifier
                )
            }
        }
    }

    func openCopilot(projectDirectoryURL: URL) {
        guard canOpenCopilot else { return }
        guard case .available(let expectedTerminal) = terminalSelection,
            case .available(let expectedCLI) = cliSelection
        else { return }
        let operationIdentifier = UUID()
        launchOperationIdentifier = operationIdentifier
        launchTimeoutTask?.cancel()
        launchTimeoutTask = nil
        launchState = .opening
        presentationDidChange()
        let installer = extensionInstaller
        let configurationStore = self.configurationStore
        let associations = ghosttyAssociations
        let store = self
        Task.detached {
            do {
                try await installer.requireNoProjectShadow(in: projectDirectoryURL)
                guard let configurationStore else {
                    throw TerminalSelectionError.terminalNotSelected
                }
                let (terminal, cli) = try await configurationStore.resolveSelectedGhosttyLaunch()
                guard terminal == expectedTerminal else {
                    throw TerminalSelectionError.terminalChanged
                }
                guard cli == expectedCLI else {
                    throw TerminalSelectionError.cliChanged
                }
                let adapter = try GhosttyAdapter(
                    installation: terminal,
                    bindings: associations
                )
                let request = try OpenCopilotRequest(
                    terminal: terminal,
                    cliExecutable: cli,
                    projectDirectoryURL: projectDirectoryURL
                )
                let openedSurface = try await adapter.openCopilot(request)
                await store.didOpenCopilot(
                    alreadyAssociated: openedSurface.claimedInstanceID != nil,
                    operationIdentifier: operationIdentifier
                )
            } catch {
                await store.failOpenCopilot(
                    error,
                    operationIdentifier: operationIdentifier
                )
            }
        }
    }

    private func refreshInstallationStatus() {
        let operationIdentifier = UUID()
        installationOperationIdentifier = operationIdentifier
        installationState = .checking
        let installer = extensionInstaller
        let store = self
        Task.detached {
            do {
                let status = try await installer.inspect()
                await store.receiveInstallationStatus(
                    status,
                    operationIdentifier: operationIdentifier
                )
            } catch {
                await store.failInstallation(
                    error,
                    operationIdentifier: operationIdentifier
                )
            }
        }
    }

    private func receiveInstallationStatus(
        _ status: BridgeExtensionInstallationStatus,
        operationIdentifier: UUID
    ) {
        guard installationOperationIdentifier == operationIdentifier else { return }
        installationOperationIdentifier = nil
        switch status {
        case .notInstalled(let destinationURL):
            installationState = .notInstalled(destinationURL)
        case .installed(let version, let destinationURL):
            installationState = .installed(
                version: version,
                destinationURL: destinationURL
            )
        case .updateAvailable(let installedVersion, let packagedVersion, let destinationURL):
            installationState = .updateAvailable(
                installedVersion: installedVersion,
                packagedVersion: packagedVersion,
                destinationURL: destinationURL
            )
        case .collision(let destinationURL):
            installationState = .blocked(
                reason: "An unrelated extension already occupies this path.",
                destinationURL: destinationURL
            )
        case .modified(let destinationURL):
            installationState = .blocked(
                reason: "The previously app-owned extension no longer matches its receipt.",
                destinationURL: destinationURL
            )
        }
        presentationDidChange()
    }

    private func failInstallation(
        _ error: Error,
        operationIdentifier: UUID
    ) {
        guard installationOperationIdentifier == operationIdentifier else { return }
        installationOperationIdentifier = nil
        installationState = .failed(Self.installationFailureMessage(error))
        presentationDidChange()
    }

    private func didOpenCopilot(
        alreadyAssociated: Bool,
        operationIdentifier: UUID
    ) {
        guard launchOperationIdentifier == operationIdentifier else { return }
        launchState = alreadyAssociated ? .associated : .waitingForRegistration
        if alreadyAssociated {
            launchOperationIdentifier = nil
            launchTimeoutTask?.cancel()
            launchTimeoutTask = nil
        } else {
            let store = self
            launchTimeoutTask = Task {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                store.registrationTimedOut(operationIdentifier: operationIdentifier)
            }
        }
        presentationDidChange()
    }

    private func failOpenCopilot(
        _ error: Error,
        operationIdentifier: UUID
    ) {
        guard launchOperationIdentifier == operationIdentifier else { return }
        launchOperationIdentifier = nil
        launchTimeoutTask?.cancel()
        launchTimeoutTask = nil
        launchState = .failed(Self.launchFailureMessage(error))
        presentationDidChange()
    }

    private func receive(
        _ event: SessionBridgeRuntimeEvent,
        startIdentifier: UUID
    ) {
        guard started, self.startIdentifier == startIdentifier else { return }
        switch event {
        case .listening:
            connectionState = .listening
        case .registrationAccepted(_, let association):
            connectionState = .connected(association)
            switch association {
            case .bound, .reconnected:
                launchOperationIdentifier = nil
                launchTimeoutTask?.cancel()
                launchTimeoutTask = nil
                launchState = .associated
            case .pending:
                launchState = .waitingForRegistration
            case .notRequested:
                break
            case .tokenClaimedByAnotherInstance, .unknownToken:
                launchOperationIdentifier = nil
                launchTimeoutTask?.cancel()
                launchTimeoutTask = nil
                launchState = .failed(
                    "The CLI registration did not match the app-created terminal surface."
                )
            }
        case .sessionUpdated:
            break
        case .disconnected:
            connectionState = .disconnected
            if launchState != .inactive {
                launchOperationIdentifier = nil
                launchTimeoutTask?.cancel()
                launchTimeoutTask = nil
                launchState = .failed("The app-created Copilot CLI connection closed.")
            }
        case .connectionFailed:
            connectionState = .listening
        case .stopped:
            started = false
            self.startIdentifier = nil
            startupTask = nil
            connectionState = .disconnected
        case .failed(let failure):
            started = false
            self.startIdentifier = nil
            startupTask = nil
            connectionState = .failed(failure)
        }
        presentationDidChange()
    }

    private func registrationTimedOut(operationIdentifier: UUID) {
        guard launchOperationIdentifier == operationIdentifier else { return }
        launchOperationIdentifier = nil
        launchTimeoutTask = nil
        launchState = .failed(
            "The new Copilot CLI did not register within 60 seconds. "
                + "Check extension loading or name collisions before retrying."
        )
        presentationDidChange()
    }

    private static func installationFailureMessage(_ error: Error) -> String {
        guard let error = error as? BridgeExtensionInstallerError else {
            return "The Copilot CLI bridge installation could not be inspected safely."
        }
        return error.errorDescription
            ?? "The Copilot CLI bridge installation could not be inspected safely."
    }

    private static func launchFailureMessage(_ error: Error) -> String {
        if let error = error as? TerminalSelectionError {
            return error.localizedDescription
        }
        if let error = error as? BridgeExtensionInstallerError {
            return error.errorDescription
                ?? "The selected project cannot safely load the installed bridge."
        }
        if let error = error as? GhosttyAdapterError {
            switch error {
            case .automationDenied:
                return "Allow Copilot Micro to automate Ghostty, then try again."
            case .multipleInstances:
                return "Quit extra Ghostty application processes, then try again."
            case .notRunning, .selectedInstallationNotRunning:
                return "The selected Ghostty installation could not be opened."
            case .unsafeCLIExecutablePath:
                return "The discovered Copilot CLI path is not safe for Ghostty launch."
            case .bindingMissing, .malformedResponse, .scriptFailed, .surfaceMissing,
                .wrongTerminal:
                return "Ghostty could not create and verify an exact Copilot CLI surface."
            }
        }
        return "Copilot could not be opened safely in Ghostty."
    }

    private func fail(
        _ failure: SessionBridgeRuntimeFailure,
        startIdentifier: UUID
    ) {
        guard started, self.startIdentifier == startIdentifier else { return }
        started = false
        self.startIdentifier = nil
        startupTask = nil
        connectionState = .failed(failure)
        presentationDidChange()
    }

    private func presentationDidChange() {
        onPresentationChange?()
    }
}
