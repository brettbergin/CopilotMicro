import CopilotMicroCore
import Foundation

public enum SessionBridgeActivation: Equatable, Sendable {
    case connected
    case reconnected
    case replaced
    case duplicate
}

public enum SessionBridgeUpdate: Equatable, Sendable {
    case heartbeat
    case compatibilityBlocked
    case reconciliationRequired(SessionObservationEventReason)
    case snapshotApplied(capabilitiesChanged: Bool)
    case shuttingDown
    case rejected(SessionBridgeRejection)
}

public enum SessionBridgeRejection: String, Equatable, Sendable {
    case noRegistration
    case staleInstance
    case staleSession
    case staleGeneration
    case outOfOrder
    case invalidPayload
    case unsafeCapability
    case bridgeOwnedPause
    case unexpectedPayload
}

public struct SessionBridgeReconciler: Sendable {
    public static let defaultLivenessTimeoutMilliseconds: UInt64 = 15_000

    public private(set) var registration: IPCRegistration?
    public private(set) var runtimeState = SessionRuntimeState()
    public private(set) var capabilities: [ActionID: Capability] = Self.unknownCapabilities
    public private(set) var hostCapabilities = SessionHostCapabilities.unavailable
    public private(set) var model = SessionModelState.unknown
    public private(set) var compatibility = SessionObservationCompatibility(
        status: .unqualified,
        cliVersion: "unknown",
        sdkVersion: "host-provided",
        reason: "Awaiting an authenticated read-only session snapshot."
    )
    public private(set) var lastSeenMilliseconds: UInt64?

    public let livenessTimeoutMilliseconds: UInt64

    public init(
        livenessTimeoutMilliseconds: UInt64 = Self.defaultLivenessTimeoutMilliseconds
    ) {
        self.livenessTimeoutMilliseconds = livenessTimeoutMilliseconds
    }

    public mutating func activateAuthenticated(
        _ connection: AuthenticatedIPCConnection,
        nowMilliseconds: UInt64
    ) -> SessionBridgeActivation {
        activateAuthenticatedRegistration(
            connection.registration,
            nowMilliseconds: nowMilliseconds
        )
    }

    public mutating func activateAuthenticatedRegistration(
        _ registration: IPCRegistration,
        nowMilliseconds: UInt64
    ) -> SessionBridgeActivation {
        let activation: SessionBridgeActivation
        if let current = self.registration {
            if current.generation == registration.generation {
                return .duplicate
            }
            activation =
                current.instanceID == registration.instanceID
                    && current.sessionID == registration.sessionID
                ? .reconnected : .replaced
        } else {
            activation = .connected
        }

        self.registration = registration
        lastSeenMilliseconds = nowMilliseconds
        capabilities = Self.unknownCapabilities
        hostCapabilities = .unavailable
        model = .unknown
        compatibility = SessionObservationCompatibility(
            status: .unqualified,
            cliVersion: registration.cliVersion,
            sdkVersion: registration.sdkVersion,
            reason: "Awaiting an authenticated read-only session snapshot."
        )
        _ = SessionReducer.reduce(
            &runtimeState,
            .connected(
                LiveBinding(
                    instanceID: registration.instanceID,
                    sessionID: registration.sessionID,
                    generation: registration.generation
                )
            )
        )
        return activation
    }

    public mutating func receive(
        _ frame: IPCFrame,
        nowMilliseconds: UInt64
    ) -> SessionBridgeUpdate {
        guard let registration else {
            return .rejected(.noRegistration)
        }
        guard frame.role == .cliBridge else {
            return .rejected(.unexpectedPayload)
        }
        guard frame.generation == registration.generation else {
            return .rejected(.staleGeneration)
        }

        switch frame.payloadMessageType {
        case .sessionSnapshot:
            return applySnapshot(frame.payload, nowMilliseconds: nowMilliseconds)
        case .sessionEvent:
            return applyEvent(frame.payload, nowMilliseconds: nowMilliseconds)
        case .heartbeat:
            return applyHeartbeat(frame.payload, nowMilliseconds: nowMilliseconds)
        case .action, .actionResult:
            return .rejected(.unexpectedPayload)
        }
    }

    @discardableResult
    public mutating func expireIfNeeded(nowMilliseconds: UInt64) -> Bool {
        guard let lastSeenMilliseconds, nowMilliseconds >= lastSeenMilliseconds else {
            return false
        }
        guard nowMilliseconds - lastSeenMilliseconds > livenessTimeoutMilliseconds else {
            return false
        }
        disconnect()
        return true
    }

    public var actionContext: ActionContext {
        ActionContext(
            binding: runtimeState.binding,
            connection: runtimeState.connection,
            isPaused: runtimeState.isPaused,
            contextRevision: runtimeState.contextRevision,
            capabilities: capabilities,
            pendingRequestIDs: Set(runtimeState.pendingAttention.map(\.requestID)),
            visiblePermissionRequestID: nil
        )
    }

