import CopilotMicroBridge
import CopilotMicroCore
import Darwin
import Foundation
import Testing

@Suite("Owner-restricted Unix socket transport")
struct UnixSocketTransportTests {
    @Test("Authenticated peers exchange role-bound framed messages")
    func authenticatedRoundTrip() async throws {
        try await withShortSocketDirectory { directory, socketURL in
            let token = try testToken()
            let registration = try testRegistration(token: token)
            let server = try AuthenticatedIPCServer(
                socketURL: socketURL,
                bootstrapToken: token
            )
            try server.start()
            defer {
                server.close()
            }

            let clientTask = Task.detached {
                try AuthenticatedIPCClient.connect(
                    socketURL: socketURL,
                    registration: registration
                )
            }
            let serverConnection = try server.accept()
            let clientConnection = try await clientTask.value
            defer {
                serverConnection.close()
                clientConnection.close()
            }

            #expect(try permissions(at: directory) == 0o700)
            #expect(try permissions(at: socketURL) == 0o600)
            #expect(serverConnection.registration == registration)
            #expect(clientConnection.registration == registration)

            let result = try ActionResult(
                requestID: RequestID(rawValue: "request-1"),
                outcome: .completed,
                message: "Completed."
            )
            try clientConnection.send(payload: JSONEncoder().encode(result))
            let receivedResult = try serverConnection.receive()
            #expect(receivedResult.payloadMessageType == .actionResult)
            #expect(try ActionResultDecoder.decode(receivedResult.payload) == result)

            let request = try ActionRequest(
                requestID: RequestID(rawValue: "request-2"),
                binding: testBinding(),
                contextRevision: 42,
                action: ActionPayload(type: .cancelForeground)
            )
            try serverConnection.send(payload: JSONEncoder().encode(request))
            let receivedRequest = try clientConnection.receive()
            #expect(receivedRequest.payloadMessageType == .action)
            #expect(try ActionRequestDecoder.decode(receivedRequest.payload) == request)
        }
    }

    @Test("Rejected authentication closes both sides without a usable connection")
    func invalidTokenIsRejected() async throws {
        try await withShortSocketDirectory { _, socketURL in
            let server = try AuthenticatedIPCServer(
                socketURL: socketURL,
                bootstrapToken: testToken()
            )
            try server.start()
            defer {
                server.close()
            }
            let wrongToken = try IPCBootstrapToken(
                rawValue: String(repeating: "f", count: 64)
            )
            let registration = try testRegistration(token: wrongToken)
            let clientTask = Task.detached {
                try AuthenticatedIPCClient.connect(
                    socketURL: socketURL,
                    registration: registration
                )
            }

            #expect(
                throws: IPCTransportError.registrationRejected(.invalidToken)
            ) {
                _ = try server.accept()
            }
            do {
                _ = try await clientTask.value
                Issue.record("The client unexpectedly authenticated.")
            } catch let error as IPCTransportError {
                #expect(error == .registrationRejected(.invalidToken))
            }
        }
    }

    @Test("Listener rejects unsafe paths and preserves unknown existing files")
    func pathSafety() throws {
        let longPath = "/tmp/\(String(repeating: "x", count: 110)).sock"
        #expect(throws: IPCTransportError.pathTooLong) {
            _ = try UnixSocketListener(socketURL: URL(fileURLWithPath: longPath))
        }

        let root = URL(fileURLWithPath: "/tmp/copilot-micro-existing-\(UUID().uuidString.prefix(8))")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let socketURL = root.appendingPathComponent("bridge.sock")
        try Data("preserve".utf8).write(to: socketURL)
        let listener = try UnixSocketListener(socketURL: socketURL)
        #expect(throws: IPCTransportError.addressInUse) {
            try listener.start()
        }
        #expect(try String(contentsOf: socketURL, encoding: .utf8) == "preserve")
    }

    @Test("Listener rejects a symlinked runtime directory")
    func symlinkedRuntimeDirectory() throws {
        let parent = URL(fileURLWithPath: "/tmp/copilot-micro-symlink-\(UUID().uuidString.prefix(8))")
        defer {
            try? FileManager.default.removeItem(at: parent)
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let linked = parent.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        let listener = try UnixSocketListener(
            socketURL: linked.appendingPathComponent("bridge.sock")
        )
        #expect(throws: IPCTransportError.permissionDenied) {
            try listener.start()
        }
    }

    @Test("Normal listener shutdown removes only its owned socket")
    func listenerCleanupAndRestart() async throws {
        try await withShortSocketDirectory { _, socketURL in
            let first = try UnixSocketListener(socketURL: socketURL)
            try first.start()
            #expect(FileManager.default.fileExists(atPath: socketURL.path))
            first.close()
            #expect(!FileManager.default.fileExists(atPath: socketURL.path))

            let second = try UnixSocketListener(socketURL: socketURL)
            try second.start()
            #expect(FileManager.default.fileExists(atPath: socketURL.path))
            second.close()
            #expect(!FileManager.default.fileExists(atPath: socketURL.path))
        }
    }
}

private func testToken() throws -> IPCBootstrapToken {
    try IPCBootstrapToken(
        rawValue: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    )
}

private func testBinding() throws -> LiveBinding {
    try LiveBinding(
        instanceID: CLIInstanceID(rawValue: "cli-instance-1"),
        sessionID: SessionID(rawValue: "session-1"),
        generation: ConnectionGeneration(rawValue: "generation-1")
    )
}

private func testRegistration(token: IPCBootstrapToken) throws -> IPCRegistration {
    try IPCRegistration(
        bootstrapToken: token,
        binding: testBinding(),
        bridgeVersion: "0.1.0",
        cliVersion: "1.0.84-5",
        sdkVersion: "host-provided"
    )
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
}

private func withShortSocketDirectory(
    _ body: (URL, URL) async throws -> Void
) async throws {
    let directory = URL(
        fileURLWithPath: "/tmp/copilot-micro-ipc-\(UUID().uuidString.prefix(8))",
        isDirectory: true
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try await body(directory, directory.appendingPathComponent("bridge.sock"))
}
