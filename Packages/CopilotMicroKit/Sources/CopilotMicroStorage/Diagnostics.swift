import Foundation

public enum DiagnosticComponent: String, Codable, CaseIterable, Sendable {
    case application
    case configuration
    case bridge
    case terminal
    case device
    case updater
}

public enum DiagnosticOutcome: String, Codable, CaseIterable, Sendable {
    case started
    case succeeded
    case rejected
    case failed
}

public enum DiagnosticErrorCategory: String, Codable, CaseIterable, Sendable {
    case invalidInput
    case unsupported
    case unavailable
    case permissionDenied
    case timedOut
    case disconnected
    case conflict
    case corruptedData
    case fileSystem
    case internalFailure
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let timestamp: Date
    public let component: DiagnosticComponent
    public let operation: String
    public let capabilityVersion: String?
    public let correlationAlias: String?
    public let outcome: DiagnosticOutcome
    public let errorCategory: DiagnosticErrorCategory?
    public let message: String?

    public init(
        timestamp: Date,
        component: DiagnosticComponent,
        operation: String,
        capabilityVersion: String? = nil,
        correlationAlias: String? = nil,
        outcome: DiagnosticOutcome,
        errorCategory: DiagnosticErrorCategory? = nil,
        message: String? = nil,
        sensitiveValues: [String] = []
    ) throws {
        guard Self.validIdentifier(operation, maximumBytes: 64),
            Self.validOptionalIdentifier(capabilityVersion, maximumBytes: 64),
            Self.validOptionalIdentifier(correlationAlias, maximumBytes: 64),
            (outcome == .failed) == (errorCategory != nil)
        else {
            throw DiagnosticError.invalidEvent
        }
        schemaVersion = Self.schemaVersion
        self.timestamp = timestamp
        self.component = component
        self.operation = operation
        self.capabilityVersion = capabilityVersion
        self.correlationAlias = correlationAlias
        self.outcome = outcome
        self.errorCategory = errorCategory
        self.message = message.map {
            DiagnosticRedactor.redact($0, sensitiveValues: sensitiveValues)
        }
    }

    private static func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x21 && scalar.value <= 0x7E
            }
    }

    private static func validOptionalIdentifier(_ value: String?, maximumBytes: Int) -> Bool {
        value.map { validIdentifier($0, maximumBytes: maximumBytes) } ?? true
    }
}

public enum DiagnosticError: Error, Equatable, Sendable {
    case invalidEvent
    case eventTooLarge
    case fileSystem

    public var userMessage: String {
        switch self {
        case .invalidEvent:
            "The diagnostic event did not use the bounded structured format."
        case .eventTooLarge:
            "The diagnostic event exceeded the local size limit."
        case .fileSystem:
            "Local diagnostics could not be read or written."
        }
    }
}

public enum DiagnosticRedactor {
    public static let maximumMessageCharacters = 512

    public static func redact(_ input: String, sensitiveValues: [String] = []) -> String {
        var redacted = input
        for value
            in sensitiveValues
            .filter({ !$0.isEmpty })
            .sorted(by: { $0.count > $1.count })
        {
            redacted = redacted.replacingOccurrences(of: value, with: "[redacted]")
        }
        for pattern in patterns {
            redacted = replace(pattern, in: redacted)
        }
        redacted = redacted.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        return String(redacted.prefix(maximumMessageCharacters))
    }

    private static let patterns = [
        #"(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,})\b"#,
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/\-=]+"#,
        #"https?://[^\s,;]+"#,
        #"(?i)\bfile://[^\s,;]+"#,
        #"(?<![A-Za-z0-9:/])/(?:[^,\s;\n][^,;\n]*)"#,
        #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
        #"(?i)\b(?:serial|account|login)\s*[:=]\s*[^,;\n]+"#,
        #"(?i)\b(?:prompt|draft|command|toolArguments?)\s*[:=]\s*[^,;\n]+"#,
    ]

    private static func replace(_ pattern: String, in value: String) -> String {
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: pattern)
        } catch {
            return "[redacted]"
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: "[redacted]"
        )
    }
}

public struct DiagnosticUsage: Equatable, Sendable {
    public let segmentCount: Int
    public let bytes: Int
    public let maximumSegmentCount: Int
    public let maximumSegmentBytes: Int

    public init(
        segmentCount: Int,
        bytes: Int,
        maximumSegmentCount: Int,
        maximumSegmentBytes: Int
    ) {
        self.segmentCount = segmentCount
        self.bytes = bytes
        self.maximumSegmentCount = maximumSegmentCount
        self.maximumSegmentBytes = maximumSegmentBytes
    }
}

