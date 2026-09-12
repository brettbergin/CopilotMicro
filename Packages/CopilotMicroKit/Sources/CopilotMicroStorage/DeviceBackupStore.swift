import CryptoKit
import Darwin
import Foundation

public struct DeviceBackupMetadata: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumFirmwareBytes = 64
    public static let maximumKeymapSchemaVersion = 1_000_000
    public static let supportedProductIDs: Set<Int> = [0x8297, 0x8298]

    public let schemaVersion: Int
    public let deviceAssociationID: String
    public let productID: Int
    public let firmwareVersion: String
    public let keymapSchemaVersion: Int
    public let createdAtUnixMilliseconds: Int64

    public init(
        deviceAssociationID: String,
        productID: Int,
        firmwareVersion: String,
        keymapSchemaVersion: Int,
        createdAt: Date = Date()
    ) throws {
        schemaVersion = Self.schemaVersion
        self.deviceAssociationID = deviceAssociationID
        self.productID = productID
        self.firmwareVersion = firmwareVersion
        self.keymapSchemaVersion = keymapSchemaVersion
        let timestamp = createdAt.timeIntervalSince1970 * 1_000
        guard
            timestamp.isFinite,
            timestamp >= 0,
            timestamp <= 253_402_300_799_999
        else {
            throw DeviceBackupError.invalidTimestamp
        }
        createdAtUnixMilliseconds = Int64(timestamp.rounded(.towardZero))
        try DeviceBackupValidation.validate(self)
    }

    public var createdAt: Date {
        Date(timeIntervalSince1970: Double(createdAtUnixMilliseconds) / 1_000)
    }
}

public struct DeviceBackupMatch: Equatable, Sendable {
    public let deviceAssociationID: String
    public let productID: Int
    public let keymapSchemaVersion: Int

    public init(
        deviceAssociationID: String,
        productID: Int,
        keymapSchemaVersion: Int
    ) throws {
        self.deviceAssociationID = deviceAssociationID
        self.productID = productID
        self.keymapSchemaVersion = keymapSchemaVersion
        try DeviceBackupValidation.validate(self)
    }
}

public struct DeviceBackup: Equatable, Sendable {
    public let metadata: DeviceBackupMetadata
    public let keymap: Data

    public init(metadata: DeviceBackupMetadata, keymap: Data) {
        self.metadata = metadata
        self.keymap = keymap
    }
}

public enum DeviceBackupError: Error, Equatable, LocalizedError, Sendable {
    case invalidDeviceAssociationID
    case unsupportedProductID
    case invalidFirmwareVersion
    case invalidKeymapSchemaVersion
    case invalidTimestamp
    case invalidPayload
    case payloadTooLarge
    case unsupportedBackupSchemaVersion(Int)
    case missingOriginalBackup
    case originalBackupAlreadyExists
    case corruptBackup
    case deviceAssociationMismatch
    case productMismatch
    case keymapSchemaMismatch
    case unsafeFileSystemEntry
    case fileSystem

    public var errorDescription: String? {
        switch self {
        case .invalidDeviceAssociationID:
            "The device does not expose a valid private association identifier."
        case .unsupportedProductID:
            "The backup product identifier is not supported."
        case .invalidFirmwareVersion:
            "The backup firmware version is invalid."
        case .invalidKeymapSchemaVersion:
            "The backup keymap schema version is invalid."
        case .invalidTimestamp:
            "The backup timestamp is invalid."
        case .invalidPayload:
            "The backup keymap is empty or invalid."
        case .payloadTooLarge:
            "The backup exceeds the keymap safety limit."
        case .unsupportedBackupSchemaVersion(let version):
            "Backup schema \(version) is not supported."
        case .missingOriginalBackup:
            "No verified original keymap backup exists for this device."
        case .originalBackupAlreadyExists:
            "The original keymap backup already exists and was not overwritten."
        case .corruptBackup:
            "The device backup failed its integrity check."
        case .deviceAssociationMismatch:
            "The backup belongs to a different physical device."
        case .productMismatch:
            "The backup belongs to a different device product."
        case .keymapSchemaMismatch:
            "The backup uses a different keymap schema."
        case .unsafeFileSystemEntry:
            "The backup path contains an unsafe file-system entry."
        case .fileSystem:
            "The device backup could not be read or written."
        }
    }
}

