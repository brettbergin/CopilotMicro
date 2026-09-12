import CopilotMicroCore
import Testing

@Suite("Deterministic all-key lighting")
struct LightingTests {
    @Test(
        "Known idle modes map to the documented steady colors",
        arguments: [
            (SessionMode.standard, LightingColor.white, "Default"),
            (SessionMode.plan, LightingColor.blue, "Plan"),
            (SessionMode.autopilot, LightingColor.purple, "Autopilot"),
        ])
    func idleModeColors(mode: SessionMode, color: LightingColor, text: String) throws {
        let state = try readyState(mode: mode, work: .idle)
        let projection = LightingProjector.project(state)

        #expect(projection.semanticState == .idle)
        #expect(projection.color == color)
        #expect(projection.animation == .steady)
        #expect(projection.textualState == text)
        #expect(projection.appliesToAllKeys)
    }

    @Test("Unknown, disconnected and paused state project off instead of guessed idle or success")
    func failClosedProjection() throws {
        var unknown = try readyState(mode: .standard, work: .idle)
        unknown.mode = .unknown

        #expect(LightingProjector.project(SessionRuntimeState()).semanticState == .disconnected)
        #expect(LightingProjector.project(unknown).semanticState == .unknown)
        #expect(LightingProjector.project(unknown).color == .off)

        unknown.connection = .paused
        #expect(LightingProjector.project(unknown).semanticState == .paused)
        #expect(LightingProjector.project(unknown).color == .off)
    }

    @Test("LED precedence is error, attention, working, completion, then idle")
    func precedence() throws {
        let binding = try makeBinding()
        let attention = PendingAttention(requestID: try RequestID(rawValue: "permission-1"), kind: .permission)
        let failure = SessionFailure(id: try ErrorID(rawValue: "error-1"), category: .host)
        let completion = CompletionMarker(id: try CompletionID(rawValue: "completion-1"), binding: binding)
        var state = try readyState(
            mode: .autopilot, work: WorkState(foregroundActive: true, backgroundCount: 0, queuedCount: 0))
        state.pendingAttention = [attention]
        state.failure = failure
        state.unacknowledgedCompletion = completion

        #expect(LightingProjector.project(state).semanticState == .error)
        state.failure = nil
        #expect(LightingProjector.project(state).semanticState == .attention)
        state.pendingAttention = []
        #expect(LightingProjector.project(state).semanticState == .working)
        state.work = .idle
        #expect(LightingProjector.project(state).semanticState == .completed)
        state.unacknowledgedCompletion = nil
        #expect(LightingProjector.project(state).semanticState == .idle)
    }

    @Test("Reduced motion replaces pulse and blink without changing state or color")
    func reducedMotion() throws {
        let attention = PendingAttention(requestID: try RequestID(rawValue: "permission-1"), kind: .permission)
        var state = try readyState(
            mode: .plan, work: WorkState(foregroundActive: true, backgroundCount: 0, queuedCount: 0))

        let busy = LightingProjector.project(state, preferences: LightingPreferences(reducedMotion: true))
        #expect(busy.semanticState == .working)
        #expect(busy.color == .blue)
        #expect(busy.animation == .steady)

        state.pendingAttention = [attention]
        let pending = LightingProjector.project(state, preferences: LightingPreferences(reducedMotion: true))
        #expect(pending.semanticState == .attention)
        #expect(pending.color == .amber)
        #expect(pending.animation == .steady)
    }

    @Test("Brightness clamps finite values and zero retains textual state")
    func brightnessClamping() throws {
        #expect(try Brightness(clamping: -1).value == 0)
        #expect(try Brightness(clamping: 2).value == 1)
        #expect(throws: Brightness.ValidationError.nonFinite) {
            try Brightness(clamping: .nan)
        }

        let state = try readyState(mode: .standard, work: .idle)
        let projection = LightingProjector.project(
            state,
            preferences: LightingPreferences(brightness: try Brightness(clamping: 0))
        )
        #expect(projection.intensity(atMilliseconds: 0) == 0)
        #expect(projection.textualState == "Default")
    }

    @Test("Animation phases are deterministic at injected monotonic times")
    func deterministicAnimationPhases() throws {
        let busyState = try readyState(
            mode: .plan,
            work: WorkState(foregroundActive: true, backgroundCount: 0, queuedCount: 0)
        )
        let busy = LightingProjector.project(
            busyState,
            preferences: LightingPreferences(brightness: try Brightness(clamping: 0.8))
        )
        #expect(busy.intensity(atMilliseconds: 0) == 0.8)
        #expect(busy.intensity(atMilliseconds: 249) == 0.8)
        #expect(busy.intensity(atMilliseconds: 250) == 0)
        #expect(busy.intensity(atMilliseconds: 499) == 0)
        #expect(busy.intensity(atMilliseconds: 500) == 0.8)

        var attentionState = busyState
        attentionState.pendingAttention = [
            PendingAttention(requestID: try RequestID(rawValue: "permission-1"), kind: .permission)
        ]
        let attention = LightingProjector.project(
            attentionState,
            preferences: LightingPreferences(brightness: try Brightness(clamping: 0.8))
        )
        #expect(abs(attention.intensity(atMilliseconds: 0) - 0.2) < 0.000_001)
        #expect(abs(attention.intensity(atMilliseconds: 500) - 0.8) < 0.000_001)
        #expect(abs(attention.intensity(atMilliseconds: 1_000) - 0.2) < 0.000_001)
    }
}

private func readyState(mode: SessionMode, work: WorkState) throws -> SessionRuntimeState {
    SessionRuntimeState(
        binding: try makeBinding(),
        connection: .ready,
        contextRevision: 1,
        mode: .known(mode),
        work: work
    )
}
