import CopilotMicroBridge
import CopilotMicroCore
import Foundation
import Testing

@Suite("Packaged app session bridge runtime")
struct SessionBridgeRuntimeTests {
    @Test("Authenticated snapshots surface known state and events invalidate it")
    func forwardsReconciledReadOnlyState() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/cm-observe-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let events = RuntimeEventRecorder()
        let runtime = SessionBridgeRuntime()
        let configuration = try await runtime.start(
            rootURL: rootURL,
            associationHandler: { _ in .bound },
            eventHandler: { event in await events.record(event) }
        )
        defer { runtime.stop() }
        let token = try await IPCBootstrapStore(rootURL: rootURL).loadOrCreate()
        let selectedRegistration = try registration(bootstrapToken: token)
        let client = try await Task.detached {
            try AuthenticatedIPCClient.connect(
                socketURL: configuration.socketURL,
                registration: selectedRegistration
            )
        }.value
        defer { client.close() }
        let snapshot = try JSONSerialization.data(withJSONObject: readOnlySnapshot(revision: 1))
        try client.send(payload: snapshot)
        try await waitUntil {
            await events.observationCount >= 1
        }
        let observation = await events.latestObservation
        #expect(observation?.runtimeState.mode == .known(.plan))
        #expect(observation?.runtimeState.work.isKnown == true)
        #expect(observation?.runtimeState.binding?.sessionID.rawValue == "session-1")
        #expect(observation?.compatibility.isQualifiedReadOnly == true)
        #expect(observation?.isDisplayable(for: .bound) == true)
        #expect(observation?.isDisplayable(for: .notRequested) == false)
        #expect(observation?.isDisplayable(for: .pending) == false)

