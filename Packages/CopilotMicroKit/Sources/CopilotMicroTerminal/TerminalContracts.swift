import CopilotMicroCore
import Foundation

public enum TerminalContractError: Error, Equatable, LocalizedError, Sendable {
    case invalidArguments
    case invalidIdentifier
    case invalidProcessIdentifier
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "The terminal launch argument vector is invalid."
        case .invalidIdentifier:
            "The terminal target identifier is invalid."
        case .invalidProcessIdentifier:
            "The terminal process identifier is invalid."
        case .invalidURL:
            "The terminal contract requires an absolute file URL."
        }
    }
}

public enum TerminalUIContext: String, Codable, CaseIterable, Sendable {
    case unknown
    case composer
    case sessionList
    case modelPicker
    case effortPicker
    case toolPermission
    case question
    case planReview
    case other
}

public struct TerminalSurfaceTarget: Codable, Equatable, Hashable, Sendable {
    public let terminal: TerminalPreference
    public let instanceID: CLIInstanceID
    public let processIdentifier: Int32
    public let windowIdentifier: String
    public let tabIdentifier: String?
    public let paneIdentifier: String?

    public init(
        terminal: TerminalPreference,
        instanceID: CLIInstanceID,
        processIdentifier: Int32,
        windowIdentifier: String,
        tabIdentifier: String? = nil,
        paneIdentifier: String? = nil
    ) throws {
        guard processIdentifier > 0 else {
            throw TerminalContractError.invalidProcessIdentifier
        }
        try validateOpaqueIdentifier(windowIdentifier)
        try tabIdentifier.map(validateOpaqueIdentifier)
        try paneIdentifier.map(validateOpaqueIdentifier)
        self.terminal = terminal
        self.instanceID = instanceID
        self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier
        self.tabIdentifier = tabIdentifier
        self.paneIdentifier = paneIdentifier
    }
}

public enum TerminalTargetMatch: String, Codable, CaseIterable, Sendable {
    case exact
    case applicationOnly
    case wrongApplication
    case wrongWindow
    case wrongTab
    case wrongPane
    case unavailable
    case unknown
}

public struct TerminalContextEvidence: Codable, Equatable, Sendable {
    public let target: TerminalSurfaceTarget
    public let match: TerminalTargetMatch
    public let context: TerminalUIContext
    public let observedAtUptimeMilliseconds: UInt64

    public init(
        target: TerminalSurfaceTarget,
        match: TerminalTargetMatch,
        context: TerminalUIContext,
        observedAtUptimeMilliseconds: UInt64
    ) {
        self.target = target
        self.match = match
        self.context = context
        self.observedAtUptimeMilliseconds = observedAtUptimeMilliseconds
    }
}

public enum TerminalFocusOutcome: String, Codable, Sendable {
    case alreadyFocused
    case focused
    case failed
}

public struct OpenCopilotRequest: Equatable, Sendable {
    public let terminal: TerminalApplicationDescriptor
    public let cliExecutable: CLIExecutableDescriptor
    public let projectDirectoryURL: URL

    public init(
        terminal: TerminalApplicationDescriptor,
        cliExecutable: CLIExecutableDescriptor,
        projectDirectoryURL: URL
    ) throws {
        guard
            projectDirectoryURL.isFileURL,
            projectDirectoryURL.path.hasPrefix("/"),
            terminal.applicationURL.isFileURL,
            cliExecutable.candidateURL.isFileURL
        else {
            throw TerminalContractError.invalidURL
        }
        self.terminal = terminal
        self.cliExecutable = cliExecutable
        self.projectDirectoryURL = projectDirectoryURL.standardizedFileURL
    }
}

public struct TerminalLaunchPlan: Equatable, Sendable {
    public static let maximumArgumentCount = 64
    public static let maximumArgumentBytes = 4096

    public let launchExecutableURL: URL
    public let arguments: [String]
    public let workingDirectoryURL: URL
    public let surfaceDisposition: TerminalLaunchSurface
    public let surfaceAssociationToken: SurfaceAssociationToken?

    public init(
        launchExecutableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        surfaceDisposition: TerminalLaunchSurface,
        surfaceAssociationToken: SurfaceAssociationToken? = nil
    ) throws {
        guard
            launchExecutableURL.isFileURL,
            launchExecutableURL.path.hasPrefix("/"),
            workingDirectoryURL.isFileURL,
            workingDirectoryURL.path.hasPrefix("/")
        else {
            throw TerminalContractError.invalidURL
        }
        guard
            arguments.count <= Self.maximumArgumentCount,
            arguments.allSatisfy({
                !$0.contains("\0") && $0.utf8.count <= Self.maximumArgumentBytes
            })
        else {
            throw TerminalContractError.invalidArguments
        }
        self.launchExecutableURL = launchExecutableURL.standardizedFileURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL.standardizedFileURL
        self.surfaceDisposition = surfaceDisposition
        self.surfaceAssociationToken = surfaceAssociationToken
    }
}

public enum TerminalLaunchSurface: String, Codable, Sendable {
    case newTab
    case newWindow
}

public protocol TerminalAdapter: Sendable {
    var terminal: SupportedTerminal { get }

    func discoverTargets(for instanceID: CLIInstanceID) async throws -> [TerminalSurfaceTarget]
    func observeContext(for target: TerminalSurfaceTarget) async throws -> TerminalContextEvidence
    func focus(_ target: TerminalSurfaceTarget) async throws -> TerminalFocusOutcome
}

private func validateOpaqueIdentifier(_ value: String) throws {
    guard
        !value.isEmpty,
        value.utf8.count <= 256,
        value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E })
    else {
        throw TerminalContractError.invalidIdentifier
    }
}
