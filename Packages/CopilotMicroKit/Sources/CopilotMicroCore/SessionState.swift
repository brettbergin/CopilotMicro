public enum SessionMode: String, Codable, CaseIterable, Sendable {
    case standard = "default"
    case plan
    case autopilot
}

public enum SessionModeState: Equatable, Sendable {
    case unknown
    case known(SessionMode)
}

public struct WorkState: Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case negativeCount
    }

    public let isKnown: Bool
    public let foregroundActive: Bool
    public let backgroundCount: Int
    public let queuedCount: Int

    public static let unknown = WorkState(
        isKnown: false,
        foregroundActive: false,
        backgroundCount: 0,
        queuedCount: 0
    )
    public static let idle = WorkState(
        isKnown: true,
        foregroundActive: false,
        backgroundCount: 0,
        queuedCount: 0
    )

    public init(foregroundActive: Bool, backgroundCount: Int, queuedCount: Int) throws {
        guard backgroundCount >= 0, queuedCount >= 0 else {
            throw ValidationError.negativeCount
        }
        self.init(
            isKnown: true,
            foregroundActive: foregroundActive,
            backgroundCount: backgroundCount,
            queuedCount: queuedCount
        )
    }

    public var hasActiveWork: Bool {
        isKnown && (foregroundActive || backgroundCount > 0 || queuedCount > 0)
    }

    private init(isKnown: Bool, foregroundActive: Bool, backgroundCount: Int, queuedCount: Int) {
        self.isKnown = isKnown
        self.foregroundActive = foregroundActive
        self.backgroundCount = backgroundCount
        self.queuedCount = queuedCount
    }
}

public enum AttentionKind: String, Codable, CaseIterable, Sendable {
    case permission
    case question
    case elicitation
    case planDecision
}

public struct PendingAttention: Codable, Equatable, Hashable, Sendable {
    public let requestID: RequestID
    public let kind: AttentionKind

    public init(requestID: RequestID, kind: AttentionKind) {
        self.requestID = requestID
        self.kind = kind
    }
}

public struct AttentionState: Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case negativeCount
    }

    public let isKnown: Bool
    public let permissionCount: Int
    public let otherCount: Int

    public static let unknown = AttentionState(
        isKnown: false,
        permissionCount: 0,
        otherCount: 0
    )
    public static let none = AttentionState(
        isKnown: true,
        permissionCount: 0,
        otherCount: 0
    )

    public init(permissionCount: Int, otherCount: Int) throws {
        guard permissionCount >= 0, otherCount >= 0 else {
            throw ValidationError.negativeCount
        }
        self.init(
            isKnown: true,
            permissionCount: permissionCount,
            otherCount: otherCount
        )
    }

    public var requiresAttention: Bool {
        isKnown && (permissionCount > 0 || otherCount > 0)
    }

    private init(isKnown: Bool, permissionCount: Int, otherCount: Int) {
        self.isKnown = isKnown
        self.permissionCount = permissionCount
        self.otherCount = otherCount
    }
}

public enum SessionErrorCategory: String, Codable, CaseIterable, Sendable {
    case host
    case integration
    case protocolViolation
    case device
}

public struct SessionFailure: Equatable, Sendable {
    public let id: ErrorID
    public let category: SessionErrorCategory

    public init(id: ErrorID, category: SessionErrorCategory) {
        self.id = id
        self.category = category
    }
}

public struct CompletionMarker: Equatable, Sendable {
    public let id: CompletionID
    public let binding: LiveBinding

    public init(id: CompletionID, binding: LiveBinding) {
        self.id = id
        self.binding = binding
    }
}

public enum AcknowledgementSource: String, Codable, CaseIterable, Sendable {
    case nativeSessionSelection
    case verifiedScopedInteraction
    case successfulSessionAction
}

public struct CompletionAcknowledgement: Equatable, Sendable {
    public let completionID: CompletionID
    public let binding: LiveBinding
    public let source: AcknowledgementSource

    public init(completionID: CompletionID, binding: LiveBinding, source: AcknowledgementSource) {
        self.completionID = completionID
        self.binding = binding
        self.source = source
    }
}

public struct SessionEventContext: Equatable, Sendable {
    public let binding: LiveBinding
    public let revision: UInt64

    public init(binding: LiveBinding, revision: UInt64) {
        self.binding = binding
        self.revision = revision
    }
}

public struct SessionSnapshot: Equatable, Sendable {
    public static let maximumPendingAttention = 128

    public enum ValidationError: Error, Equatable, Sendable {
        case terminalStateWithoutKnownWork
        case completionDuringActiveWork
        case conflictingTerminalState
        case tooManyPendingRequests
        case duplicatePendingRequest
    }

    public let mode: SessionModeState
    public let work: WorkState
    public let pendingAttention: Set<PendingAttention>
    public let attention: AttentionState
    public let failure: SessionFailure?
    public let unacknowledgedCompletionID: CompletionID?

