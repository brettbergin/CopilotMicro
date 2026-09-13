import Foundation

public enum SupportedTerminal: String, Codable, CaseIterable, Sendable {
    case ghostty
    case iTerm2 = "iterm2"
    case terminal

    public var displayName: String {
        switch self {
        case .ghostty:
            "Ghostty"
        case .iTerm2:
            "iTerm2"
        case .terminal:
            "Terminal"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .ghostty:
            "com.mitchellh.ghostty"
        case .iTerm2:
            "com.googlecode.iterm2"
        case .terminal:
            "com.apple.Terminal"
        }
    }

    public init?(bundleIdentifier: String) {
        guard let terminal = Self.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier })
        else {
            return nil
        }
        self = terminal
    }
}

public enum TerminalDiscoverySource: String, Codable, Sendable {
    case commonLocation
    case userSelected
}

public struct TerminalApplicationDescriptor: Codable, Equatable, Hashable, Sendable {
    public let terminal: SupportedTerminal
    public let bundleIdentifier: String
    public let applicationURL: URL
    public let executableURL: URL
    public let version: String?
    public let source: TerminalDiscoverySource

    public init(
        terminal: SupportedTerminal,
        bundleIdentifier: String,
        applicationURL: URL,
        executableURL: URL,
        version: String?,
        source: TerminalDiscoverySource
    ) {
        self.terminal = terminal
        self.bundleIdentifier = bundleIdentifier
        self.applicationURL = applicationURL
        self.executableURL = executableURL
        self.version = version
        self.source = source
    }
}

public enum TerminalApplicationValidationError: String, Error, Codable, LocalizedError, Sendable {
    case applicationMissing
    case bundleMetadataUnreadable
    case executableEscapesBundle
    case executableMissing
    case executableNotRunnable
    case invalidApplicationBundle
    case missingBundleIdentifier
    case missingExecutableName
    case unsupportedBundleIdentifier

    public var errorDescription: String? {
        switch self {
        case .applicationMissing:
            "The selected terminal application no longer exists."
        case .bundleMetadataUnreadable:
            "The terminal application's Info.plist is missing, oversized, or malformed."
        case .executableEscapesBundle:
            "The terminal executable resolves outside its application bundle."
        case .executableMissing:
            "The terminal application's declared executable is missing."
        case .executableNotRunnable:
            "The terminal application's declared executable is not a runnable regular file."
        case .invalidApplicationBundle:
            "The selected path is not an application bundle."
        case .missingBundleIdentifier:
            "The terminal application does not declare a bundle identifier."
        case .missingExecutableName:
            "The terminal application does not declare a safe executable name."
        case .unsupportedBundleIdentifier:
            "The application is not a supported terminal."
        }
    }
}

public struct TerminalDiscoveryIssue: Codable, Equatable, Sendable {
    public let candidateURL: URL
    public let source: TerminalDiscoverySource
    public let error: TerminalApplicationValidationError

    public init(
        candidateURL: URL,
        source: TerminalDiscoverySource,
        error: TerminalApplicationValidationError
    ) {
        self.candidateURL = candidateURL
        self.source = source
        self.error = error
    }
}

public struct TerminalDiscoveryReport: Codable, Equatable, Sendable {
    public let installations: [TerminalApplicationDescriptor]
    public let issues: [TerminalDiscoveryIssue]

    public init(
        installations: [TerminalApplicationDescriptor],
        issues: [TerminalDiscoveryIssue]
    ) {
        self.installations = installations
        self.issues = issues
    }
}

public struct TerminalApplicationDiscovery {
    public static let maximumInfoPlistBytes = 1_048_576

    private let fileManager: FileManager
    private let searchRoots: [URL]

    public init(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.searchRoots =
            searchRoots ?? Self.defaultSearchRoots(fileManager: fileManager)
    }