    private mutating func applySnapshot(
        _ data: Data,
        nowMilliseconds: UInt64
    ) -> SessionBridgeUpdate {
        let snapshot: SessionObservationSnapshot
        do {
            snapshot = try SessionObservationPayloadCodec.decodeSnapshot(data)
        } catch {
            return .rejected(.invalidPayload)
        }
        if let identityRejection = validate(snapshot.binding) {
            return .rejected(identityRejection)
        }
        guard !snapshot.paused else {
            return .rejected(.bridgeOwnedPause)
        }
        guard Set(snapshot.capabilities.keys) == Set(ActionID.allCases),
            snapshot.capabilities.values.allSatisfy({ $0.status != .supported })
        else {
            return .rejected(.unsafeCapability)
        }
        lastSeenMilliseconds = nowMilliseconds

        switch snapshot.connection {
        case .connecting, .synchronizing, .reconnecting:
            requireReconciliation()
            return .reconciliationRequired(.lifecycle)
        case .shuttingDown, .disconnected:
            disconnect()
            return .shuttingDown
        case .ready:
            break
        }

        let previousCapabilities = capabilities
        let previousHostCapabilities = hostCapabilities
        guard snapshot.compatibility.isQualifiedReadOnly else {
            requireReconciliation()
            capabilities = snapshot.capabilities
            hostCapabilities = snapshot.hostCapabilities
            compatibility = snapshot.compatibility
            return .compatibilityBlocked
        }
        do {
            let reduction = SessionReducer.reduce(
                &runtimeState,
                .snapshot(
                    SessionEventContext(
                        binding: snapshot.binding,
                        revision: snapshot.contextRevision
                    ),
                    try snapshot.coreSnapshot()
                )
            )
            guard reduction == .applied else {
                return .rejected(rejection(for: reduction))
            }
        } catch {
            return .rejected(.invalidPayload)
        }
        capabilities = snapshot.capabilities
        hostCapabilities = snapshot.hostCapabilities
        model = snapshot.model
        compatibility = snapshot.compatibility
        return .snapshotApplied(
            capabilitiesChanged: capabilities != previousCapabilities
                || hostCapabilities != previousHostCapabilities
        )
    }

    private mutating func applyEvent(
        _ data: Data,
        nowMilliseconds: UInt64
    ) -> SessionBridgeUpdate {
        let event: SessionObservationEvent
        do {
            event = try SessionObservationPayloadCodec.decodeEvent(data)
        } catch {
            return .rejected(.invalidPayload)
        }
        if let identityRejection = validate(event.binding) {
            return .rejected(identityRejection)
        }
        guard event.contextRevision > runtimeState.contextRevision else {
            return .rejected(.outOfOrder)
        }
        lastSeenMilliseconds = nowMilliseconds
        requireReconciliation()
        return .reconciliationRequired(event.reason)
    }

    private mutating func applyHeartbeat(
        _ data: Data,
        nowMilliseconds: UInt64
    ) -> SessionBridgeUpdate {
        let heartbeat: SessionObservationHeartbeat
        do {
            heartbeat = try SessionObservationPayloadCodec.decodeHeartbeat(data)
        } catch {
            return .rejected(.invalidPayload)
        }
        if let identityRejection = validate(heartbeat.binding) {
            return .rejected(identityRejection)
        }
        lastSeenMilliseconds = nowMilliseconds
        if heartbeat.contextRevision > runtimeState.contextRevision {
            requireReconciliation()
            return .reconciliationRequired(.lifecycle)
        }
        return .heartbeat
    }

    private func validate(_ binding: LiveBinding) -> SessionBridgeRejection? {
        guard let registration else {
            return .noRegistration
        }
        guard binding.instanceID == registration.instanceID else {
            return .staleInstance
        }
        guard binding.sessionID == registration.sessionID else {
            return .staleSession
        }
        guard binding.generation == registration.generation else {
            return .staleGeneration
        }
        return nil
    }

    private mutating func requireReconciliation() {
        if let binding = runtimeState.binding {
            _ = SessionReducer.reduce(&runtimeState, .reconciliationRequired(binding))
        }
        capabilities = Self.unknownCapabilities
        hostCapabilities = .unavailable
        model = .unknown
    }

    private mutating func disconnect() {
        registration = nil
        lastSeenMilliseconds = nil
        capabilities = Self.unknownCapabilities
        hostCapabilities = .unavailable
        model = .unknown
        compatibility = SessionObservationCompatibility(
            status: .unqualified,
            cliVersion: "unknown",
            sdkVersion: "host-provided",
            reason: "The authenticated CLI bridge is disconnected."
        )
        _ = SessionReducer.reduce(&runtimeState, .disconnected)
    }

    private func rejection(for reduction: SessionReduction) -> SessionBridgeRejection {
        guard case .rejected(let rejection) = reduction else {
            return .invalidPayload
        }
        switch rejection {
        case .staleInstance:
            return .staleInstance
        case .staleSession:
            return .staleSession
        case .staleGeneration:
            return .staleGeneration
        case .outOfOrder:
            return .outOfOrder
        case .noBinding, .revisionGap, .invalidSnapshot, .invalidWorkState,
            .staleCompletion, .staleError, .duplicatePendingRequest, .tooManyPendingRequests:
            return .invalidPayload
        }
    }

    private static let unknownCapabilities = Dictionary(
        uniqueKeysWithValues: ActionID.allCases.map {
            (
                $0,
                Capability(
                    status: .unknown,
                    reason: "Awaiting an authenticated read-only session snapshot.",
                    gapReference: "I-15"
                )
            )
        }
    )
}