    public init(
        mode: SessionModeState,
        work: WorkState,
        pendingAttention: Set<PendingAttention> = [],
        attention: AttentionState = .none,
        failure: SessionFailure? = nil,
        unacknowledgedCompletionID: CompletionID? = nil
    ) {
        self.mode = mode
        self.work = work
        self.pendingAttention = pendingAttention
        self.attention = attention
        self.failure = failure
        self.unacknowledgedCompletionID = unacknowledgedCompletionID
    }

    public func validate() throws {
        guard pendingAttention.count <= Self.maximumPendingAttention else {
            throw ValidationError.tooManyPendingRequests
        }
        guard Set(pendingAttention.map(\.requestID)).count == pendingAttention.count else {
            throw ValidationError.duplicatePendingRequest
        }
        if !work.isKnown, failure != nil || unacknowledgedCompletionID != nil {
            throw ValidationError.terminalStateWithoutKnownWork
        }
        if work.hasActiveWork, unacknowledgedCompletionID != nil {
            throw ValidationError.completionDuringActiveWork
        }
        if failure != nil, unacknowledgedCompletionID != nil {
            throw ValidationError.conflictingTerminalState
        }
    }
}

public struct SessionRuntimeState: Equatable, Sendable {
    public var binding: LiveBinding?
    public var connection: ConnectionState
    public var isPaused: Bool
    public var contextRevision: UInt64
    public var mode: SessionModeState
    public var work: WorkState
    public var pendingAttention: Set<PendingAttention>
    public var attention: AttentionState
    public var failure: SessionFailure?
    public var unacknowledgedCompletion: CompletionMarker?

    public init(
        binding: LiveBinding? = nil,
        connection: ConnectionState = .disconnected,
        isPaused: Bool = false,
        contextRevision: UInt64 = 0,
        mode: SessionModeState = .unknown,
        work: WorkState = .unknown,
        pendingAttention: Set<PendingAttention> = [],
        attention: AttentionState = .none,
        failure: SessionFailure? = nil,
        unacknowledgedCompletion: CompletionMarker? = nil
    ) {
        self.binding = binding
        self.connection = connection
        self.isPaused = isPaused
        self.contextRevision = contextRevision
        self.mode = mode
        self.work = work
        self.pendingAttention = pendingAttention
        self.attention = attention
        self.failure = failure
        self.unacknowledgedCompletion = unacknowledgedCompletion
    }
}

public enum SessionEvent: Equatable, Sendable {
    case connected(LiveBinding)
    case snapshot(SessionEventContext, SessionSnapshot)
    case workStarted(SessionEventContext, WorkState)
    case workCompleted(SessionEventContext, CompletionID)
    case workAborted(SessionEventContext)
    case workFailed(SessionEventContext, SessionFailure)
    case attentionAdded(SessionEventContext, PendingAttention)
    case attentionResolved(SessionEventContext, RequestID)
    case errorRecovered(SessionEventContext, ErrorID)
    case acknowledge(CompletionAcknowledgement)
    case reconciliationRequired(LiveBinding)
    case paused
    case resume
    case disconnected
}

public enum SessionEventRejection: String, Equatable, Sendable {
    case noBinding
    case staleInstance
    case staleSession
    case staleGeneration
    case outOfOrder
    case revisionGap
    case invalidSnapshot
    case invalidWorkState
    case staleCompletion
    case staleError
    case duplicatePendingRequest
    case tooManyPendingRequests
}

public enum SessionReduction: Equatable, Sendable {
    case applied
    case rejected(SessionEventRejection)
}