    public static func defaultSearchRoots(fileManager: FileManager = .default) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Applications",
                isDirectory: true
            ),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        ]
    }

    public func discover(
        userSelectedApplicationURLs: [URL] = []
    ) -> TerminalDiscoveryReport {
        var installationsByPath: [String: TerminalApplicationDescriptor] = [:]
        var issues: [TerminalDiscoveryIssue] = []

        for root in uniqueCanonicalURLs(searchRoots) {
            guard isDirectory(root) else { continue }
            guard
                let candidates = try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                continue
            }
            for candidate in candidates where candidate.pathExtension.lowercased() == "app" {
                collect(
                    candidate,
                    source: .commonLocation,
                    installationsByPath: &installationsByPath,
                    issues: &issues
                )
            }
        }

        for candidate in userSelectedApplicationURLs {
            collect(
                candidate,
                source: .userSelected,
                installationsByPath: &installationsByPath,
                issues: &issues
            )
        }

        return TerminalDiscoveryReport(
            installations: installationsByPath.values.sorted {
                if $0.terminal.rawValue != $1.terminal.rawValue {
                    return $0.terminal.rawValue < $1.terminal.rawValue
                }
                return $0.applicationURL.path < $1.applicationURL.path
            },
            issues: issues.sorted { $0.candidateURL.path < $1.candidateURL.path }
        )
    }

    public func validateApplication(
        at candidateURL: URL,
        source: TerminalDiscoverySource = .userSelected
    ) throws -> TerminalApplicationDescriptor {
        let applicationURL = canonicalURL(candidateURL)
        guard applicationURL.pathExtension.lowercased() == "app" else {
            throw TerminalApplicationValidationError.invalidApplicationBundle
        }
        guard isDirectory(applicationURL) else {
            throw TerminalApplicationValidationError.applicationMissing
        }

        let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: infoURL.path),
            let size = (attributes[.size] as? NSNumber)?.intValue,
            size <= Self.maximumInfoPlistBytes,
            let data = try? Data(contentsOf: infoURL),
            let metadata = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        else {
            throw TerminalApplicationValidationError.bundleMetadataUnreadable
        }
        guard let bundleIdentifier = metadata["CFBundleIdentifier"] as? String else {
            throw TerminalApplicationValidationError.missingBundleIdentifier
        }
        guard let terminal = SupportedTerminal(bundleIdentifier: bundleIdentifier) else {
            throw TerminalApplicationValidationError.unsupportedBundleIdentifier
        }
        guard
            let executableName = metadata["CFBundleExecutable"] as? String,
            isSafeExecutableName(executableName)
        else {
            throw TerminalApplicationValidationError.missingExecutableName
        }

        let executableDirectory = canonicalURL(
            applicationURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        )
        guard isDescendant(executableDirectory, of: applicationURL) else {
            throw TerminalApplicationValidationError.executableEscapesBundle
        }
        let executableURL = canonicalURL(
            executableDirectory.appendingPathComponent(executableName)
        )
        guard isDescendant(executableURL, of: executableDirectory) else {
            throw TerminalApplicationValidationError.executableEscapesBundle
        }
        guard fileManager.fileExists(atPath: executableURL.path) else {
            throw TerminalApplicationValidationError.executableMissing
        }
        guard
            isRegularFile(executableURL),
            fileManager.isExecutableFile(atPath: executableURL.path)
        else {
            throw TerminalApplicationValidationError.executableNotRunnable
        }

        return TerminalApplicationDescriptor(
            terminal: terminal,
            bundleIdentifier: bundleIdentifier,
            applicationURL: applicationURL,
            executableURL: executableURL,
            version: validVersion(
                (metadata["CFBundleShortVersionString"] as? String)
                    ?? (metadata["CFBundleVersion"] as? String)
            ),
            source: source
        )
    }

    private func collect(
        _ candidateURL: URL,
        source: TerminalDiscoverySource,
        installationsByPath: inout [String: TerminalApplicationDescriptor],
        issues: inout [TerminalDiscoveryIssue]
    ) {
        do {
            let descriptor = try validateApplication(at: candidateURL, source: source)
            let path = descriptor.applicationURL.path
            if installationsByPath[path]?.source != .userSelected
                || source == .userSelected
            {
                installationsByPath[path] = descriptor
            }
        } catch let error as TerminalApplicationValidationError {
            if source == .userSelected
                || ![.missingBundleIdentifier, .unsupportedBundleIdentifier].contains(error)
            {
                issues.append(
                    TerminalDiscoveryIssue(
                        candidateURL: canonicalURL(candidateURL),
                        source: source,
                        error: error
                    )
                )
            }
        } catch {
            issues.append(
                TerminalDiscoveryIssue(
                    candidateURL: canonicalURL(candidateURL),
                    source: source,
                    error: .bundleMetadataUnreadable
                )
            )
        }
    }

    private func uniqueCanonicalURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.compactMap { url in
            let canonical = canonicalURL(url)
            return seen.insert(canonical.path).inserted ? canonical : nil
        }
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let type = attributes[.type] as? FileAttributeType
        else {
            return false
        }
        return type == .typeRegular
    }

    private func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let parentComponents = parent.pathComponents
        return candidateComponents.count > parentComponents.count
            && Array(candidateComponents.prefix(parentComponents.count)) == parentComponents
    }

    private func isSafeExecutableName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }

    private func validVersion(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128 else {
            return nil
        }
        return value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
            ? value
            : nil
    }
}

