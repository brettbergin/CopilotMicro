import Foundation
import Testing

@testable import CopilotMicroStorage

@Suite("Device keymap backup storage")
struct DeviceBackupStoreTests {
    @Test("Original and recovery backups round-trip one integrity envelope")
    func roundTrip() async throws {
        try await withDeviceBackupTemporaryDirectory { root in
            let store = DeviceBackupStore(rootURL: root)
            let metadata = try makeMetadata()
            let match = try makeMatch()
            let originalBytes = Data([0x00, 0x7B, 0xFF, 0x0A, 0x42])
            let snapshotBytes = Data(#"{"layers":[["key-a"]]}"#.utf8)

            let saved = try await store.saveOriginal(originalBytes, metadata: metadata)
            #expect(saved == DeviceBackup(metadata: metadata, keymap: originalBytes))
            #expect(try await store.loadOriginal(matching: match) == saved)

            let snapshotMetadata = try makeMetadata(createdAtOffset: 1)
            let snapshot = try await store.savePreChangeSnapshot(
                snapshotBytes,
                metadata: snapshotMetadata
            )
            #expect(try await store.loadRecoverySnapshots(matching: match) == [snapshot])

            let envelope = try #require(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: originalURL(root: root))
                ) as? [String: Any]
            )
            #expect(Set(envelope.keys) == Set(["metadata", "payload", "sha256"]))
            #expect(envelope["payload"] as? String == originalBytes.base64EncodedString())
            #expect((envelope["sha256"] as? String)?.count == 64)
            #expect(
                !String(decoding: try Data(contentsOf: originalURL(root: root)), as: UTF8.self)
                    .localizedCaseInsensitiveContains("serial"))
        }
    }

    @Test("Missing, corrupt, and structurally invalid originals are rejected")
    func corruptBackupsAreRejected() async throws {
        try await withDeviceBackupTemporaryDirectory { root in
            let store = DeviceBackupStore(rootURL: root)
            let match = try makeMatch()

            await #expect(throws: DeviceBackupError.missingOriginalBackup) {
                _ = try await store.loadOriginal(matching: match)
            }

            let metadata = try makeMetadata()
            try await store.saveOriginal(Data("original".utf8), metadata: metadata)
            let url = originalURL(root: root)
            let validEnvelope = try Data(contentsOf: url)

            try mutateEnvelope(at: url) { root in
                root["sha256"] = String(repeating: "0", count: 64)
            }
            await #expect(throws: DeviceBackupError.corruptBackup) {
                _ = try await store.loadOriginal(matching: match)
            }

            try validEnvelope.write(to: url, options: [.atomic])
            try mutateEnvelope(at: url) { root in
                var storedMetadata = try #require(root["metadata"] as? [String: Any])
                storedMetadata["unexpected"] = true
                root["metadata"] = storedMetadata
            }
            await #expect(throws: DeviceBackupError.corruptBackup) {
                _ = try await store.loadOriginal(matching: match)
            }

            try validEnvelope.write(to: url, options: [.atomic])
            try mutateEnvelope(at: url) { root in
                var storedMetadata = try #require(root["metadata"] as? [String: Any])
                storedMetadata["schemaVersion"] = 2
                root["metadata"] = storedMetadata
            }
            await #expect(throws: DeviceBackupError.unsupportedBackupSchemaVersion(2)) {
                _ = try await store.loadOriginal(matching: match)
            }
        }
    }

    @Test("Association, product, and keymap schema mismatches fail closed")
    func mismatchesAreRejected() async throws {
        try await withDeviceBackupTemporaryDirectory { root in
            let store = DeviceBackupStore(rootURL: root)
            try await store.saveOriginal(
                Data("original".utf8),
                metadata: makeMetadata()
            )

            await #expect(throws: DeviceBackupError.productMismatch) {
                _ = try await store.loadOriginal(
                    matching: makeMatch(productID: 0x8297)
                )
            }
            await #expect(throws: DeviceBackupError.keymapSchemaMismatch) {
                _ = try await store.loadOriginal(
                    matching: makeMatch(keymapSchemaVersion: 2)
                )
            }

            let otherAssociationID = String(repeating: "b", count: 64)
            let otherDirectory = root.appendingPathComponent(
                otherAssociationID,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: otherDirectory,
                withIntermediateDirectories: false
            )
            try FileManager.default.copyItem(
                at: originalURL(root: root),
                to: otherDirectory.appendingPathComponent(
                    DeviceBackupStore.originalFilename,
                    isDirectory: false
                )
            )
            await #expect(throws: DeviceBackupError.deviceAssociationMismatch) {
                _ = try await store.loadOriginal(
                    matching: makeMatch(deviceAssociationID: otherAssociationID)
                )
            }
        }
    }

    @Test("The original backup is created once and never overwritten")
    func originalIsNeverOverwritten() async throws {
        try await withDeviceBackupTemporaryDirectory { root in
            let store = DeviceBackupStore(rootURL: root)
            let metadata = try makeMetadata()
            let match = try makeMatch()
            let original = Data("original".utf8)
            try await store.saveOriginal(original, metadata: metadata)

            await #expect(throws: DeviceBackupError.originalBackupAlreadyExists) {
                try await store.saveOriginal(Data("replacement".utf8), metadata: metadata)
            }
            #expect(try await store.loadOriginal(matching: match).keymap == original)
        }
    }

    @Test("Recovery history retains only the five newest atomic snapshots")
    func recoveryHistoryIsBounded() async throws {
        try await withDeviceBackupTemporaryDirectory { root in
            let store = DeviceBackupStore(rootURL: root)
            let match = try makeMatch()
            try await store.saveOriginal(
                Data("original".utf8),
                metadata: makeMetadata()
            )

            for index in 0..<7 {
                try await store.savePreChangeSnapshot(
                    Data([UInt8(index)]),
                    metadata: makeMetadata(createdAtOffset: index + 1)
                )
            }

            let snapshots = try await store.loadRecoverySnapshots(matching: match)
            #expect(snapshots.count == DeviceBackupStore.maximumRecoverySnapshots)
            #expect(snapshots.map(\.keymap) == (2...6).reversed().map { Data([UInt8($0)]) })
            #expect(
                try FileManager.default.contentsOfDirectory(
                    at: recoveryDirectoryURL(root: root),
                    includingPropertiesForKeys: nil
                ).count == DeviceBackupStore.maximumRecoverySnapshots
            )
        }
    }

    @Test("Managed directories and backup files are user-only")
    func permissionsAreUserOnly() async throws {
        try await withDeviceBackupTemporaryDirectory { root in
            let store = DeviceBackupStore(rootURL: root)
            try await store.saveOriginal(
                Data("original".utf8),
                metadata: makeMetadata()
            )
            try await store.savePreChangeSnapshot(
                Data("snapshot".utf8),
                metadata: makeMetadata(createdAtOffset: 1)
            )

            let deviceDirectory = root.appendingPathComponent(
                deviceAssociationID,
                isDirectory: true
            )
            let recoveryDirectory = recoveryDirectoryURL(root: root)
            let snapshot = try #require(
                FileManager.default.contentsOfDirectory(
                    at: recoveryDirectory,
                    includingPropertiesForKeys: nil
                ).first
            )
            #expect(try permissions(at: root) == 0o700)
            #expect(try permissions(at: deviceDirectory) == 0o700)
            #expect(try permissions(at: recoveryDirectory) == 0o700)
            #expect(try permissions(at: originalURL(root: root)) == 0o600)
            #expect(try permissions(at: snapshot) == 0o600)
        }
    }

    @Test("Symlinked roots, originals, and recovery entries are rejected")
    func symlinksAreRejected() async throws {
        try await withDeviceBackupTemporaryDirectory { container in
            let outside = container.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let linkedRoot = container.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: linkedRoot,
                withDestinationURL: outside
            )
            let linkedStore = DeviceBackupStore(rootURL: linkedRoot)
            await #expect(throws: DeviceBackupError.unsafeFileSystemEntry) {
                try await linkedStore.saveOriginal(
                    Data("original".utf8),
                    metadata: makeMetadata()
                )
            }

            let fileRoot = container.appendingPathComponent("file-root", isDirectory: true)
            let fileStore = DeviceBackupStore(rootURL: fileRoot)
            let match = try makeMatch()
            try await fileStore.saveOriginal(
                Data("original".utf8),
                metadata: makeMetadata()
            )
            let original = originalURL(root: fileRoot)
            try FileManager.default.removeItem(at: original)
            let outsideFile = outside.appendingPathComponent("outside.json")
            try Data("outside".utf8).write(to: outsideFile)
            try FileManager.default.createSymbolicLink(
                at: original,
                withDestinationURL: outsideFile
            )
            await #expect(throws: DeviceBackupError.unsafeFileSystemEntry) {
                _ = try await fileStore.loadOriginal(matching: match)
            }

            let recoveryRoot = container.appendingPathComponent(
                "recovery-root",
                isDirectory: true
            )
            let recoveryStore = DeviceBackupStore(rootURL: recoveryRoot)
            try await recoveryStore.saveOriginal(
                Data("original".utf8),
                metadata: makeMetadata()
            )
            try FileManager.default.createSymbolicLink(
                at: recoveryDirectoryURL(root: recoveryRoot)
                    .appendingPathComponent("snapshot-linked.json"),
                withDestinationURL: outsideFile
            )
            await #expect(throws: DeviceBackupError.unsafeFileSystemEntry) {
                _ = try await recoveryStore.loadRecoverySnapshots(matching: match)
            }
        }
    }

    @Test("Metadata and payload bounds are enforced before storage")
    func boundsAreEnforced() async throws {
        #expect(throws: DeviceBackupError.invalidDeviceAssociationID) {
            _ = try makeMetadata(deviceAssociationID: String(repeating: "A", count: 64))
        }
        #expect(throws: DeviceBackupError.unsupportedProductID) {
            _ = try makeMetadata(productID: 0x0001)
        }
        #expect(throws: DeviceBackupError.invalidFirmwareVersion) {
            _ = try makeMetadata(firmwareVersion: "0.6.2\n")
        }
        #expect(throws: DeviceBackupError.invalidFirmwareVersion) {
            _ = try makeMetadata(
                firmwareVersion: String(
                    repeating: "x",
                    count: DeviceBackupMetadata.maximumFirmwareBytes + 1
                )
            )
        }
        #expect(throws: DeviceBackupError.invalidKeymapSchemaVersion) {
            _ = try makeMetadata(keymapSchemaVersion: 0)
        }
        #expect(throws: DeviceBackupError.invalidTimestamp) {
            _ = try makeMetadata(createdAtOffset: -2_000_000_000)
        }

        try await withDeviceBackupTemporaryDirectory { root in
            let store = DeviceBackupStore(rootURL: root)
            let metadata = try makeMetadata()
            await #expect(throws: DeviceBackupError.invalidPayload) {
                try await store.saveOriginal(Data(), metadata: metadata)
            }
            await #expect(throws: DeviceBackupError.payloadTooLarge) {
                try await store.saveOriginal(
                    Data(
                        repeating: 0x41,
                        count: DeviceBackupStore.maximumKeymapBytes + 1
                    ),
                    metadata: metadata
                )
            }
            #expect(!FileManager.default.fileExists(atPath: originalURL(root: root).path))
        }
    }

    @Test("A pre-rename interruption leaves the original and history intact")
    func interruptedWriteIsAtomic() async throws {
        try await withDeviceBackupTemporaryDirectory { root in
            let initialStore = DeviceBackupStore(rootURL: root)
            let original = Data("original".utf8)
            let match = try makeMatch()
            try await initialStore.saveOriginal(original, metadata: makeMetadata())

            let interruptedStore = DeviceBackupStore(
                rootURL: root,
                beforeAtomicRename: { throw DeviceBackupError.fileSystem }
            )
            await #expect(throws: DeviceBackupError.fileSystem) {
                try await interruptedStore.savePreChangeSnapshot(
                    Data("snapshot".utf8),
                    metadata: makeMetadata(createdAtOffset: 1)
                )
            }

            #expect(try await initialStore.loadOriginal(matching: match).keymap == original)
            #expect(try await initialStore.loadRecoverySnapshots(matching: match).isEmpty)
            #expect(
                try FileManager.default.contentsOfDirectory(
                    at: recoveryDirectoryURL(root: root),
                    includingPropertiesForKeys: nil
                ).allSatisfy { !$0.lastPathComponent.hasSuffix(".tmp") }
            )
        }
    }
}

