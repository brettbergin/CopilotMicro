import Darwin
import Foundation

public enum IPCBootstrapStoreError: Error, Equatable, Sendable {
    case malformed
    case fileSystem
}

public enum IPCBridgeRuntime {
    public static let directoryName = "bridge"
    public static let socketFilename = "bridge.sock"
    public static let bootstrapTokenFilename = "bootstrap-token"
    public static let listenerLockFilename = "listener.lock"

    public static func defaultRootURL(fileManager: FileManager = .default) throws -> URL {
        guard
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw IPCBootstrapStoreError.fileSystem
        }
        return applicationSupport.appendingPathComponent("Copilot Micro", isDirectory: true)
    }
}

public actor IPCBootstrapStore {
    public static let filename = IPCBridgeRuntime.bootstrapTokenFilename

    public let rootURL: URL
    public let directoryURL: URL
    public let tokenURL: URL

    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL
        directoryURL = self.rootURL.appendingPathComponent(
            IPCBridgeRuntime.directoryName,
            isDirectory: true
        )
        tokenURL = directoryURL.appendingPathComponent(IPCBridgeRuntime.bootstrapTokenFilename)
        self.fileManager = fileManager
    }

    public func loadOrCreate() throws -> IPCBootstrapToken {
        do {
            try prepareDirectories()
            if fileManager.fileExists(atPath: tokenURL.path) {
                let values = try tokenURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                    let size = values.fileSize, size == 64
                else {
                    throw IPCBootstrapStoreError.malformed
                }
                let data = try Data(contentsOf: tokenURL)
                guard let rawValue = String(data: data, encoding: .utf8) else {
                    throw IPCBootstrapStoreError.malformed
                }
                let token: IPCBootstrapToken
                do {
                    token = try IPCBootstrapToken(rawValue: rawValue)
                } catch {
                    throw IPCBootstrapStoreError.malformed
                }
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: tokenURL.path
                )
                return token
            }

            let token = try IPCBootstrapToken.generate()
            if try installIfAbsent(Data(token.rawValue.utf8)) {
                return token
            }
            return try readExistingToken()
        } catch let error as IPCBootstrapStoreError {
            throw error
        } catch {
            throw IPCBootstrapStoreError.fileSystem
        }
    }

    private func prepareDirectories() throws {
        try prepareProtectedDirectory(rootURL)
        try prepareProtectedDirectory(directoryURL)
    }

    private func prepareProtectedDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isSymbolicLink != true else {
                throw IPCBootstrapStoreError.fileSystem
            }
        } else {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else {
                    throw error
                }
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw IPCBootstrapStoreError.fileSystem
                }
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func readExistingToken() throws -> IPCBootstrapToken {
        let values = try tokenURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            values.fileSize == 64
        else {
            throw IPCBootstrapStoreError.malformed
        }
        guard let rawValue = String(data: try Data(contentsOf: tokenURL), encoding: .utf8) else {
            throw IPCBootstrapStoreError.malformed
        }
        do {
            return try IPCBootstrapToken(rawValue: rawValue)
        } catch {
            throw IPCBootstrapStoreError.malformed
        }
    }

    private func installIfAbsent(_ data: Data) throws -> Bool {
        let temporary = directoryURL.appendingPathComponent(
            ".\(Self.filename).\(UUID().uuidString.lowercased()).tmp"
        )
        guard
            fileManager.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw IPCBootstrapStoreError.fileSystem
        }
        defer {
            try? fileManager.removeItem(at: temporary)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        guard link(temporary.path, tokenURL.path) == 0 else {
            if errno == EEXIST {
                return false
            }
            throw IPCBootstrapStoreError.fileSystem
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return true
    }
}