public enum CLIExecutableDiscoverySource: String, Codable, Sendable {
    case commonLocation
    case userSelected
}

public struct CLIExecutableDescriptor: Codable, Equatable, Hashable, Sendable {
    public let candidateURL: URL
    public let resolvedExecutableURL: URL
    public let source: CLIExecutableDiscoverySource

    public init(
        candidateURL: URL,
        resolvedExecutableURL: URL,
        source: CLIExecutableDiscoverySource
    ) {
        self.candidateURL = candidateURL
        self.resolvedExecutableURL = resolvedExecutableURL
        self.source = source
    }
}

public enum CLIExecutableValidationError: String, Error, Codable, LocalizedError, Sendable {
    case executableMissing
    case executableNotRunnable
    case invalidExecutableName
    case invalidExecutablePath

    public var errorDescription: String? {
        switch self {
        case .executableMissing:
            "The selected Copilot CLI executable no longer exists."
        case .executableNotRunnable:
            "The selected Copilot CLI path is not a runnable regular file."
        case .invalidExecutableName:
            "The selected executable must be named copilot."
        case .invalidExecutablePath:
            "The selected Copilot CLI path must be an absolute file URL."
        }
    }
}

public struct CLIExecutableDiscoveryIssue: Codable, Equatable, Sendable {
    public let candidateURL: URL
    public let source: CLIExecutableDiscoverySource
    public let error: CLIExecutableValidationError

    public init(
        candidateURL: URL,
        source: CLIExecutableDiscoverySource,
        error: CLIExecutableValidationError
    ) {
        self.candidateURL = candidateURL
        self.source = source
        self.error = error
    }
}

public struct CLIExecutableDiscoveryReport: Codable, Equatable, Sendable {
    public let executables: [CLIExecutableDescriptor]
    public let issues: [CLIExecutableDiscoveryIssue]

    public init(
        executables: [CLIExecutableDescriptor],
        issues: [CLIExecutableDiscoveryIssue]
    ) {
        self.executables = executables
        self.issues = issues
    }
}

public struct CLIExecutableDiscovery {
    private let candidateURLs: [URL]
    private let fileManager: FileManager

    public init(
        candidateURLs: [URL]? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.candidateURLs =
            candidateURLs ?? Self.defaultCandidateURLs(fileManager: fileManager)
    }

    public static func defaultCandidateURLs(fileManager: FileManager = .default) -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin/copilot"),
            URL(fileURLWithPath: "/usr/local/bin/copilot"),
            URL(fileURLWithPath: "/usr/bin/copilot"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/copilot"),
        ]
    }

    public func discover(
        userSelectedExecutableURLs: [URL] = []
    ) -> CLIExecutableDiscoveryReport {
        var executablesByResolvedPath: [String: CLIExecutableDescriptor] = [:]
        var issues: [CLIExecutableDiscoveryIssue] = []

        for candidate in candidateURLs {
            collect(
                candidate,
                source: .commonLocation,
                executablesByResolvedPath: &executablesByResolvedPath,
                issues: &issues
            )
        }
        for candidate in userSelectedExecutableURLs {
            collect(
                candidate,
                source: .userSelected,
                executablesByResolvedPath: &executablesByResolvedPath,
                issues: &issues
            )
        }

        return CLIExecutableDiscoveryReport(
            executables: executablesByResolvedPath.values.sorted {
                $0.candidateURL.path < $1.candidateURL.path
            },
            issues: issues.sorted { $0.candidateURL.path < $1.candidateURL.path }
        )
    }

    public func validateExecutable(
        at candidateURL: URL,
        source: CLIExecutableDiscoverySource = .userSelected
    ) throws -> CLIExecutableDescriptor {
        let candidate = candidateURL.standardizedFileURL
        guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
            throw CLIExecutableValidationError.invalidExecutablePath
        }
        guard candidate.lastPathComponent == "copilot" else {
            throw CLIExecutableValidationError.invalidExecutableName
        }
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw CLIExecutableValidationError.executableMissing
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard
            isRegularFile(resolved),
            fileManager.isExecutableFile(atPath: resolved.path)
        else {
            throw CLIExecutableValidationError.executableNotRunnable
        }
        return CLIExecutableDescriptor(
            candidateURL: candidate,
            resolvedExecutableURL: resolved,
            source: source
        )
    }

    private func collect(
        _ candidateURL: URL,
        source: CLIExecutableDiscoverySource,
        executablesByResolvedPath: inout [String: CLIExecutableDescriptor],
        issues: inout [CLIExecutableDiscoveryIssue]
    ) {
        do {
            let descriptor = try validateExecutable(at: candidateURL, source: source)
            let path = descriptor.resolvedExecutableURL.path
            if executablesByResolvedPath[path]?.source != .userSelected
                || source == .userSelected
            {
                executablesByResolvedPath[path] = descriptor
            }
        } catch let error as CLIExecutableValidationError {
            if source == .userSelected || error != .executableMissing {
                issues.append(
                    CLIExecutableDiscoveryIssue(
                        candidateURL: candidateURL.standardizedFileURL,
                        source: source,
                        error: error
                    )
                )
            }
        } catch {
            issues.append(
                CLIExecutableDiscoveryIssue(
                    candidateURL: candidateURL.standardizedFileURL,
                    source: source,
                    error: .executableNotRunnable
                )
            )
        }
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let type = attributes[.type] as? FileAttributeType
        else {
            return false
        }
        return type == .typeRegular
    }
}

