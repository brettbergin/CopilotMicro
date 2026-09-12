import CopilotMicroBridge
import Foundation
import Testing

@Suite("Private bridge bootstrap material")
struct BootstrapStoreTests {
    @Test("Bootstrap material is stable, separate and user-only")
    func stableProtectedToken() async throws {
        try await withTemporaryRoot { root in
            let firstStore = IPCBootstrapStore(rootURL: root)
            let secondStore = IPCBootstrapStore(rootURL: root)
            async let firstResult = firstStore.loadOrCreate()
            async let secondResult = secondStore.loadOrCreate()
            let first = try await firstResult
            let second = try await secondResult
            #expect(first == second)

            let directoryURL = await firstStore.directoryURL
            let tokenURL = await firstStore.tokenURL
            #expect(try permissions(at: root) == 0o700)
            #expect(try permissions(at: directoryURL) == 0o700)
            #expect(try permissions(at: tokenURL) == 0o600)
            #expect(tokenURL.lastPathComponent == IPCBootstrapStore.filename)
            #expect(!tokenURL.path.contains("config.json"))
        }
    }

    @Test("Malformed and symlinked bootstrap material fails closed")
    func invalidMaterialIsRejected() async throws {
        try await withTemporaryRoot { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let bridge = root.appendingPathComponent("bridge", isDirectory: true)
            try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: false)
            let tokenURL = bridge.appendingPathComponent(IPCBootstrapStore.filename)
            try Data("short".utf8).write(to: tokenURL)
            let malformed = IPCBootstrapStore(rootURL: root)
            await #expect(throws: IPCBootstrapStoreError.malformed) {
                _ = try await malformed.loadOrCreate()
            }

            try FileManager.default.removeItem(at: tokenURL)
            let outside = root.appendingPathComponent("outside")
            try Data(String(repeating: "a", count: 64).utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(
                at: tokenURL,
                withDestinationURL: outside
            )
            let symlinked = IPCBootstrapStore(rootURL: root)
            await #expect(throws: IPCBootstrapStoreError.malformed) {
                _ = try await symlinked.loadOrCreate()
            }
        }
    }
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
}

private func withTemporaryRoot(
    _ body: (URL) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "copilot-micro-bootstrap-\(UUID().uuidString)",
        isDirectory: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try await body(root)
}
