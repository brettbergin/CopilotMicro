import CryptoKit
import Darwin
import Foundation

public enum BridgeExtensionPackage {
    public static let name = "copilot-micro-session-bridge"
    public static let version = "0.1.0"
    public static let resourceDirectoryName = name
    public static let filenames = [
        "client.mjs",
        "extension-runtime.mjs",
        "extension.mjs",
        "protocol.mjs",
        "session-observer.mjs",
    ]
}

public struct BridgeExtensionFileDigest: Codable, Equatable, Sendable {
    public let filename: String
    public let sha256: String

    public init(filename: String, sha256: String) {
        self.filename = filename
        self.sha256 = sha256
    }
}

public struct BridgeExtensionReceipt: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let extensionName: String
    public let version: String
    public let destinationPath: String
    public let installedAtUnixSeconds: UInt64
    public let files: [BridgeExtensionFileDigest]

    public init(
        version: String,
        destinationPath: String,
        installedAtUnixSeconds: UInt64,
        files: [BridgeExtensionFileDigest]
    ) {
        schemaVersion = Self.schemaVersion
        extensionName = BridgeExtensionPackage.name
        self.version = version
        self.destinationPath = destinationPath
        self.installedAtUnixSeconds = installedAtUnixSeconds
        self.files = files
    }
}

public enum BridgeExtensionInstallationStatus: Equatable, Sendable {
    case notInstalled(destinationURL: URL)
    case installed(version: String, destinationURL: URL)
    case updateAvailable(installedVersion: String, packagedVersion: String, destinationURL: URL)
    case collision(destinationURL: URL)
    case modified(destinationURL: URL)

    public var destinationURL: URL {
        switch self {
        case .notInstalled(let destinationURL), .installed(_, let destinationURL),
            .updateAvailable(_, _, let destinationURL), .collision(let destinationURL),
            .modified(let destinationURL):
            destinationURL
        }
    }

    public var canInstall: Bool {
        switch self {
        case .notInstalled, .updateAvailable:
            true
        case .installed, .collision, .modified:
            false
        }
    }

    public var isInstalled: Bool {
        if case .installed = self {
            return true
        }
        return false
    }
}

public enum BridgeExtensionInstallationAuthorization: Equatable, Sendable {
    case notConfirmed
    case userConfirmed
}

public enum BridgeExtensionInstallerError: Error, Equatable, LocalizedError, Sendable {
    case authorizationRequired
    case collision
    case fileSystem
    case modifiedInstallation
    case packageUnavailable
    case projectExtensionCollision
    case unsafePath

    public var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            "Installing the Copilot CLI bridge requires explicit confirmation."
        case .collision:
            "Another extension already uses the Copilot Micro extension path."
        case .fileSystem:
            "The Copilot CLI bridge files could not be installed safely."
        case .modifiedInstallation:
            "The installed Copilot Micro extension was modified outside this app."
        case .packageUnavailable:
            "The packaged Copilot Micro extension is missing or invalid."
        case .projectExtensionCollision:
            "This project contains an extension that shadows the installed Copilot Micro bridge."
        case .unsafePath:
            "The Copilot CLI extension path is not an owned, safe filesystem location."
        }
    }
}