public enum TerminalPreferenceError: Error, Equatable, LocalizedError, Sendable {
    case invalidApplicationPath
    case invalidCLIExecutablePath
    case unsupportedTerminal

    public var errorDescription: String? {
        switch self {
        case .invalidApplicationPath:
            "The preferred terminal application path is invalid."
        case .invalidCLIExecutablePath:
            "The preferred Copilot CLI executable path is invalid."
        case .unsupportedTerminal:
            "The preferred terminal bundle identifier is unsupported."
        }
    }
}

public struct TerminalPreference: Codable, Equatable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let applicationPath: String

    public init(bundleIdentifier: String, applicationPath: String) throws {
        guard SupportedTerminal(bundleIdentifier: bundleIdentifier) != nil else {
            throw TerminalPreferenceError.unsupportedTerminal
        }
        let url = URL(fileURLWithPath: applicationPath).standardizedFileURL
        guard
            applicationPath.hasPrefix("/"),
            url.pathExtension.lowercased() == "app",
            applicationPath.utf8.count <= 4096
        else {
            throw TerminalPreferenceError.invalidApplicationPath
        }
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = url.path
    }

    public init(_ descriptor: TerminalApplicationDescriptor) {
        bundleIdentifier = descriptor.bundleIdentifier
        applicationPath = descriptor.applicationURL.path
    }
}

public struct CLIExecutablePreference: Codable, Equatable, Hashable, Sendable {
    public let executablePath: String

    public init(executablePath: String) throws {
        let url = URL(fileURLWithPath: executablePath).standardizedFileURL
        guard
            executablePath.hasPrefix("/"),
            url.lastPathComponent == "copilot",
            executablePath.utf8.count <= 4096
        else {
            throw TerminalPreferenceError.invalidCLIExecutablePath
        }
        self.executablePath = url.path
    }

    public init(_ descriptor: CLIExecutableDescriptor) {
        executablePath = descriptor.candidateURL.path
    }
}

public enum TerminalPreferenceResolution: Equatable, Sendable {
    case notSelected
    case available(TerminalApplicationDescriptor)
    case missing(TerminalPreference, alternatives: [TerminalApplicationDescriptor])
}

public enum CLIExecutablePreferenceResolution: Equatable, Sendable {
    case notSelected
    case available(CLIExecutableDescriptor)
    case missing(CLIExecutablePreference, alternatives: [CLIExecutableDescriptor])
}

public enum TerminalPreferenceResolver {
    public static func resolve(
        _ preference: TerminalPreference?,
        in installations: [TerminalApplicationDescriptor]
    ) -> TerminalPreferenceResolution {
        guard let preference else { return .notSelected }
        let preferredURL = URL(fileURLWithPath: preference.applicationPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        if let exact = installations.first(where: {
            $0.bundleIdentifier == preference.bundleIdentifier
                && $0.applicationURL.path == preferredURL.path
        }) {
            return .available(exact)
        }
        let alternatives = installations.filter {
            $0.bundleIdentifier == preference.bundleIdentifier
        }
        return .missing(preference, alternatives: alternatives)
    }

    public static func resolve(
        _ preference: CLIExecutablePreference?,
        in executables: [CLIExecutableDescriptor]
    ) -> CLIExecutablePreferenceResolution {
        guard let preference else { return .notSelected }
        let preferredURL = URL(fileURLWithPath: preference.executablePath).standardizedFileURL
        if let exact = executables.first(where: { $0.candidateURL.path == preferredURL.path }) {
            return .available(exact)
        }
        return .missing(preference, alternatives: executables)
    }
}