private let deviceAssociationID = String(repeating: "a", count: 64)
private let baseTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

private func makeMetadata(
    deviceAssociationID: String = deviceAssociationID,
    productID: Int = 0x8298,
    firmwareVersion: String = "0.6.2",
    keymapSchemaVersion: Int = 1,
    createdAtOffset: Int = 0
) throws -> DeviceBackupMetadata {
    try DeviceBackupMetadata(
        deviceAssociationID: deviceAssociationID,
        productID: productID,
        firmwareVersion: firmwareVersion,
        keymapSchemaVersion: keymapSchemaVersion,
        createdAt: baseTimestamp.addingTimeInterval(TimeInterval(createdAtOffset))
    )
}

private func makeMatch(
    deviceAssociationID: String = deviceAssociationID,
    productID: Int = 0x8298,
    keymapSchemaVersion: Int = 1
) throws -> DeviceBackupMatch {
    try DeviceBackupMatch(
        deviceAssociationID: deviceAssociationID,
        productID: productID,
        keymapSchemaVersion: keymapSchemaVersion
    )
}

private func originalURL(root: URL) -> URL {
    root.appendingPathComponent(deviceAssociationID, isDirectory: true)
        .appendingPathComponent(DeviceBackupStore.originalFilename, isDirectory: false)
}

private func recoveryDirectoryURL(root: URL) -> URL {
    root.appendingPathComponent(deviceAssociationID, isDirectory: true)
        .appendingPathComponent(DeviceBackupStore.recoveryDirectoryName, isDirectory: true)
}

private func mutateEnvelope(
    at url: URL,
    mutation: (inout [String: Any]) throws -> Void
) throws {
    var root = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    try mutation(&root)
    try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        .write(to: url, options: [.atomic])
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
}

private func withDeviceBackupTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "copilot-micro-device-backups-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try await body(root)
}