public actor DeviceBackupStore {
    public static let originalFilename = "original.json"
    public static let recoveryDirectoryName = "recovery"
    public static let maximumRecoverySnapshots = 5
    public static let maximumKeymapBytes = 524_288
    public static let maximumEnvelopeBytes =
        ((maximumKeymapBytes + 2) / 3 * 4) + 4_096

    public let rootURL: URL

    private let beforeAtomicRename: @Sendable () throws -> Void

    public init(rootURL: URL) {
        self.init(rootURL: rootURL, beforeAtomicRename: {})
    }

    init(
        rootURL: URL,
        beforeAtomicRename: @escaping @Sendable () throws -> Void
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.beforeAtomicRename = beforeAtomicRename
    }

    public static func defaultRootURL(fileManager: FileManager = .default) throws -> URL {
        guard
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw DeviceBackupError.fileSystem
        }
        return
            applicationSupport
            .appendingPathComponent("Copilot Micro", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("device-keymaps", isDirectory: true)
    }

    @discardableResult
    public func saveOriginal(
        _ keymap: Data,
        metadata: DeviceBackupMetadata
    ) throws -> DeviceBackup {
        do {
            let envelope = try encodedEnvelope(keymap: keymap, metadata: metadata)
            try prepareDirectories(for: metadata.deviceAssociationID)
            let destination = originalURL(for: metadata.deviceAssociationID)
            switch try entryKind(at: destination) {
            case .missing:
                break
            case .regular:
                throw DeviceBackupError.originalBackupAlreadyExists
            case .directory, .symbolicLink, .other:
                throw DeviceBackupError.unsafeFileSystemEntry
            }
            try atomicCreate(envelope, at: destination)
            return DeviceBackup(metadata: metadata, keymap: keymap)
        } catch let error as DeviceBackupError {
            throw error
        } catch {
            throw DeviceBackupError.fileSystem
        }
    }

    @discardableResult
    public func savePreChangeSnapshot(
        _ keymap: Data,
        metadata: DeviceBackupMetadata
    ) throws -> DeviceBackup {
        do {
            let match = try DeviceBackupMatch(
                deviceAssociationID: metadata.deviceAssociationID,
                productID: metadata.productID,
                keymapSchemaVersion: metadata.keymapSchemaVersion
            )
            _ = try loadOriginal(matching: match)
            _ = try loadRecoverySnapshots(matching: match)
            let envelope = try encodedEnvelope(keymap: keymap, metadata: metadata)
            let destination = recoveryDirectoryURL(for: metadata.deviceAssociationID)
                .appendingPathComponent(snapshotFilename(for: metadata), isDirectory: false)
            try atomicCreate(envelope, at: destination)
            try trimRecoverySnapshots(for: metadata.deviceAssociationID)
            return DeviceBackup(metadata: metadata, keymap: keymap)
        } catch let error as DeviceBackupError {
            throw error
        } catch {
            throw DeviceBackupError.fileSystem
        }
    }

    public func loadOriginal(matching match: DeviceBackupMatch) throws -> DeviceBackup {
        do {
            try prepareDirectories(for: match.deviceAssociationID)
            let source = originalURL(for: match.deviceAssociationID)
            guard try entryKind(at: source) != .missing else {
                throw DeviceBackupError.missingOriginalBackup
            }
            return try loadAndVerify(source, matching: match)
        } catch let error as DeviceBackupError {
            throw error
        } catch {
            throw DeviceBackupError.fileSystem
        }
    }

    public func loadRecoverySnapshots(
        matching match: DeviceBackupMatch
    ) throws -> [DeviceBackup] {
        do {
            try prepareDirectories(for: match.deviceAssociationID)
            let urls = try recoverySnapshotURLs(for: match.deviceAssociationID)
            let backups = try urls.map { try loadAndVerify($0, matching: match) }
            if urls.count > Self.maximumRecoverySnapshots {
                try removeRecoverySnapshots(
                    Array(urls.dropFirst(Self.maximumRecoverySnapshots)),
                    associationID: match.deviceAssociationID
                )
            }
            return Array(backups.prefix(Self.maximumRecoverySnapshots))
        } catch let error as DeviceBackupError {
            throw error
        } catch {
            throw DeviceBackupError.fileSystem
        }
    }

    private func loadAndVerify(
        _ source: URL,
        matching match: DeviceBackupMatch
    ) throws -> DeviceBackup {
        let data = try readBoundedRegularFile(
            at: source,
            maximumBytes: Self.maximumEnvelopeBytes
        )
        let backup = try decodeEnvelope(data)
        guard backup.metadata.deviceAssociationID == match.deviceAssociationID else {
            throw DeviceBackupError.deviceAssociationMismatch
        }
        guard backup.metadata.productID == match.productID else {
            throw DeviceBackupError.productMismatch
        }
        guard backup.metadata.keymapSchemaVersion == match.keymapSchemaVersion else {
            throw DeviceBackupError.keymapSchemaMismatch
        }
        return backup
    }

    private func encodedEnvelope(
        keymap: Data,
        metadata: DeviceBackupMetadata
    ) throws -> Data {
        try DeviceBackupValidation.validate(metadata)
        try DeviceBackupValidation.validatePayload(keymap, maximumBytes: Self.maximumKeymapBytes)
        let envelope = DeviceBackupEnvelope(
            metadata: metadata,
            payload: keymap.base64EncodedString(),
            sha256: Self.sha256Hex(keymap)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw DeviceBackupError.payloadTooLarge
        }
        return data
    }

    private func decodeEnvelope(_ data: Data) throws -> DeviceBackup {
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw DeviceBackupError.payloadTooLarge
        }
        do {
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(root.keys) == Set(["metadata", "payload", "sha256"]),
                let metadata = root["metadata"] as? [String: Any],
                Set(metadata.keys)
                    == Set([
                        "schemaVersion",
                        "deviceAssociationID",
                        "productID",
                        "firmwareVersion",
                        "keymapSchemaVersion",
                        "createdAtUnixMilliseconds",
                    ])
            else {
                throw DeviceBackupError.corruptBackup
            }
            let envelope = try JSONDecoder().decode(DeviceBackupEnvelope.self, from: data)
            guard envelope.metadata.schemaVersion == DeviceBackupMetadata.schemaVersion else {
                throw DeviceBackupError.unsupportedBackupSchemaVersion(
                    envelope.metadata.schemaVersion
                )
            }
            do {
                try DeviceBackupValidation.validate(envelope.metadata)
            } catch DeviceBackupError.unsupportedBackupSchemaVersion(let version) {
                throw DeviceBackupError.unsupportedBackupSchemaVersion(version)
            } catch {
                throw DeviceBackupError.corruptBackup
            }
            guard
                DeviceBackupValidation.isLowercaseSHA256(envelope.sha256),
                let payload = Data(base64Encoded: envelope.payload),
                payload.base64EncodedString() == envelope.payload
            else {
                throw DeviceBackupError.corruptBackup
            }
            guard !payload.isEmpty else {
                throw DeviceBackupError.corruptBackup
            }
            guard payload.count <= Self.maximumKeymapBytes else {
                throw DeviceBackupError.payloadTooLarge
            }
            guard Self.sha256Hex(payload) == envelope.sha256 else {
                throw DeviceBackupError.corruptBackup
            }
            return DeviceBackup(metadata: envelope.metadata, keymap: payload)
        } catch let error as DeviceBackupError {
            throw error
        } catch {
            throw DeviceBackupError.corruptBackup
        }
    }

    private func prepareDirectories(for associationID: String) throws {
        guard DeviceBackupValidation.isDeviceAssociationID(associationID) else {
            throw DeviceBackupError.invalidDeviceAssociationID
        }
        try prepareRootDirectory()
        try prepareProtectedDirectory(deviceDirectoryURL(for: associationID))
        try prepareProtectedDirectory(recoveryDirectoryURL(for: associationID))
    }

    private func prepareRootDirectory() throws {
        var missing: [URL] = []
        var candidate = rootURL
        while true {
            switch try entryKind(at: candidate) {
            case .directory:
                if candidate == rootURL {
                    try setPermissions(0o700, at: candidate)
                }
                for directory in missing.reversed() {
                    try createProtectedDirectory(directory)
                }
                return
            case .missing:
                missing.append(candidate)
                let parent = candidate.deletingLastPathComponent()
                guard parent.path != candidate.path else {
                    throw DeviceBackupError.fileSystem
                }
                candidate = parent
            case .regular, .symbolicLink, .other:
                throw DeviceBackupError.unsafeFileSystemEntry
            }
        }
    }

    private func prepareProtectedDirectory(_ url: URL) throws {
        switch try entryKind(at: url) {
        case .directory:
            try setPermissions(0o700, at: url)
        case .missing:
            try createProtectedDirectory(url)
        case .regular, .symbolicLink, .other:
            throw DeviceBackupError.unsafeFileSystemEntry
        }
    }

    private func createProtectedDirectory(_ url: URL) throws {
        let result = url.path.withCString { mkdir($0, mode_t(0o700)) }
        if result != 0 {
            guard errno == EEXIST, try entryKind(at: url) == .directory else {
                throw DeviceBackupError.fileSystem
            }
        }
        try setPermissions(0o700, at: url)
    }

    private func atomicCreate(_ data: Data, at destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try prepareProtectedDirectory(directory)
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw DeviceBackupError.fileSystem
        }
        var shouldRemoveTemporary = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemoveTemporary {
                _ = temporary.path.withCString { Darwin.unlink($0) }
            }
        }
        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw DeviceBackupError.fileSystem
        }
        try beforeAtomicRename()
        let renameResult = temporary.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard renameResult == 0 else {
            if errno == EEXIST, destination.lastPathComponent == Self.originalFilename {
                throw DeviceBackupError.originalBackupAlreadyExists
            }
            if errno == EEXIST {
                throw DeviceBackupError.fileSystem
            }
            throw DeviceBackupError.fileSystem
        }
        shouldRemoveTemporary = false
        try setPermissions(0o600, at: destination)
        try synchronizeDirectory(directory)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw DeviceBackupError.fileSystem
                }
                offset += written
            }
        }
    }

    private func readBoundedRegularFile(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        switch try entryKind(at: url) {
        case .regular:
            break
        case .missing:
            throw DeviceBackupError.fileSystem
        case .directory, .symbolicLink, .other:
            throw DeviceBackupError.unsafeFileSystemEntry
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw DeviceBackupError.unsafeFileSystemEntry
            }
            throw DeviceBackupError.fileSystem
        }
        defer {
            _ = Darwin.close(descriptor)
        }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw DeviceBackupError.fileSystem
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            throw DeviceBackupError.unsafeFileSystemEntry
        }
        guard information.st_size >= 0, information.st_size <= Int64(maximumBytes) else {
            throw DeviceBackupError.payloadTooLarge
        }
        var data = Data()
        data.reserveCapacity(Int(information.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw DeviceBackupError.fileSystem
            }
            guard count > 0 else {
                break
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else {
                throw DeviceBackupError.payloadTooLarge
            }
        }
        return data
    }

    private func recoverySnapshotURLs(for associationID: String) throws -> [URL] {
        let directory = recoveryDirectoryURL(for: associationID)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in urls {
            guard
                url.lastPathComponent.hasPrefix("snapshot-"),
                url.pathExtension == "json",
                try entryKind(at: url) == .regular
            else {
                throw DeviceBackupError.unsafeFileSystemEntry
            }
        }
        return urls.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func trimRecoverySnapshots(for associationID: String) throws {
        let urls = try recoverySnapshotURLs(for: associationID)
        guard urls.count > Self.maximumRecoverySnapshots else {
            return
        }
        try removeRecoverySnapshots(
            Array(urls.dropFirst(Self.maximumRecoverySnapshots)),
            associationID: associationID
        )
    }

    private func removeRecoverySnapshots(
        _ urls: [URL],
        associationID: String
    ) throws {
        for url in urls {
            guard try entryKind(at: url) == .regular else {
                throw DeviceBackupError.unsafeFileSystemEntry
            }
            guard url.path.withCString({ Darwin.unlink($0) }) == 0 else {
                throw DeviceBackupError.fileSystem
            }
        }
        try synchronizeDirectory(recoveryDirectoryURL(for: associationID))
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw DeviceBackupError.fileSystem
        }
        defer {
            _ = Darwin.close(descriptor)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw DeviceBackupError.fileSystem
        }
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        guard
            url.path.withCString({
                Darwin.chmod($0, mode_t(permissions))
            }) == 0
        else {
            throw DeviceBackupError.fileSystem
        }
    }

    private func entryKind(at url: URL) throws -> FileSystemEntryKind {
        var information = stat()
        let result = url.path.withCString { Darwin.lstat($0, &information) }
        if result != 0 {
            if errno == ENOENT {
                return .missing
            }
            throw DeviceBackupError.fileSystem
        }
        switch information.st_mode & S_IFMT {
        case S_IFREG:
            return .regular
        case S_IFDIR:
            return .directory
        case S_IFLNK:
            return .symbolicLink
        default:
            return .other
        }
    }

    private func deviceDirectoryURL(for associationID: String) -> URL {
        rootURL.appendingPathComponent(associationID, isDirectory: true)
    }

    private func originalURL(for associationID: String) -> URL {
        deviceDirectoryURL(for: associationID)
            .appendingPathComponent(Self.originalFilename, isDirectory: false)
    }

    private func recoveryDirectoryURL(for associationID: String) -> URL {
        deviceDirectoryURL(for: associationID)
            .appendingPathComponent(Self.recoveryDirectoryName, isDirectory: true)
    }

    private func snapshotFilename(for metadata: DeviceBackupMetadata) -> String {
        let timestamp = String(format: "%020lld", metadata.createdAtUnixMilliseconds)
        return "snapshot-\(timestamp)-\(UUID().uuidString.lowercased()).json"
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private enum FileSystemEntryKind: Equatable {
    case missing
    case regular
    case directory
    case symbolicLink
    case other
}

private struct DeviceBackupEnvelope: Codable {
    let metadata: DeviceBackupMetadata
    let payload: String
    let sha256: String
}

private enum DeviceBackupValidation {
    static func validate(_ metadata: DeviceBackupMetadata) throws {
        guard metadata.schemaVersion == DeviceBackupMetadata.schemaVersion else {
            throw DeviceBackupError.unsupportedBackupSchemaVersion(metadata.schemaVersion)
        }
        guard isDeviceAssociationID(metadata.deviceAssociationID) else {
            throw DeviceBackupError.invalidDeviceAssociationID
        }
        guard DeviceBackupMetadata.supportedProductIDs.contains(metadata.productID) else {
            throw DeviceBackupError.unsupportedProductID
        }
        guard
            !metadata.firmwareVersion.isEmpty,
            metadata.firmwareVersion.utf8.count <= DeviceBackupMetadata.maximumFirmwareBytes,
            metadata.firmwareVersion.unicodeScalars.allSatisfy({
                (0x20...0x7E).contains($0.value)
            })
        else {
            throw DeviceBackupError.invalidFirmwareVersion
        }
        guard
            (1...DeviceBackupMetadata.maximumKeymapSchemaVersion)
                .contains(metadata.keymapSchemaVersion)
        else {
            throw DeviceBackupError.invalidKeymapSchemaVersion
        }
        guard
            metadata.createdAtUnixMilliseconds >= 0,
            metadata.createdAtUnixMilliseconds <= 253_402_300_799_999
        else {
            throw DeviceBackupError.invalidTimestamp
        }
    }

    static func validate(_ match: DeviceBackupMatch) throws {
        guard isDeviceAssociationID(match.deviceAssociationID) else {
            throw DeviceBackupError.invalidDeviceAssociationID
        }
        guard DeviceBackupMetadata.supportedProductIDs.contains(match.productID) else {
            throw DeviceBackupError.unsupportedProductID
        }
        guard
            (1...DeviceBackupMetadata.maximumKeymapSchemaVersion)
                .contains(match.keymapSchemaVersion)
        else {
            throw DeviceBackupError.invalidKeymapSchemaVersion
        }
    }

    static func validatePayload(_ payload: Data, maximumBytes: Int) throws {
        guard !payload.isEmpty else {
            throw DeviceBackupError.invalidPayload
        }
        guard payload.count <= maximumBytes else {
            throw DeviceBackupError.payloadTooLarge
        }
    }

    static func isDeviceAssociationID(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39)
                    || ($0 >= 0x61 && $0 <= 0x66)
            }
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        isDeviceAssociationID(value)
    }
}