public actor DiagnosticStore {
    public static let defaultMaximumSegmentBytes = 5 * 1_024 * 1_024
    public static let defaultMaximumSegments = 3

    public let directoryURL: URL
    private let maximumSegmentBytes: Int
    private let maximumSegments: Int
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    public init(
        directoryURL: URL,
        maximumSegmentBytes: Int = defaultMaximumSegmentBytes,
        maximumSegments: Int = defaultMaximumSegments,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.maximumSegmentBytes = maximumSegmentBytes
        self.maximumSegments = maximumSegments
        self.now = now
        fileManager = .default
    }

    public func append(_ event: DiagnosticEvent) throws {
        guard maximumSegmentBytes > 0, maximumSegments > 0 else {
            throw DiagnosticError.fileSystem
        }
        do {
            try prepareDirectory()
            var data = try encoder().encode(event.redactedForExport())
            data.append(0x0A)
            guard data.count <= maximumSegmentBytes else {
                throw DiagnosticError.eventTooLarge
            }
            let current = segmentURL(index: 0)
            let currentSize = try segmentSize(at: current)
            if currentSize + data.count > maximumSegmentBytes {
                try rotate()
            }
            if !fileManager.fileExists(atPath: current.path) {
                guard
                    fileManager.createFile(
                        atPath: current.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                else {
                    throw DiagnosticError.fileSystem
                }
            }
            let handle = try FileHandle(forWritingTo: current)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
        } catch let error as DiagnosticError {
            throw error
        } catch {
            throw DiagnosticError.fileSystem
        }
    }

    public func clear() throws {
        do {
            try prepareDirectory()
            for index in 0..<maximumSegments {
                let url = segmentURL(index: index)
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
        } catch {
            throw DiagnosticError.fileSystem
        }
    }

    public func usage() throws -> DiagnosticUsage {
        do {
            try prepareDirectory()
            var bytes = 0
            var segments = 0
            for index in 0..<maximumSegments {
                let url = segmentURL(index: index)
                guard fileManager.fileExists(atPath: url.path) else {
                    continue
                }
                try validateSegment(url)
                segments += 1
                bytes +=
                    ((try fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
                    .intValue ?? 0
            }
            return DiagnosticUsage(
                segmentCount: segments,
                bytes: bytes,
                maximumSegmentCount: maximumSegments,
                maximumSegmentBytes: maximumSegmentBytes
            )
        } catch {
            throw DiagnosticError.fileSystem
        }
    }

    public func exportData() throws -> Data {
        do {
            try prepareDirectory()
            var events: [DiagnosticEvent] = []
            for index in (0..<maximumSegments).reversed() {
                let url = segmentURL(index: index)
                guard fileManager.fileExists(atPath: url.path) else {
                    continue
                }
                try validateSegment(url)
                let contents = try String(contentsOf: url, encoding: .utf8)
                for line in contents.split(separator: "\n") {
                    let event = try decoder().decode(DiagnosticEvent.self, from: Data(line.utf8))
                    events.append(try event.redactedForExport())
                }
            }
            return try encoder().encode(
                DiagnosticExport(generatedAt: now(), events: events)
            )
        } catch let error as DiagnosticError {
            throw error
        } catch {
            throw DiagnosticError.fileSystem
        }
    }

    public func writeExport(to destinationURL: URL) throws {
        do {
            let destination = destinationURL.standardizedFileURL
            guard
                !StoragePathGuard.contains(
                    destination,
                    within: directoryURL.deletingLastPathComponent()
                )
            else {
                throw DiagnosticError.fileSystem
            }
            if fileManager.fileExists(atPath: destination.path) {
                let existing = try destination.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard existing.isRegularFile == true, existing.isSymbolicLink != true else {
                    throw DiagnosticError.fileSystem
                }
            }
            let data = try exportData()
            try data.write(to: destination, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch let error as DiagnosticError {
            throw error
        } catch {
            throw DiagnosticError.fileSystem
        }
    }

    private func prepareDirectory() throws {
        try prepareProtectedDirectory(directoryURL.deletingLastPathComponent())
        try prepareProtectedDirectory(directoryURL)
    }

    private func prepareProtectedDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isSymbolicLink != true else {
                throw DiagnosticError.fileSystem
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func rotate() throws {
        let oldest = segmentURL(index: maximumSegments - 1)
        if fileManager.fileExists(atPath: oldest.path) {
            try fileManager.removeItem(at: oldest)
        }
        guard maximumSegments > 1 else {
            return
        }
        for index in stride(from: maximumSegments - 2, through: 0, by: -1) {
            let source = segmentURL(index: index)
            guard fileManager.fileExists(atPath: source.path) else {
                continue
            }
            try validateSegment(source)
            try fileManager.moveItem(at: source, to: segmentURL(index: index + 1))
        }
    }

    private func segmentSize(at url: URL) throws -> Int {
        guard fileManager.fileExists(atPath: url.path) else {
            return 0
        }
        try validateSegment(url)
        return
            ((try fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
            .intValue ?? 0
    }

    private func validateSegment(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize <= maximumSegmentBytes
        else {
            throw DiagnosticError.fileSystem
        }
    }

    private func segmentURL(index: Int) -> URL {
        directoryURL.appendingPathComponent("segment-\(index).jsonl", isDirectory: false)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct DiagnosticExport: Encodable {
    let schemaVersion = 1
    let product = "Copilot Micro"
    let generatedAt: Date
    let events: [DiagnosticEvent]
}

extension DiagnosticEvent {
    fileprivate func redactedForExport() throws -> DiagnosticEvent {
        try DiagnosticEvent(
            timestamp: timestamp,
            component: component,
            operation: operation,
            capabilityVersion: capabilityVersion,
            correlationAlias: correlationAlias,
            outcome: outcome,
            errorCategory: errorCategory,
            message: message.map { DiagnosticRedactor.redact($0) }
        )
    }
}
