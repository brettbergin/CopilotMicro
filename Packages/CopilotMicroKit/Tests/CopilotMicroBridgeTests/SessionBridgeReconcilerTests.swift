import CopilotMicroBridge
import CopilotMicroCore
import Foundation
import Testing

@Suite("Read-only production session bridge reconciliation")
struct SessionBridgeReconcilerTests {
    @Test("Registration and replacement keep host, session and generation distinct")
    func replacementStartsUnknown() throws {
        var reconciler = SessionBridgeReconciler()
        let first = try registration(session: "session-1", generation: "generation-1")
        #expect(
            reconciler.activateAuthenticatedRegistration(first, nowMilliseconds: 10)
                == .connected
        )
        #expect(reconciler.runtimeState.connection == .synchronizing)
        #expect(reconciler.runtimeState.mode == .unknown)
        #expect(reconciler.runtimeState.work == .unknown)

        let replacement = try registration(session: "session-2", generation: "generation-2")
        #expect(
            reconciler.activateAuthenticatedRegistration(replacement, nowMilliseconds: 20)
                == .replaced
        )
        #expect(reconciler.runtimeState.binding?.instanceID == first.instanceID)
        #expect(reconciler.runtimeState.binding?.sessionID == replacement.sessionID)
        #expect(reconciler.runtimeState.binding?.generation == replacement.generation)
        #expect(reconciler.runtimeState.connection == .synchronizing)
        #expect(reconciler.runtimeState.mode == .unknown)

        let stale = try frame(
            payload: snapshotPayload(
                session: "session-1",
                generation: "generation-1",
                revision: 1
            ),
            generation: "generation-1"
        )
        #expect(
            reconciler.receive(stale, nowMilliseconds: 21)
                == .rejected(.staleGeneration)
        )
    }

    @Test("Events invalidate derived state until a newer authoritative snapshot")
    func eventReconciliationIsOrdered() throws {
        var reconciler = SessionBridgeReconciler()
        let registration = try registration()
        _ = reconciler.activateAuthenticatedRegistration(registration, nowMilliseconds: 10)

        let initial = try frame(
            payload: snapshotPayload(revision: 1),
            generation: "generation-1"
        )
        #expect(
            reconciler.receive(initial, nowMilliseconds: 11)
                == .snapshotApplied(capabilitiesChanged: true)
        )
        #expect(reconciler.runtimeState.connection == .ready)
        #expect(reconciler.runtimeState.mode == .known(.plan))
        #expect(reconciler.runtimeState.attention.permissionCount == 1)
        #expect(reconciler.model.modelID == "gpt-qualified")

        let event = try frame(
            payload: eventPayload(revision: 2, reason: "mode"),
            generation: "generation-1",
            sequence: 2
        )
        #expect(
            reconciler.receive(event, nowMilliseconds: 12)
                == .reconciliationRequired(.mode)
        )
        #expect(reconciler.runtimeState.connection == .synchronizing)
        #expect(reconciler.runtimeState.mode == .unknown)
        #expect(reconciler.model == .unknown)
        #expect(
            reconciler.capabilities.values.allSatisfy { $0.status == .unknown }
        )

        let stale = try frame(
            payload: snapshotPayload(revision: 1),
            generation: "generation-1",
            sequence: 3
        )
        #expect(
            reconciler.receive(stale, nowMilliseconds: 13)
                == .rejected(.outOfOrder)
        )

        let reconciled = try frame(
            payload: snapshotPayload(revision: 2, mode: "default"),
            generation: "generation-1",
            sequence: 4
        )
        #expect(
            reconciler.receive(reconciled, nowMilliseconds: 14)
                == .snapshotApplied(capabilitiesChanged: true)
        )
        #expect(reconciler.runtimeState.connection == .ready)
        #expect(reconciler.runtimeState.mode == .known(.standard))
        #expect(reconciler.runtimeState.contextRevision == 2)
    }

    @Test("Heartbeats preserve liveness but higher revisions require reconciliation")
    func heartbeatAndExpiry() throws {
        var reconciler = SessionBridgeReconciler(livenessTimeoutMilliseconds: 100)
        _ = reconciler.activateAuthenticatedRegistration(
            try registration(),
            nowMilliseconds: 10
        )
        let snapshot = try frame(
            payload: snapshotPayload(revision: 1),
            generation: "generation-1"
        )
        _ = reconciler.receive(snapshot, nowMilliseconds: 20)

        let heartbeat = try frame(
            payload: heartbeatPayload(revision: 1),
            generation: "generation-1",
            sequence: 2
        )
        #expect(reconciler.receive(heartbeat, nowMilliseconds: 90) == .heartbeat)
        let stillAlive = reconciler.expireIfNeeded(nowMilliseconds: 190)
        #expect(!stillAlive)
        let expired = reconciler.expireIfNeeded(nowMilliseconds: 191)
        #expect(expired)
        #expect(reconciler.runtimeState.connection == .disconnected)
        #expect(reconciler.registration == nil)

        _ = reconciler.activateAuthenticatedRegistration(
            try registration(),
            nowMilliseconds: 200
        )
        let ahead = try frame(
            payload: heartbeatPayload(revision: 2),
            generation: "generation-1"
        )
        #expect(
            reconciler.receive(ahead, nowMilliseconds: 201)
                == .reconciliationRequired(.lifecycle)
        )
        #expect(reconciler.runtimeState.connection == .synchronizing)
    }

    @Test("Production snapshots cannot advertise any supported stateful action")
    func supportedActionsFailClosed() throws {
        var reconciler = SessionBridgeReconciler()
        _ = reconciler.activateAuthenticatedRegistration(
            try registration(),
            nowMilliseconds: 10
        )
        var payload = snapshotPayload(revision: 1)
        var capabilities = try #require(payload["capabilities"] as? [String: Any])
        capabilities[ActionID.cycleMode.rawValue] = [
            "status": "supported"
        ]
        payload["capabilities"] = capabilities
        let unsafe = try frame(payload: payload, generation: "generation-1")

        #expect(
            reconciler.receive(unsafe, nowMilliseconds: 11)
                == .rejected(.unsafeCapability)
        )
        #expect(reconciler.runtimeState.connection == .synchronizing)
    }

    @Test("Unqualified host versions retain compatibility reasons but not live state")
    func incompatibleHostStaysUnknown() throws {
        var reconciler = SessionBridgeReconciler()
        _ = reconciler.activateAuthenticatedRegistration(
            try registration(),
            nowMilliseconds: 10
        )
        let snapshot = try frame(
            payload: snapshotPayload(
                revision: 1,
                cliVersion: "1.0.85",
                compatibilityStatus: "unqualified"
            ),
            generation: "generation-1"
        )

        #expect(
            reconciler.receive(snapshot, nowMilliseconds: 11)
                == .compatibilityBlocked
        )
        #expect(reconciler.runtimeState.connection == .synchronizing)
        #expect(reconciler.runtimeState.mode == .unknown)
        #expect(reconciler.compatibility.cliVersion == "1.0.85")
        #expect(
            reconciler.capabilities.values.allSatisfy { $0.status != .supported }
        )
    }

    @Test("Every native action context remains rejected before I-15")
    func nativeActionsRemainRejected() throws {
        var reconciler = SessionBridgeReconciler()
        let registration = try registration()
        _ = reconciler.activateAuthenticatedRegistration(registration, nowMilliseconds: 10)
        let snapshot = try frame(
            payload: snapshotPayload(revision: 1),
            generation: "generation-1"
        )
        _ = reconciler.receive(snapshot, nowMilliseconds: 11)

        for (index, action) in ActionID.allCases.enumerated() {
            let permissionID = try RequestID(rawValue: "permission-\(index)")
            let request = ActionRequest(
                requestID: try RequestID(rawValue: "action-\(index)"),
                binding: try binding(),
                contextRevision: 1,
                action: try ActionPayload(
                    type: action,
                    permissionRequestID: action.requiresPermissionRequest ? permissionID : nil
                )
            )
            let rejection = try #require(
                ActionGuard.validate(request, against: reconciler.actionContext)
            )
            #expect(
                rejection == .capabilityUnavailable || rejection == .capabilityBlocked
            )
        }
    }

    private func registration(
        session: String = "session-1",
        generation: String = "generation-1"
    ) throws -> IPCRegistration {
        try IPCRegistration(
            bootstrapToken: IPCBootstrapToken(
                rawValue: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            ),
            binding: LiveBinding(
                instanceID: CLIInstanceID(rawValue: "cli-host-100"),
                sessionID: SessionID(rawValue: session),
                generation: ConnectionGeneration(rawValue: generation)
            ),
            bridgeVersion: "0.1.0",
            cliVersion: "unknown",
            sdkVersion: "host-provided"
        )
    }

    private func binding() throws -> LiveBinding {
        try LiveBinding(
            instanceID: CLIInstanceID(rawValue: "cli-host-100"),
            sessionID: SessionID(rawValue: "session-1"),
            generation: ConnectionGeneration(rawValue: "generation-1")
        )
    }

    private func frame(
        payload: [String: Any],
        generation: String,
        sequence: UInt64 = 1
    ) throws -> IPCFrame {
        try IPCFrame(
            role: .cliBridge,
            generation: ConnectionGeneration(rawValue: generation),
            sequence: sequence,
            payload: JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        )
    }

    private func snapshotPayload(
        session: String = "session-1",
        generation: String = "generation-1",
        revision: UInt64,
        mode: String = "plan",
        cliVersion: String = "1.0.84-5",
        compatibilityStatus: String = "qualifiedReadOnly"
    ) -> [String: Any] {
        [
            "protocolVersion": 1,
            "messageType": "sessionSnapshot",
            "instanceId": "cli-host-100",
            "sessionId": session,
            "generation": generation,
            "contextRevision": revision,
            "connection": "ready",
            "paused": false,
            "mode": mode,
            "work": [
                "known": true,
                "foregroundActive": false,
                "backgroundCount": 1,
                "queuedCount": 0,
            ],
            "pendingAttention": [],
            "attention": [
                "known": true,
                "permissionCount": 1,
                "otherCount": 0,
            ],
            "capabilities": productionCapabilities(),
            "hostCapabilities": [
                "elicitation": true,
                "canvases": false,
                "mcpApps": false,
            ],
            "model": [
                "known": true,
                "modelId": "gpt-qualified",
                "reasoningEffort": "medium",
                "contextTier": "default",
                "availableModels": [
                    [
                        "id": "gpt-qualified",
                        "reasoningEffort": true,
                        "supportedReasoningEfforts": ["low", "medium", "high"],
                    ]
                ],
            ],
            "compatibility": [
                "status": compatibilityStatus,
                "cliVersion": cliVersion,
                "sdkVersion": "host-provided",
                "reason": "Read-only behavior is qualified for this host tuple.",
            ],
            "visiblePermissionRequestId": NSNull(),
            "failure": NSNull(),
            "completionId": NSNull(),
        ]
    }

    private func eventPayload(revision: UInt64, reason: String) -> [String: Any] {
        [
            "protocolVersion": 1,
            "messageType": "sessionEvent",
            "instanceId": "cli-host-100",
            "sessionId": "session-1",
            "generation": "generation-1",
            "contextRevision": revision,
            "reason": reason,
        ]
    }

    private func heartbeatPayload(revision: UInt64) -> [String: Any] {
        [
            "protocolVersion": 1,
            "messageType": "heartbeat",
            "instanceId": "cli-host-100",
            "sessionId": "session-1",
            "generation": "generation-1",
            "contextRevision": revision,
        ]
    }

    private func productionCapabilities() -> [String: Any] {
        Dictionary(
            uniqueKeysWithValues: ActionID.allCases.map { action in
                (
                    action.rawValue,
                    [
                        "status": action == .cycleMode ? "blocked" : "unavailable",
                        "reason": "Production actions remain disabled until I-15.",
                        "gapReference": "I-15",
                    ]
                )
            }
        )
    }
}