public enum SessionReducer {
    @discardableResult
    public static func reduce(_ state: inout SessionRuntimeState, _ event: SessionEvent) -> SessionReduction {
        switch event {
        case .connected(let binding):
            let isPaused = state.isPaused
            state = SessionRuntimeState(
                binding: binding,
                connection: .synchronizing,
                isPaused: isPaused,
                mode: .unknown,
                work: .unknown
            )
            return .applied
        case .snapshot(let context, let snapshot):
            guard let rejection = validateSnapshot(context, against: state) else {
                guard (try? snapshot.validate()) != nil else {
                    return .rejected(.invalidSnapshot)
                }
                state.connection = .ready
                state.contextRevision = context.revision
                state.mode = snapshot.mode
                state.work = snapshot.work
                state.pendingAttention = snapshot.pendingAttention
                state.attention = snapshot.attention
                state.failure = snapshot.failure
                state.unacknowledgedCompletion = snapshot.unacknowledgedCompletionID.map {
                    CompletionMarker(id: $0, binding: context.binding)
                }
                return .applied
            }
            return .rejected(rejection)
        case .workStarted(let context, let work):
            guard let rejection = validateIncrement(context, against: &state) else {
                guard work.isKnown, work.hasActiveWork else {
                    return .rejected(.invalidWorkState)
                }
                state.contextRevision = context.revision
                state.work = work
                state.failure = nil
                state.unacknowledgedCompletion = nil
                return .applied
            }
            return .rejected(rejection)
        case .workCompleted(let context, let completionID):
            guard let rejection = validateIncrement(context, against: &state) else {
                let completedRealWork = state.work.hasActiveWork
                state.contextRevision = context.revision
                state.work = .idle
                state.failure = nil
                state.unacknowledgedCompletion =
                    completedRealWork
                    ? CompletionMarker(id: completionID, binding: context.binding) : nil
                return .applied
            }
            return .rejected(rejection)
        case .workAborted(let context):
            guard let rejection = validateIncrement(context, against: &state) else {
                state.contextRevision = context.revision
                state.work = .idle
                state.unacknowledgedCompletion = nil
                return .applied
            }
            return .rejected(rejection)
        case .workFailed(let context, let failure):
            guard let rejection = validateIncrement(context, against: &state) else {
                state.contextRevision = context.revision
                state.work = .idle
                state.failure = failure
                state.unacknowledgedCompletion = nil
                return .applied
            }
            return .rejected(rejection)
        case .attentionAdded(let context, let attention):
            guard let rejection = validateIncrement(context, against: &state) else {
                guard !state.pendingAttention.contains(where: { $0.requestID == attention.requestID }) else {
                    return .rejected(.duplicatePendingRequest)
                }
                guard state.pendingAttention.count < SessionSnapshot.maximumPendingAttention else {
                    return .rejected(.tooManyPendingRequests)
                }
                state.contextRevision = context.revision
                state.pendingAttention.insert(attention)
                return .applied
            }
            return .rejected(rejection)
        case .attentionResolved(let context, let requestID):
            guard let rejection = validateIncrement(context, against: &state) else {
                state.contextRevision = context.revision
                state.pendingAttention = Set(
                    state.pendingAttention.filter { $0.requestID != requestID }
                )
                return .applied
            }
            return .rejected(rejection)
        case .errorRecovered(let context, let errorID):
            guard let rejection = validateIncrement(context, against: &state) else {
                guard state.failure?.id == errorID else {
                    return .rejected(.staleError)
                }
                state.contextRevision = context.revision
                state.failure = nil
                return .applied
            }
            return .rejected(rejection)
        case .acknowledge(let acknowledgement):
            guard let completion = state.unacknowledgedCompletion else {
                return .rejected(.staleCompletion)
            }
            guard completion.binding == acknowledgement.binding, completion.id == acknowledgement.completionID else {
                return .rejected(.staleCompletion)
            }
            state.unacknowledgedCompletion = nil
            return .applied
        case .reconciliationRequired(let binding):
            guard let currentBinding = state.binding else {
                return .rejected(.noBinding)
            }
            guard binding.instanceID == currentBinding.instanceID else {
                return .rejected(.staleInstance)
            }
            guard binding.sessionID == currentBinding.sessionID else {
                return .rejected(.staleSession)
            }
            guard binding.generation == currentBinding.generation else {
                return .rejected(.staleGeneration)
            }
            invalidateDerivedState(&state)
            return .applied
        case .paused:
            state.isPaused = true
            return .applied
        case .resume:
            state.isPaused = false
            if state.binding != nil {
                invalidateDerivedState(&state)
            }
            return .applied
        case .disconnected:
            let isPaused = state.isPaused
            state = SessionRuntimeState(isPaused: isPaused)
            return .applied
        }
    }

    private static func validateSnapshot(
        _ context: SessionEventContext,
        against state: SessionRuntimeState
    ) -> SessionEventRejection? {
        if let identityRejection = validateIdentity(context, against: state) {
            return identityRejection
        }
        guard context.revision > state.contextRevision else {
            return .outOfOrder
        }
        return nil
    }

    private static func validateIncrement(
        _ context: SessionEventContext,
        against state: inout SessionRuntimeState
    ) -> SessionEventRejection? {
        if let identityRejection = validateIdentity(context, against: state) {
            return identityRejection
        }
        let (nextRevision, overflow) = state.contextRevision.addingReportingOverflow(1)
        guard !overflow, context.revision == nextRevision else {
            if context.revision > state.contextRevision {
                invalidateDerivedState(&state)
                return .revisionGap
            }
            return .outOfOrder
        }
        return nil
    }

    private static func validateIdentity(
        _ context: SessionEventContext,
        against state: SessionRuntimeState
    ) -> SessionEventRejection? {
        guard let binding = state.binding else {
            return .noBinding
        }
        guard context.binding.instanceID == binding.instanceID else {
            return .staleInstance
        }
        guard context.binding.sessionID == binding.sessionID else {
            return .staleSession
        }
        guard context.binding.generation == binding.generation else {
            return .staleGeneration
        }
        return nil
    }

    private static func invalidateDerivedState(_ state: inout SessionRuntimeState) {
        state.connection = .synchronizing
        state.mode = .unknown
        state.work = .unknown
        state.pendingAttention.removeAll()
        state.attention = .unknown
        state.failure = nil
        state.unacknowledgedCompletion = nil
    }
}
