import Combine
import CopilotMicroBridge
import CopilotMicroTerminal
import Foundation

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
    var onPresentationChange: (@MainActor () -> Void)?

    private let runtime: SessionBridgeRuntime
    private var startupTask: Task<Void, Never>?
    private var started = false
    private var startIdentifier: UUID?

    init(
        bridgeEnabled: Bool,
        runtime: SessionBridgeRuntime = SessionBridgeRuntime(),
        ghosttyAssociations: GhosttyTargetBindingStore = GhosttyTargetBindingStore()
    ) {
        self.bridgeEnabled = bridgeEnabled
        self.runtime = runtime
        self.ghosttyAssociations = ghosttyAssociations
        connectionState = bridgeEnabled ? .inactive : .suppressedForSmoke
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
        runtime.stop()
        connectionState = .inactive
        presentationDidChange()
    }

    func restart() {
        guard bridgeEnabled else { return }
        stop()
        start()
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
        case .sessionUpdated:
            break
        case .disconnected:
            connectionState = .disconnected
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
