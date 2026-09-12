import CopilotMicroCore
import Testing

@Suite("Session state and completion acknowledgement")
struct SessionReducerTests {
    @Test("Initial idle and abort never become clean completion")
    func noFalseCompletion() throws {
        let binding = try makeBinding()
        var state = SessionRuntimeState()
        #expect(SessionReducer.reduce(&state, .connected(binding)) == .applied)
        #expect(
            SessionReducer.reduce(
                &state,
                .snapshot(context(binding, 1), SessionSnapshot(mode: .known(.standard), work: .idle))
            ) == .applied
        )
        #expect(state.unacknowledgedCompletion == nil)
        #expect(LightingProjector.project(state).semanticState == .idle)

        #expect(SessionReducer.reduce(&state, .workAborted(context(binding, 2))) == .applied)
        #expect(state.unacknowledgedCompletion == nil)
        #expect(LightingProjector.project(state).semanticState == .idle)
    }

    @Test("An authoritative synchronized snapshot can restore unacknowledged completion")
    func snapshotRestoresCompletion() throws {
        let binding = try makeBinding()
        let completionID = try CompletionID(rawValue: "completion-snapshot-1")
        var state = SessionRuntimeState()

        #expect(SessionReducer.reduce(&state, .connected(binding)) == .applied)
        #expect(
            SessionReducer.reduce(
                &state,
                .snapshot(
                    context(binding, 1),
                    SessionSnapshot(
                        mode: .known(.plan),
                        work: .idle,
                        unacknowledgedCompletionID: completionID
                    )
                )
            ) == .applied
        )
        #expect(state.unacknowledgedCompletion?.id == completionID)
        #expect(LightingProjector.project(state).semanticState == .completed)
    }

    @Test("Contradictory snapshots fail without mutating state")
    func invalidSnapshotIsRejected() throws {
        let binding = try makeBinding()
        var state = SessionRuntimeState()
        #expect(SessionReducer.reduce(&state, .connected(binding)) == .applied)
        let original = state
        let active = try WorkState(foregroundActive: true, backgroundCount: 0, queuedCount: 0)
        let snapshot = SessionSnapshot(
            mode: .known(.plan),
            work: active,
            unacknowledgedCompletionID: try CompletionID(rawValue: "completion-invalid")
        )

        #expect(
            SessionReducer.reduce(&state, .snapshot(context(binding, 1), snapshot))
                == .rejected(.invalidSnapshot)
        )
        #expect(state == original)
    }

    @Test("Clean completion remains green until a matching verified interaction")
    func completionAcknowledgement() throws {
        let binding = try makeBinding()
        let completionID = try CompletionID(rawValue: "completion-1")
        var state = try synchronizedState(binding)
        let active = try WorkState(foregroundActive: true, backgroundCount: 0, queuedCount: 0)

        #expect(SessionReducer.reduce(&state, .workStarted(context(binding, 2), active)) == .applied)
        #expect(SessionReducer.reduce(&state, .workCompleted(context(binding, 3), completionID)) == .applied)
        #expect(LightingProjector.project(state).semanticState == .completed)

        let stale = CompletionAcknowledgement(
            completionID: try CompletionID(rawValue: "completion-old"),
            binding: binding,
            source: .verifiedScopedInteraction
        )
        #expect(SessionReducer.reduce(&state, .acknowledge(stale)) == .rejected(.staleCompletion))
        #expect(LightingProjector.project(state).semanticState == .completed)

        let acknowledgement = CompletionAcknowledgement(
            completionID: completionID,
            binding: binding,
            source: .verifiedScopedInteraction
        )
        #expect(SessionReducer.reduce(&state, .acknowledge(acknowledgement)) == .applied)
        #expect(LightingProjector.project(state).semanticState == .idle)
    }

    @Test("One resolved request cannot clear other pending attention")
    func pendingRequestSet() throws {
        let binding = try makeBinding()
        let first = PendingAttention(requestID: try RequestID(rawValue: "permission-1"), kind: .permission)
        let second = PendingAttention(requestID: try RequestID(rawValue: "question-1"), kind: .question)
        var state = try synchronizedState(binding)

        #expect(SessionReducer.reduce(&state, .attentionAdded(context(binding, 2), first)) == .applied)
        #expect(SessionReducer.reduce(&state, .attentionAdded(context(binding, 3), second)) == .applied)
        #expect(SessionReducer.reduce(&state, .attentionResolved(context(binding, 4), first.requestID)) == .applied)
        #expect(state.pendingAttention == [second])
        #expect(LightingProjector.project(state).semanticState == .attention)
    }

    @Test("Pending attention IDs are unique and bounded")
    func pendingRequestValidation() throws {
        let duplicateID = try RequestID(rawValue: "request-duplicate")
        let duplicateSnapshot = SessionSnapshot(
            mode: .known(.standard),
            work: .idle,
            pendingAttention: [
                PendingAttention(requestID: duplicateID, kind: .permission),
                PendingAttention(requestID: duplicateID, kind: .question),
            ]
        )
        #expect(throws: SessionSnapshot.ValidationError.duplicatePendingRequest) {
            try duplicateSnapshot.validate()
        }

        let excessive = try Set(
            (0...SessionSnapshot.maximumPendingAttention).map {
                PendingAttention(requestID: try RequestID(rawValue: "request-\($0)"), kind: .question)
            }
        )
        let excessiveSnapshot = SessionSnapshot(
            mode: .known(.standard),
            work: .idle,
            pendingAttention: excessive
        )
        #expect(throws: SessionSnapshot.ValidationError.tooManyPendingRequests) {
            try excessiveSnapshot.validate()
        }
    }

    @Test("New authoritative work clears prior completion and task error")
    func newWorkRecoversState() throws {
        let binding = try makeBinding()
        let failure = SessionFailure(id: try ErrorID(rawValue: "error-1"), category: .host)
        var state = try synchronizedState(binding)
        #expect(SessionReducer.reduce(&state, .workFailed(context(binding, 2), failure)) == .applied)
        #expect(LightingProjector.project(state).semanticState == .error)

        let active = try WorkState(foregroundActive: false, backgroundCount: 1, queuedCount: 0)
        #expect(SessionReducer.reduce(&state, .workStarted(context(binding, 3), active)) == .applied)
        #expect(state.failure == nil)
        #expect(state.unacknowledgedCompletion == nil)
        #expect(LightingProjector.project(state).semanticState == .working)
    }

    @Test("Stale identity and out-of-order events cannot mutate current state")
    func staleEventsAreRejected() throws {
        let binding = try makeBinding()
        var state = try synchronizedState(binding)
        let original = state
        let staleBinding = try LiveBinding(
            instanceID: binding.instanceID,
            sessionID: binding.sessionID,
            generation: ConnectionGeneration(rawValue: "generation-old")
        )

        #expect(
            SessionReducer.reduce(&state, .workAborted(context(staleBinding, 2)))
                == .rejected(.staleGeneration)
        )
        #expect(state == original)
        #expect(
            SessionReducer.reduce(&state, .workAborted(context(binding, 1)))
                == .rejected(.outOfOrder)
        )
        #expect(state == original)
    }

    @Test("A revision gap invalidates derived state until an authoritative snapshot arrives")
    func revisionGapRequiresReconciliation() throws {
        let binding = try makeBinding()
        var state = try synchronizedState(binding)
        let attention = PendingAttention(requestID: try RequestID(rawValue: "permission-1"), kind: .permission)

        #expect(
            SessionReducer.reduce(&state, .attentionAdded(context(binding, 3), attention))
                == .rejected(.revisionGap)
        )
        #expect(state.connection == .synchronizing)
        #expect(state.mode == .unknown)
        #expect(state.work == .unknown)
        #expect(state.pendingAttention.isEmpty)
        #expect(LightingProjector.project(state).semanticState == .unknown)

        #expect(
            SessionReducer.reduce(
                &state,
                .snapshot(context(binding, 3), SessionSnapshot(mode: .known(.plan), work: .idle))
            ) == .applied
        )
        #expect(state.connection == .ready)
        #expect(state.contextRevision == 3)
    }

    @Test("Pause survives late snapshots, disconnect and reconnect until explicit resume")
    func pauseIsSticky() throws {
        let binding = try makeBinding()
        var state = try synchronizedState(binding)

        #expect(SessionReducer.reduce(&state, .paused) == .applied)
        #expect(state.isPaused)
        #expect(
            SessionReducer.reduce(
                &state,
                .snapshot(context(binding, 2), SessionSnapshot(mode: .known(.plan), work: .idle))
            ) == .applied
        )
        #expect(state.isPaused)
        #expect(LightingProjector.project(state).semanticState == .paused)

        #expect(SessionReducer.reduce(&state, .disconnected) == .applied)
        #expect(state.isPaused)
        #expect(SessionReducer.reduce(&state, .connected(binding)) == .applied)
        #expect(state.isPaused)
        #expect(
            SessionReducer.reduce(
                &state,
                .snapshot(context(binding, 1), SessionSnapshot(mode: .known(.standard), work: .idle))
            ) == .applied
        )
        #expect(state.isPaused)

        #expect(SessionReducer.reduce(&state, .resume) == .applied)
        #expect(!state.isPaused)
        #expect(state.connection == .synchronizing)
        #expect(LightingProjector.project(state).semanticState == .unknown)
    }

    @Test("Disconnect clears cached success, error and pending state")
    func disconnectInvalidatesLiveState() throws {
        let binding = try makeBinding()
        var state = try synchronizedState(binding)
        state.failure = SessionFailure(id: try ErrorID(rawValue: "error-1"), category: .host)
        state.pendingAttention = [
            PendingAttention(requestID: try RequestID(rawValue: "permission-1"), kind: .permission)
        ]
        state.unacknowledgedCompletion = CompletionMarker(
            id: try CompletionID(rawValue: "completion-1"),
            binding: binding
        )

        #expect(SessionReducer.reduce(&state, .disconnected) == .applied)
        #expect(state == SessionRuntimeState())
        #expect(LightingProjector.project(state).semanticState == .disconnected)
    }

    @Test("Action guards distinguish stale, unavailable and invisible permission requests")
    func actionGuardFailuresAreExplicit() throws {
        let binding = try makeBinding()
        let requestID = try RequestID(rawValue: "action-1")
        let permissionID = try RequestID(rawValue: "permission-1")
        let action = ActionRequest(
            requestID: requestID,
            binding: binding,
            contextRevision: 42,
            action: try ActionPayload(type: .approvePermissionOnce, permissionRequestID: permissionID)
        )
        let supported: [ActionID: Capability] = [.approvePermissionOnce: .supported]
        let base = ActionContext(
            binding: binding,
            connection: .ready,
            isPaused: false,
            contextRevision: 42,
            capabilities: supported,
            pendingRequestIDs: [permissionID],
            visiblePermissionRequestID: permissionID
        )
        #expect(ActionGuard.validate(action, against: base) == nil)
        #expect(
            ActionGuard.validate(
                action,
                against: ActionContext(
                    binding: binding,
                    connection: .ready,
                    isPaused: true,
                    contextRevision: 42,
                    capabilities: supported,
                    pendingRequestIDs: [permissionID],
                    visiblePermissionRequestID: permissionID
                )
            ) == .paused
        )
        #expect(
            ActionGuard.validate(
                action,
                against: ActionContext(
                    binding: binding,
                    connection: .ready,
                    isPaused: false,
                    contextRevision: 42,
                    capabilities: supported,
                    pendingRequestIDs: [permissionID]
                )
            ) == .permissionRequestNotVisible
        )
        #expect(
            ActionGuard.validate(
                action,
                against: ActionContext(
                    binding: binding,
                    connection: .ready,
                    isPaused: false,
                    contextRevision: 42,
                    capabilities: [.approvePermissionOnce: Capability(status: .unavailable)]
                )
            ) == .capabilityUnavailable
        )
        #expect(
            ActionGuard.validate(
                action,
                against: ActionContext(
                    binding: binding,
                    connection: .ready,
                    isPaused: false,
                    contextRevision: 42,
                    capabilities: [.approvePermissionOnce: Capability(status: .blocked)]
                )
            ) == .capabilityBlocked
        )
        #expect(
            ActionGuard.validate(
                action,
                against: ActionContext(
                    binding: binding,
                    connection: .ready,
                    isPaused: false,
                    contextRevision: 42,
                    capabilities: [:]
                )
            ) == .capabilityUnknown
        )
        #expect(
            ActionGuard.validate(
                action,
                against: ActionContext(
                    binding: binding,
                    connection: .synchronizing,
                    isPaused: false,
                    contextRevision: 42,
                    capabilities: supported
                )
            ) == .unsynchronized
        )
    }

    @Test("Replay ledger rejects in-flight and completed duplicates until generation invalidation")
    func duplicateRequestsAreRejected() throws {
        let binding = try makeBinding()
        let request = ActionRequest(
            requestID: try RequestID(rawValue: "action-duplicate-1"),
            binding: binding,
            contextRevision: 42,
            action: try ActionPayload(type: .cancelForeground)
        )
        let context = ActionContext(
            binding: binding,
            connection: .ready,
            isPaused: false,
            contextRevision: 42,
            capabilities: [.cancelForeground: .supported]
        )
        var ledger = ActionReplayLedger()

        #expect(ledger.reserve(request, against: context) == .reserved)
        #expect(ledger.reserve(request, against: context) == .rejected(.duplicateRequest))
        let completed = ledger.complete(request.requestID)
        #expect(completed)
        #expect(ledger.reserve(request, against: context) == .rejected(.duplicateRequest))

        let sameGenerationInvalidated = ledger.invalidate(for: binding.generation)
        #expect(!sameGenerationInvalidated)
        #expect(ledger.reserve(request, against: context) == .rejected(.duplicateRequest))

        let replacement = try LiveBinding(
            instanceID: binding.instanceID,
            sessionID: binding.sessionID,
            generation: ConnectionGeneration(rawValue: "generation-2")
        )
        let replacementRequest = ActionRequest(
            requestID: request.requestID,
            binding: replacement,
            contextRevision: 1,
            action: try ActionPayload(type: .cancelForeground)
        )
        let replacementContext = ActionContext(
            binding: replacement,
            connection: .ready,
            isPaused: false,
            contextRevision: 1,
            capabilities: [.cancelForeground: .supported]
        )
        let replacementInvalidated = ledger.invalidate(for: replacement.generation)
        #expect(replacementInvalidated)
        #expect(ledger.reserve(replacementRequest, against: replacementContext) == .reserved)
    }

    @Test("Replay ledger fails closed at its bounded per-generation capacity")
    func replayLedgerIsBounded() throws {
        let binding = try makeBinding()
        let context = ActionContext(
            binding: binding,
            connection: .ready,
            isPaused: false,
            contextRevision: 42,
            capabilities: [.cancelForeground: .supported]
        )
        var ledger = ActionReplayLedger()
        for index in 0..<ActionReplayLedger.maximumTrackedRequests {
            let request = ActionRequest(
                requestID: try RequestID(rawValue: "action-\(index)"),
                binding: binding,
                contextRevision: 42,
                action: try ActionPayload(type: .cancelForeground)
            )
            #expect(ledger.reserve(request, against: context) == .reserved)
        }
        let overflow = ActionRequest(
            requestID: try RequestID(rawValue: "action-overflow"),
            binding: binding,
            contextRevision: 42,
            action: try ActionPayload(type: .cancelForeground)
        )
        #expect(ledger.reserve(overflow, against: context) == .rejected(.replayLedgerFull))
    }

    private func synchronizedState(_ binding: LiveBinding) throws -> SessionRuntimeState {
        var state = SessionRuntimeState()
        #expect(SessionReducer.reduce(&state, .connected(binding)) == .applied)
        #expect(
            SessionReducer.reduce(
                &state,
                .snapshot(context(binding, 1), SessionSnapshot(mode: .known(.standard), work: .idle))
            ) == .applied
        )
        return state
    }

    private func context(_ binding: LiveBinding, _ revision: UInt64) -> SessionEventContext {
        SessionEventContext(binding: binding, revision: revision)
    }
}