        let event = try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 1, "messageType": "sessionEvent",
            "instanceId": "cli-host-42", "sessionId": "session-1",
            "generation": "generation-1", "contextRevision": 2, "reason": "mode",
        ])
        try client.send(payload: event)
        try await waitUntil {
            await events.observationCount >= 2
        }
        #expect(await events.latestObservation?.runtimeState.mode == .unknown)
        #expect(await events.latestObservation?.runtimeState.connection == .synchronizing)
        #expect(await events.latestObservation?.isDisplayable(for: .bound) == true)
        let incompatible = SessionBridgeObservedState(
            runtimeState: try #require(await events.latestObservation).runtimeState,
            model: .unknown,
            compatibility: SessionObservationCompatibility(
                status: .unqualified,
                cliVersion: "unsupported",
                sdkVersion: "host-provided",
                reason: "Not qualified."
            )
        )
        #expect(!incompatible.isDisplayable(for: .bound))
        client.close()
        try await waitUntil {
            await events.observationCount >= 3
        }
        #expect(await events.latestObservation?.runtimeState.binding == nil)
        #expect(await events.latestObservation?.runtimeState.connection == .disconnected)
    }

    @Test("Runtime authenticates registrations and reports surface association")
    func authenticatesAndAssociates() async throws {
        let rootURL = URL(
            fileURLWithPath: "/tmp/cm-runtime-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let events = RuntimeEventRecorder()
        let registrations = RuntimeRegistrationRecorder()
        let runtime = SessionBridgeRuntime()
        let configuration = try await runtime.start(
            rootURL: rootURL,
            associationHandler: { registration in
                await registrations.recordAndClassify(registration)
            },
            eventHandler: { event in
                await events.record(event)
            }
        )
        defer { runtime.stop() }

        #expect(runtime.isStarted)
        #expect(configuration.socketURL.path.hasSuffix("/bridge/bridge.sock"))
        #expect(try permissions(at: configuration.directoryURL) == 0o700)
        #expect(try permissions(at: configuration.socketURL) == 0o600)
        let bootstrapToken = try await IPCBootstrapStore(rootURL: rootURL).loadOrCreate()
        let surfaceToken = try SurfaceAssociationToken(
            rawValue: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )
        let registration = try IPCRegistration(
            bootstrapToken: bootstrapToken,
            binding: LiveBinding(
                instanceID: CLIInstanceID(rawValue: "cli-host-42"),
                sessionID: SessionID(rawValue: "session-1"),
                generation: ConnectionGeneration(rawValue: "generation-1")
            ),
            surfaceAssociationToken: surfaceToken,
            bridgeVersion: "0.1.0",
            cliVersion: "1.0.84-5",
            sdkVersion: "host-provided"
        )

        let client = try await Task.detached {
            try AuthenticatedIPCClient.connect(
                socketURL: configuration.socketURL,
                registration: registration
            )
        }.value
        client.close()

        try await waitUntil {
            await events.contains(
                .registrationAccepted(
                    activation: .connected,
                    association: .bound
                )
            )
        }
        #expect(await events.first == .listening)
        #expect(await registrations.latest == registration)
        try await waitUntil {
            await events.contains(.disconnected)
        }

        let reconnect = try await Task.detached {
            try AuthenticatedIPCClient.connect(
                socketURL: configuration.socketURL,
                registration: registration
            )
        }.value
        reconnect.close()
        try await waitUntil {
            await events.contains(
                .registrationAccepted(
                    activation: .reconnected,
                    association: .reconnected
                )
            )
        }

        runtime.stop()
        try await waitUntil {
            !FileManager.default.fileExists(atPath: configuration.socketURL.path)
        }
        #expect(!runtime.isStarted)
    }

    @Test("Runtime rejects duplicate starts")
    func rejectsDuplicateStart() async throws {
        let rootURL = URL(
            fileURLWithPath: "/tmp/cm-runtime-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runtime = SessionBridgeRuntime()
        _ = try await runtime.start(
            rootURL: rootURL,
            associationHandler: { _ in .notRequested },
            eventHandler: { _ in }
        )
        defer { runtime.stop() }

        await #expect(throws: SessionBridgeRuntimeFailure.alreadyStarted) {
            _ = try await runtime.start(
                rootURL: rootURL,
                associationHandler: { _ in .notRequested },
                eventHandler: { _ in }
            )
        }
    }

    @Test("Rejected registration does not stop the listener")
    func rejectedRegistrationDoesNotStopListener() async throws {
        let rootURL = URL(
            fileURLWithPath: "/tmp/cm-runtime-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let events = RuntimeEventRecorder()
        let runtime = SessionBridgeRuntime()
        let configuration = try await runtime.start(
            rootURL: rootURL,
            associationHandler: { _ in .notRequested },
            eventHandler: { event in
                await events.record(event)
            }
        )
        defer { runtime.stop() }
        let validToken = try await IPCBootstrapStore(rootURL: rootURL).loadOrCreate()
        let wrongToken = try IPCBootstrapToken(
            rawValue: String(repeating: "f", count: 64)
        )
        let invalidRegistration = try registration(bootstrapToken: wrongToken)
        let validRegistration = try registration(bootstrapToken: validToken)

        do {
            _ = try await Task.detached {
                try AuthenticatedIPCClient.connect(
                    socketURL: configuration.socketURL,
                    registration: invalidRegistration
                )
            }.value
            Issue.record("The invalid registration unexpectedly connected.")
        } catch let error as IPCTransportError {
            #expect(error == .registrationRejected(.invalidToken))
        }
        try await waitUntil {
            await events.contains(.connectionFailed)
        }
        #expect(runtime.isStarted)

        let validClient = try await Task.detached {
            try AuthenticatedIPCClient.connect(
                socketURL: configuration.socketURL,
                registration: validRegistration
            )
        }.value
        validClient.close()
        try await waitUntil {
            await events.contains(
                .registrationAccepted(
                    activation: .connected,
                    association: .notRequested
                )
            )
        }
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    private func readOnlySnapshot(revision: UInt64) -> [String: Any] {
        [
            "protocolVersion": 1, "messageType": "sessionSnapshot",
            "instanceId": "cli-host-42", "sessionId": "session-1",
            "generation": "generation-1", "contextRevision": revision,
            "connection": "ready", "paused": false, "mode": "plan",
            "work": ["known": true, "foregroundActive": true, "backgroundCount": 0, "queuedCount": 0],
            "pendingAttention": [],
            "attention": ["known": true, "permissionCount": 0, "otherCount": 0],
            "capabilities": Dictionary(
                uniqueKeysWithValues: ActionID.allCases.map {
                    ($0.rawValue, ["status": "unavailable", "reason": "Read-only observer", "gapReference": "I-15"])
                }),
            "hostCapabilities": ["elicitation": false, "canvases": false, "mcpApps": false],
            "model": [
                "known": false, "modelId": NSNull(), "reasoningEffort": NSNull(),
                "contextTier": NSNull(), "availableModels": [],
            ],
            "compatibility": [
                "status": "qualifiedReadOnly", "cliVersion": "1.0.84-5",
                "sdkVersion": "host-provided", "reason": "Qualified read-only observer.",
            ],
            "visiblePermissionRequestId": NSNull(), "failure": NSNull(),
            "completionId": NSNull(),
        ]
    }

    private func registration(
        bootstrapToken: IPCBootstrapToken
    ) throws -> IPCRegistration {
        try IPCRegistration(
            bootstrapToken: bootstrapToken,
            binding: LiveBinding(
                instanceID: CLIInstanceID(rawValue: "cli-host-42"),
                sessionID: SessionID(rawValue: "session-1"),
                generation: ConnectionGeneration(rawValue: "generation-1")
            ),
            bridgeVersion: "0.1.0",
            cliVersion: "1.0.84-5",
            sdkVersion: "host-provided"
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the bridge runtime condition.")
    }
}

private actor RuntimeEventRecorder {
    private var events: [SessionBridgeRuntimeEvent] = []

    func record(_ event: SessionBridgeRuntimeEvent) {
        events.append(event)
    }

    func contains(_ event: SessionBridgeRuntimeEvent) -> Bool {
        events.contains(event)
    }

    var first: SessionBridgeRuntimeEvent? {
        events.first
    }

    var latestObservation: SessionBridgeObservedState? {
        for event in events.reversed() {
            if case .sessionObserved(let state) = event {
                return state
            }
        }
        return nil
    }

    var observationCount: Int {
        events.reduce(into: 0) { count, event in
            if case .sessionObserved = event {
                count += 1
            }
        }
    }
}

private actor RuntimeRegistrationRecorder {
    private(set) var latest: IPCRegistration?
    private var registrationCount = 0

    func recordAndClassify(
        _ registration: IPCRegistration
    ) -> SessionBridgeAssociationOutcome {
        latest = registration
        registrationCount += 1
        return registrationCount == 1 ? .bound : .reconnected
    }
}
