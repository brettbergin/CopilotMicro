import Foundation
import Testing

@testable import CopilotMicroStorage

@Suite("Bounded private diagnostics")
struct DiagnosticsTests {
    @Test("Events use bounded categories and redact planted sensitive content")
    func eventRedaction() throws {
        let secret = "github_pat_secret12345678"
        let prompt = "Summarize private acquisition plans"
        let event = try DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 1_000),
            component: .bridge,
            operation: "connect",
            capabilityVersion: "v1",
            correlationAlias: "host-2",
            outcome: .failed,
            errorCategory: .permissionDenied,
            message:
                "Bearer abc.def \(secret) /Users/example/repo prompt: \(prompt), command=/bin/rm -rf /tmp/private",
            sensitiveValues: [prompt]
        )
        let message = try #require(event.message)
        #expect(!message.contains(secret))
        #expect(!message.contains(prompt))
        #expect(!message.contains("/Users/example"))
        #expect(!message.contains("/bin/rm"))
        #expect(!message.contains("abc.def"))
        #expect(message.contains("[redacted]"))
    }

    @Test("Redaction covers common absolute macOS paths")
    func commonAbsolutePathsAreRedacted() {
        let message = DiagnosticRedactor.redact(
            """
            /Applications/Secret Terminal.app, /opt/homebrew/bin/copilot, \
            /Volumes/Private/repo, /Library/Application Support/Private
            """
        )
        #expect(!message.contains("/Applications"))
        #expect(!message.contains("/opt/homebrew"))
        #expect(!message.contains("/Volumes"))
        #expect(!message.contains("/Library"))
        #expect(message.contains("[redacted]"))
    }

    @Test("Rotation remains within the injected segment count and byte bound")
    func boundedRotation() async throws {
        try await withDiagnosticDirectory { root in
            let store = DiagnosticStore(
                directoryURL: root,
                maximumSegmentBytes: 360,
                maximumSegments: 3,
                now: { Date(timeIntervalSince1970: 2_000) }
            )
            for index in 0..<12 {
                let event = try DiagnosticEvent(
                    timestamp: Date(timeIntervalSince1970: Double(index)),
                    component: .configuration,
                    operation: "save",
                    correlationAlias: "config-\(index)",
                    outcome: .succeeded,
                    message:
                        index == 11
                        ? "github_pat_private123456 /Users/example/private command=/bin/rm"
                        : String(repeating: "safe ", count: 12)
                )
                try await store.append(event)
            }
            let files = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey]
            )
            #expect(files.count <= 3)
            for file in files {
                let size = try #require(
                    file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                )
                #expect(size <= 360)
                #expect(try permissions(at: file) == 0o600)
            }
            #expect(try permissions(at: root) == 0o700)

            let exported = try await store.exportData()
            let text = String(decoding: exported, as: UTF8.self)
            #expect(text.contains(#""schemaVersion":1"#))
            #expect(text.contains(#""product":"Copilot Micro""#))
            #expect(!text.contains("github_pat_"))
            #expect(!text.contains("/Users/example"))
            #expect(!text.contains("/bin/rm"))
        }
    }

    @Test("Clearing diagnostics cannot remove sibling recovery material")
    func clearIsDirectoryScoped() async throws {
        try await withDiagnosticDirectory { diagnostics in
            let applicationSupport = diagnostics.deletingLastPathComponent()
            let backup = applicationSupport.appendingPathComponent("backups/original.json")
            try FileManager.default.createDirectory(
                at: backup.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("preserve".utf8).write(to: backup)

            let store = DiagnosticStore(directoryURL: diagnostics)
            let event = try DiagnosticEvent(
                timestamp: Date(),
                component: .application,
                operation: "launch",
                outcome: .succeeded
            )
            try await store.append(event)
            try await store.clear()
            #expect(FileManager.default.fileExists(atPath: backup.path))
            #expect(
                try FileManager.default.contentsOfDirectory(
                    at: diagnostics,
                    includingPropertiesForKeys: nil
                ).isEmpty
            )
        }
    }

    @Test("A symlinked diagnostics directory is rejected")
    func symlinkedDirectoryIsRejected() async throws {
        try await withDiagnosticDirectory { diagnostics in
            let outside = diagnostics.deletingLastPathComponent().appendingPathComponent(
                "outside",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: diagnostics,
                withDestinationURL: outside
            )
            let store = DiagnosticStore(directoryURL: diagnostics)
            let event = try DiagnosticEvent(
                timestamp: Date(),
                component: .application,
                operation: "launch",
                outcome: .succeeded
            )
            await #expect(throws: DiagnosticError.fileSystem) {
                try await store.append(event)
            }
        }
    }

    @Test("Append revalidates and redacts decoded diagnostic input")
    func decodedEventsCannotBypassRedaction() async throws {
        try await withDiagnosticDirectory { diagnostics in
            let raw = """
                {
                  "schemaVersion": 999,
                  "timestamp": "1970-01-01T00:00:00Z",
                  "component": "application",
                  "operation": "launch",
                  "outcome": "failed",
                  "errorCategory": "internalFailure",
                  "message": "github_pat_private123456 /Users/example/private"
                }
                """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let event = try decoder.decode(DiagnosticEvent.self, from: Data(raw.utf8))
            let store = DiagnosticStore(directoryURL: diagnostics)
            try await store.append(event)
            let export = String(decoding: try await store.exportData(), as: UTF8.self)
            #expect(!export.contains("github_pat_"))
            #expect(!export.contains("/Users/example"))
            #expect(export.contains(#""schemaVersion":1"#))
        }
    }

    @Test("Diagnostic exports cannot overwrite app-managed storage")
    func exportRejectsManagedDestinations() async throws {
        try await withDiagnosticDirectory { diagnostics in
            let store = DiagnosticStore(directoryURL: diagnostics)
            let event = try DiagnosticEvent(
                timestamp: Date(),
                component: .application,
                operation: "launch",
                outcome: .succeeded
            )
            try await store.append(event)
            let applicationSupport = diagnostics.deletingLastPathComponent()
            let segment = diagnostics.appendingPathComponent("segment-0.jsonl")
            let configuration = applicationSupport.appendingPathComponent("config.json")

            await #expect(throws: DiagnosticError.fileSystem) {
                try await store.writeExport(to: segment)
            }
            await #expect(throws: DiagnosticError.fileSystem) {
                try await store.writeExport(to: configuration)
            }

            let destination = applicationSupport.deletingLastPathComponent().appendingPathComponent(
                "copilot-micro-diagnostics-\(UUID().uuidString).json"
            )
            defer {
                try? FileManager.default.removeItem(at: destination)
            }
            try await store.writeExport(to: destination)
            #expect(FileManager.default.fileExists(atPath: destination.path))
            #expect(try permissions(at: destination) == 0o600)
        }
    }
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
}

private func withDiagnosticDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "copilot-micro-diagnostics-\(UUID().uuidString)",
        isDirectory: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try await body(root.appendingPathComponent("diagnostics", isDirectory: true))
}
