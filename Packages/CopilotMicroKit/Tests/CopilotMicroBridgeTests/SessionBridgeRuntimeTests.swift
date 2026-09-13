import CopilotMicroBridge
import CopilotMicroCore
import Foundation
import Testing

@Suite("Packaged app session bridge runtime")
struct SessionBridgeRuntimeTests {
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