public actor BridgeExtensionInstaller {
    public static let receiptFilename = "bridge-extension-receipt.json"
    public static let stagingDirectoryName = ".copilot-micro-staging"
    public static let backupDirectoryName = ".copilot-micro-backups"
    public static let maximumFileBytes = 1_048_576
    public static let maximumReceiptBytes = 65_536

    public let packageDirectoryURL: URL
    public let copilotHomeURL: URL
    public let extensionsDirectoryURL: URL
    public let destinationURL: URL
    public let receiptURL: URL
    public let backupDirectoryURL: URL

    private let applicationSupportRootURL: URL
    private let fileManager: FileManager
    private let nowUnixSeconds: @Sendable () -> UInt64

    public init(
        packageDirectoryURL: URL,
        copilotHomeURL: URL,
        applicationSupportRootURL: URL,
        fileManager: FileManager = .default,
        nowUnixSeconds: @escaping @Sendable () -> UInt64 = {
            UInt64(Date().timeIntervalSince1970)
        }
    ) {
        self.packageDirectoryURL = packageDirectoryURL.standardizedFileURL
        self.copilotHomeURL = copilotHomeURL.standardizedFileURL
        extensionsDirectoryURL = self.copilotHomeURL.appendingPathComponent(
            "extensions",
            isDirectory: true
        )
        destinationURL = extensionsDirectoryURL.appendingPathComponent(
            BridgeExtensionPackage.name,
            isDirectory: true
        )
        self.applicationSupportRootURL = applicationSupportRootURL.standardizedFileURL
        receiptURL = self.applicationSupportRootURL.appendingPathComponent(
            Self.receiptFilename,
            isDirectory: false
        )
        backupDirectoryURL = self.copilotHomeURL.appendingPathComponent(
            Self.backupDirectoryName,
            isDirectory: true
        )
        self.fileManager = fileManager
        self.nowUnixSeconds = nowUnixSeconds
    }

    public static func defaultCopilotHomeURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
            ".copilot",
            isDirectory: true
        )
    }

    public static func packagedDirectoryURL(bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent(
            BridgeExtensionPackage.resourceDirectoryName,
            isDirectory: true
        )
    }

    public func inspect() throws -> BridgeExtensionInstallationStatus {
        let packagedFiles = try manifest(
            at: packageDirectoryURL,
            requirePrivateOwnership: false
        )
        guard try nodeMetadata(at: destinationURL) != nil else {
            return .notInstalled(destinationURL: destinationURL)
        }
        guard
            let destinationMetadata = try nodeMetadata(at: destinationURL),
            destinationMetadata.isDirectory,
            destinationMetadata.userID == geteuid(),
            destinationMetadata.permissions == 0o700
        else {
            return .collision(destinationURL: destinationURL)
        }
        guard let receipt = try? readReceipt(), receiptMatchesIdentity(receipt) else {
            return .collision(destinationURL: destinationURL)
        }
        guard
            let installedFiles = try? manifest(
                at: destinationURL,
                requirePrivateOwnership: true
            ),
            installedFiles == receipt.files
        else {
            return .modified(destinationURL: destinationURL)
        }
        guard
            receipt.version == BridgeExtensionPackage.version,
            installedFiles == packagedFiles
        else {
            return .updateAvailable(
                installedVersion: receipt.version,
                packagedVersion: BridgeExtensionPackage.version,
                destinationURL: destinationURL
            )
        }
        return .installed(
            version: receipt.version,
            destinationURL: destinationURL
        )
    }

    public func install(
        authorization: BridgeExtensionInstallationAuthorization
    ) throws -> BridgeExtensionInstallationStatus {
        guard authorization == .userConfirmed else {
            throw BridgeExtensionInstallerError.authorizationRequired
        }
        let status = try inspect()
        switch status {
        case .installed:
            return status
        case .collision:
            throw BridgeExtensionInstallerError.collision
        case .modified:
            throw BridgeExtensionInstallerError.modifiedInstallation
        case .notInstalled, .updateAvailable:
            break
        }

        try prepareOwnedParentDirectory(copilotHomeURL)
        try prepareExtensionsDirectory()
        let stagingRoot = copilotHomeURL.appendingPathComponent(
            Self.stagingDirectoryName,
            isDirectory: true
        )
        try preparePrivateDirectory(stagingRoot)
        try preparePrivateDirectory(backupDirectoryURL)
        try preparePrivateDirectory(applicationSupportRootURL)

        let stagedURL = stagingRoot.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        try copyPackage(to: stagedURL)
        guard try inspect() == status else {
            try? fileManager.removeItem(at: stagedURL)
            throw BridgeExtensionInstallerError.modifiedInstallation
        }
        var installedNewDirectory = false
        var swappedExistingDirectory = false
        do {
            switch status {
            case .notInstalled:
                try installExclusively(stagedURL, destinationURL)
                installedNewDirectory = true
            case .updateAvailable:
                try preserveCurrentInstallation()
                guard try inspect() == status else {
                    throw BridgeExtensionInstallerError.modifiedInstallation
                }
                try swapDirectories(stagedURL, destinationURL)
                swappedExistingDirectory = true
            case .installed, .collision, .modified:
                throw BridgeExtensionInstallerError.fileSystem
            }

            let installedFiles = try manifest(
                at: destinationURL,
                requirePrivateOwnership: true
            )
            let receipt = BridgeExtensionReceipt(
                version: BridgeExtensionPackage.version,
                destinationPath: destinationURL.path,
                installedAtUnixSeconds: nowUnixSeconds(),
                files: installedFiles
            )
            try writeReceipt(receipt)

            if swappedExistingDirectory {
                try? fileManager.removeItem(at: stagedURL)
            }
            return .installed(
                version: receipt.version,
                destinationURL: destinationURL
            )
        } catch {
            if swappedExistingDirectory {
                try? swapDirectories(stagedURL, destinationURL)
            } else if installedNewDirectory {
                try? fileManager.removeItem(at: destinationURL)
            }
            try? fileManager.removeItem(at: stagedURL)
            if let error = error as? BridgeExtensionInstallerError {
                throw error
            }
            throw BridgeExtensionInstallerError.fileSystem
        }
    }

    public func requireNoProjectShadow(in projectDirectoryURL: URL) throws {
        guard
            projectDirectoryURL.isFileURL,
            projectDirectoryURL.path.hasPrefix("/"),
            let metadata = try nodeMetadata(at: projectDirectoryURL),
            metadata.isDirectory
        else {
            throw BridgeExtensionInstallerError.unsafePath
        }
        let projectExtensionURL =
            projectDirectoryURL
            .appendingPathComponent(".github/extensions", isDirectory: true)
            .appendingPathComponent(BridgeExtensionPackage.name, isDirectory: true)
        if try nodeMetadata(at: projectExtensionURL) != nil {
            throw BridgeExtensionInstallerError.projectExtensionCollision
        }
    }

    private func receiptMatchesIdentity(_ receipt: BridgeExtensionReceipt) -> Bool {
        receipt.schemaVersion == BridgeExtensionReceipt.schemaVersion
            && receipt.extensionName == BridgeExtensionPackage.name
            && receipt.destinationPath == destinationURL.path
            && Set(receipt.files.map(\.filename)) == Set(BridgeExtensionPackage.filenames)
            && receipt.files.allSatisfy {
                $0.sha256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
            }
    }

    private func readReceipt() throws -> BridgeExtensionReceipt {
        guard
            let metadata = try nodeMetadata(at: receiptURL),
            metadata.isRegularFile,
            metadata.userID == geteuid(),
            metadata.permissions == 0o600,
            metadata.size <= Self.maximumReceiptBytes
        else {
            throw BridgeExtensionInstallerError.unsafePath
        }
        do {
            return try JSONDecoder().decode(
                BridgeExtensionReceipt.self,
                from: Data(contentsOf: receiptURL)
            )
        } catch {
            throw BridgeExtensionInstallerError.fileSystem
        }
    }

    private func manifest(
        at directoryURL: URL,
        requirePrivateOwnership: Bool
    ) throws -> [BridgeExtensionFileDigest] {
        guard
            let directoryMetadata = try nodeMetadata(at: directoryURL),
            directoryMetadata.isDirectory
        else {
            throw BridgeExtensionInstallerError.packageUnavailable
        }
        if requirePrivateOwnership {
            guard
                directoryMetadata.userID == geteuid(),
                directoryMetadata.permissions == 0o700
            else {
                throw BridgeExtensionInstallerError.unsafePath
            }
        }
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw BridgeExtensionInstallerError.fileSystem
        }
        guard Set(contents.map(\.lastPathComponent)) == Set(BridgeExtensionPackage.filenames) else {
            throw BridgeExtensionInstallerError.packageUnavailable
        }
        return try BridgeExtensionPackage.filenames.map { filename in
            let fileURL = directoryURL.appendingPathComponent(filename)
            guard
                let metadata = try nodeMetadata(at: fileURL),
                metadata.isRegularFile,
                metadata.size <= Self.maximumFileBytes
            else {
                throw BridgeExtensionInstallerError.packageUnavailable
            }
            if requirePrivateOwnership {
                guard
                    metadata.userID == geteuid(),
                    metadata.permissions == 0o600
                else {
                    throw BridgeExtensionInstallerError.unsafePath
                }
            }
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw BridgeExtensionInstallerError.fileSystem
            }
            return BridgeExtensionFileDigest(
                filename: filename,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            )
        }
    }

    private func prepareOwnedParentDirectory(_ url: URL) throws {
        if let metadata = try nodeMetadata(at: url) {
            guard
                metadata.isDirectory,
                metadata.userID == geteuid(),
                metadata.permissions & 0o022 == 0
            else {
                throw BridgeExtensionInstallerError.unsafePath
            }
            return
        }
        guard mkdir(url.path, 0o700) == 0 else {
            throw BridgeExtensionInstallerError.fileSystem
        }
    }

    private func prepareExtensionsDirectory() throws {
        if let metadata = try nodeMetadata(at: extensionsDirectoryURL) {
            guard
                metadata.isDirectory,
                metadata.userID == geteuid(),
                metadata.permissions & 0o022 == 0
            else {
                throw BridgeExtensionInstallerError.unsafePath
            }
            return
        }
        guard mkdir(extensionsDirectoryURL.path, 0o700) == 0 else {
            throw BridgeExtensionInstallerError.fileSystem
        }
    }

    private func preparePrivateDirectory(_ url: URL) throws {
        if let metadata = try nodeMetadata(at: url) {
            guard metadata.isDirectory, metadata.userID == geteuid() else {
                throw BridgeExtensionInstallerError.unsafePath
            }
            guard chmod(url.path, 0o700) == 0 else {
                throw BridgeExtensionInstallerError.fileSystem
            }
            return
        }
        guard mkdir(url.path, 0o700) == 0 else {
            throw BridgeExtensionInstallerError.fileSystem
        }
    }

    private func copyPackage(to stagedURL: URL) throws {
        guard mkdir(stagedURL.path, 0o700) == 0 else {
            throw BridgeExtensionInstallerError.fileSystem
        }
        do {
            for filename in BridgeExtensionPackage.filenames {
                let sourceURL = packageDirectoryURL.appendingPathComponent(filename)
                guard
                    let metadata = try nodeMetadata(at: sourceURL),
                    metadata.isRegularFile,
                    metadata.size <= Self.maximumFileBytes
                else {
                    throw BridgeExtensionInstallerError.packageUnavailable
                }
                let destination = stagedURL.appendingPathComponent(filename)
                guard
                    fileManager.createFile(
                        atPath: destination.path,
                        contents: try Data(contentsOf: sourceURL),
                        attributes: [.posixPermissions: 0o600]
                    )
                else {
                    throw BridgeExtensionInstallerError.fileSystem
                }
                let handle = try FileHandle(forWritingTo: destination)
                try handle.synchronize()
                try handle.close()
            }
            _ = try manifest(at: stagedURL, requirePrivateOwnership: true)
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
    }

    private func preserveCurrentInstallation() throws {
        let backupURL = backupDirectoryURL.appendingPathComponent(
            "\(BridgeExtensionPackage.version)-\(nowUnixSeconds())-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        do {
            try fileManager.copyItem(at: destinationURL, to: backupURL)
            guard chmod(backupURL.path, 0o700) == 0 else {
                throw BridgeExtensionInstallerError.fileSystem
            }
            for filename in BridgeExtensionPackage.filenames {
                guard
                    chmod(backupURL.appendingPathComponent(filename).path, 0o600) == 0
                else {
                    throw BridgeExtensionInstallerError.fileSystem
                }
            }
            _ = try manifest(at: backupURL, requirePrivateOwnership: true)
        } catch {
            try? fileManager.removeItem(at: backupURL)
            if let error = error as? BridgeExtensionInstallerError {
                throw error
            }
            throw BridgeExtensionInstallerError.fileSystem
        }
    }

    private func swapDirectories(_ first: URL, _ second: URL) throws {
        let result = renameatx_np(
            AT_FDCWD,
            first.path,
            AT_FDCWD,
            second.path,
            UInt32(RENAME_SWAP)
        )
        guard result == 0 else {
            throw BridgeExtensionInstallerError.fileSystem
        }
    }

    private func installExclusively(_ source: URL, _ destination: URL) throws {
        let result = renameatx_np(
            AT_FDCWD,
            source.path,
            AT_FDCWD,
            destination.path,
            UInt32(RENAME_EXCL)
        )
        guard result == 0 else {
            throw errno == EEXIST || errno == ENOTEMPTY
                ? BridgeExtensionInstallerError.collision
                : BridgeExtensionInstallerError.fileSystem
        }
    }

    private func writeReceipt(_ receipt: BridgeExtensionReceipt) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(receipt)
        } catch {
            throw BridgeExtensionInstallerError.fileSystem
        }
        guard data.count <= Self.maximumReceiptBytes else {
            throw BridgeExtensionInstallerError.fileSystem
        }
        if let metadata = try nodeMetadata(at: receiptURL) {
            guard metadata.isRegularFile, metadata.userID == geteuid() else {
                throw BridgeExtensionInstallerError.unsafePath
            }
        }
        let temporaryURL = applicationSupportRootURL.appendingPathComponent(
            ".\(Self.receiptFilename).\(UUID().uuidString.lowercased()).tmp"
        )
        guard
            fileManager.createFile(
                atPath: temporaryURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw BridgeExtensionInstallerError.fileSystem
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.synchronize()
            try handle.close()
        } catch {
            throw BridgeExtensionInstallerError.fileSystem
        }
        guard rename(temporaryURL.path, receiptURL.path) == 0 else {
            throw BridgeExtensionInstallerError.fileSystem
        }
    }

    private func nodeMetadata(at url: URL) throws -> NodeMetadata? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw BridgeExtensionInstallerError.fileSystem
        }
        return NodeMetadata(value)
    }
}

private struct NodeMetadata {
    let mode: mode_t
    let userID: uid_t
    let size: Int

    init(_ value: stat) {
        mode = value.st_mode
        userID = value.st_uid
        size = Int(value.st_size)
    }

    var permissions: mode_t {
        mode & 0o777
    }

    var isDirectory: Bool {
        mode & S_IFMT == S_IFDIR
    }

    var isRegularFile: Bool {
        mode & S_IFMT == S_IFREG
    }
}
