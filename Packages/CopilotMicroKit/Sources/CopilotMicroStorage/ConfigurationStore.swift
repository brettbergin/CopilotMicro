import CopilotMicroCore
import Darwin
import Foundation

public actor LocalConfigurationStore {
    public static let configurationFilename = "config.json"
    public static let maximumRecoveryConfigurations = 5

    public let rootURL: URL
    public let configurationURL: URL
    public let backupDirectoryURL: URL

    private let fileManager: FileManager
    private let beforeAtomicReplace: @Sendable () throws -> Void
    private var latestSaveRevision: UInt64 = 0

    public init(rootURL: URL) {
        self.init(rootURL: rootURL, fileManager: .default, beforeAtomicReplace: {})
    }

    init(
        rootURL: URL,
        fileManager: FileManager,
        beforeAtomicReplace: @escaping @Sendable () throws -> Void
    ) {
        self.rootURL = rootURL.standardizedFileURL
        configurationURL = self.rootURL.appendingPathComponent(
            Self.configurationFilename,
            isDirectory: false
        )
        backupDirectoryURL = self.rootURL.appendingPathComponent(
            "backups/configuration",
            isDirectory: true
        )
        self.fileManager = fileManager
        self.beforeAtomicReplace = beforeAtomicReplace
    }

    public static func defaultRootURL(fileManager: FileManager = .default) throws -> URL {
        guard
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw ConfigurationError.fileSystem
        }
        return applicationSupport.appendingPathComponent("Copilot Micro", isDirectory: true)
    }

    public func load() throws -> StoredConfiguration {
        do {
            try prepareDirectories()
            guard fileManager.fileExists(atPath: configurationURL.path) else {
                let configuration = StoredConfiguration()
                try atomicWrite(
                    ConfigurationCodec.encodeStored(configuration),
                    to: configurationURL
                )
                return configuration
            }
            let data = try boundedData(from: configurationURL)
            let schemaVersion = try schemaVersion(in: data)
            if schemaVersion == StoredConfiguration.schemaVersion {
                return try ConfigurationCodec.decodeStored(data)
            }
            if schemaVersion == 0 {
                let migrated = try migrateLegacyV0(data)
                try preserve(data, reason: "pre-migration-v0")
                try atomicWrite(ConfigurationCodec.encodeStored(migrated), to: configurationURL)
                return migrated
            }
            throw ConfigurationError.unsupportedSchema(schemaVersion)
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.fileSystem
        }
    }

    func save(_ configuration: StoredConfiguration) throws {
        do {
            try prepareDirectories()
            try atomicWrite(ConfigurationCodec.encodeStored(configuration), to: configurationURL)
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.fileSystem
        }
    }

    @discardableResult
    public func save(
        _ configuration: StoredConfiguration,
        revision: UInt64
    ) throws -> Bool {
        guard revision > latestSaveRevision else {
            return false
        }
        try save(configuration)
        latestSaveRevision = revision
        return true
    }

    public func previewImport(
        _ data: Data,
        against current: StoredConfiguration
    ) throws -> ConfigurationImportPlan {
        try ConfigurationCodec.decodePortable(data, against: current)
    }

    public func previewImport(
        from sourceURL: URL,
        against current: StoredConfiguration
    ) throws -> ConfigurationImportPlan {
        do {
            let source = sourceURL.standardizedFileURL
            let values = try source.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ConfigurationError.fileSystem
            }
            guard
                let fileSize = values.fileSize,
                fileSize <= ConfigurationCodec.maximumEncodedBytes
            else {
                throw ConfigurationError.messageTooLarge
            }
            return try ConfigurationCodec.decodePortable(
                Data(contentsOf: source, options: [.mappedIfSafe]),
                against: current
            )
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.fileSystem
        }
    }

    func applyImport(_ plan: ConfigurationImportPlan) throws -> StoredConfiguration {
        do {
            let current = try load()
            let imported = try plan.applying(to: current)
            let previousData = try ConfigurationCodec.encodeStored(current)
            try preserve(previousData, reason: "pre-import")
            try atomicWrite(ConfigurationCodec.encodeStored(imported), to: configurationURL)
            return imported
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.fileSystem
        }
    }

    public func applyImport(
        _ plan: ConfigurationImportPlan,
        revision: UInt64
    ) throws -> StoredConfiguration {
        guard revision > latestSaveRevision else {
            throw ConfigurationError.staleImportPreview
        }
        let imported = try applyImport(plan)
        latestSaveRevision = revision
        return imported
    }

    public func portableData(for configuration: StoredConfiguration) throws -> Data {
        try ConfigurationCodec.encodePortable(configuration)
    }

    public func writePortable(
        _ configuration: StoredConfiguration,
        to destinationURL: URL
    ) throws {
        do {
            let destination = destinationURL.standardizedFileURL
            guard !StoragePathGuard.contains(destination, within: rootURL) else {
                throw ConfigurationError.fileSystem
            }
            if fileManager.fileExists(atPath: destination.path) {
                let existing = try destination.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard existing.isRegularFile == true, existing.isSymbolicLink != true else {
                    throw ConfigurationError.fileSystem
                }
            }
            try atomicExportWrite(
                ConfigurationCodec.encodePortable(configuration),
                to: destination
            )
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.fileSystem
        }
    }

    func replaceWithDefaultsPreservingOriginal() throws -> StoredConfiguration {
        do {
            try prepareDirectories()
            guard fileManager.fileExists(atPath: configurationURL.path) else {
                throw ConfigurationError.missingConfiguration
            }
            try preserveFile(configurationURL, reason: "malformed")
            let configuration = StoredConfiguration()
            try atomicWrite(ConfigurationCodec.encodeStored(configuration), to: configurationURL)
            return configuration
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.fileSystem
        }
    }

    public func replaceWithDefaultsPreservingOriginal(
        revision: UInt64
    ) throws -> StoredConfiguration {
        guard revision > latestSaveRevision else {
            throw ConfigurationError.staleImportPreview
        }
        let configuration = try replaceWithDefaultsPreservingOriginal()
        latestSaveRevision = revision
        return configuration
    }

    private func migrateLegacyV0(_ data: Data) throws -> StoredConfiguration {
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard
                let root = object as? [String: Any],
                Set(root.keys)
                    == Set([
                        "schemaVersion",
                        "bindings",
                        "brightness",
                        "reducedMotion",
                        "notificationsEnabled",
                    ])
            else {
                throw ConfigurationError.unexpectedField
            }
            let legacy = try JSONDecoder().decode(LegacyConfigurationV0.self, from: data)
            let migrated = StoredConfiguration(
                bindings: try legacy.decodedBindings(),
                lighting: StoredLightingPreferences(
                    brightness: legacy.brightness,
                    reducedMotion: legacy.reducedMotion
                ),
                preferences: StoredUserPreferences(
                    notificationsEnabled: legacy.notificationsEnabled
                )
            )
            try ConfigurationCodec.validate(migrated)
            return migrated
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.malformed
        }
    }

    private func schemaVersion(in data: Data) throws -> Int {
        do {
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let version = object["schemaVersion"] as? Int
            else {
                throw ConfigurationError.malformed
            }
            return version
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.malformed
        }
    }

    private func boundedData(from url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ConfigurationError.fileSystem
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard
            let size = attributes[.size] as? NSNumber,
            size.intValue <= ConfigurationCodec.maximumEncodedBytes
        else {
            throw ConfigurationError.messageTooLarge
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func prepareDirectories() throws {
        try createProtectedDirectory(rootURL)
        try createProtectedDirectory(
            rootURL.appendingPathComponent("backups", isDirectory: true)
        )
        try createProtectedDirectory(backupDirectoryURL)
    }

    private func createProtectedDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isSymbolicLink != true else {
                throw ConfigurationError.fileSystem
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func preserve(_ data: Data, reason: String) throws {
        try prepareDirectories()
        let filename = "config-\(reason)-\(UUID().uuidString.lowercased()).json"
        try atomicWrite(data, to: backupDirectoryURL.appendingPathComponent(filename))
        try trimRecoveryConfigurations()
    }

    private func preserveFile(_ source: URL, reason: String) throws {
        try prepareDirectories()
        let destination = backupDirectoryURL.appendingPathComponent(
            "config-\(reason)-\(UUID().uuidString.lowercased()).json"
        )
        try fileManager.copyItem(at: source, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try trimRecoveryConfigurations()
    }

    private func trimRecoveryConfigurations() throws {
        let backupURLs = try fileManager.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        var backups: [(url: URL, date: Date)] = []
        for url in backupURLs {
            let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let date = values.contentModificationDate
            else {
                throw ConfigurationError.fileSystem
            }
            backups.append((url, date))
        }
        backups.sort { $0.date > $1.date }
        for expired in backups.dropFirst(Self.maximumRecoveryConfigurations) {
            try fileManager.removeItem(at: expired.url)
        }
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try createProtectedDirectory(directory)
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        guard
            fileManager.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw ConfigurationError.fileSystem
        }
        defer {
            try? fileManager.removeItem(at: temporary)
        }
        try beforeAtomicReplace()
        guard rename(temporary.path, destination.path) == 0 else {
            throw ConfigurationError.fileSystem
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func atomicExportWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ConfigurationError.fileSystem
        }
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        guard
            fileManager.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw ConfigurationError.fileSystem
        }
        defer {
            try? fileManager.removeItem(at: temporary)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw ConfigurationError.fileSystem
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

enum StoragePathGuard {
    static func contains(_ candidateURL: URL, within rootURL: URL) -> Bool {
        let candidate = candidateURL.standardizedFileURL
        let root = rootURL.standardizedFileURL
        if hasPathPrefix(candidate, root: root) {
            return true
        }
        return hasPathPrefix(
            candidate.resolvingSymlinksInPath(),
            root: root.resolvingSymlinksInPath()
        )
    }

    private static func hasPathPrefix(_ candidate: URL, root: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        return zip(candidateComponents, rootComponents).allSatisfy(==)
    }
}

private struct LegacyConfigurationV0: Decodable {
    let schemaVersion: Int
    let bindings: [String: ActionID]
    let brightness: Double
    let reducedMotion: Bool
    let notificationsEnabled: Bool

    func decodedBindings() throws -> [PhysicalControlID: ActionID] {
        var decoded: [PhysicalControlID: ActionID] = [:]
        for (key, action) in bindings {
            guard let control = PhysicalControlID(rawValue: key) else {
                throw ConfigurationError.incompleteBindings
            }
            decoded[control] = action
        }
        return decoded
    }
}
