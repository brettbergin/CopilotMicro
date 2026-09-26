import AppKit
import CopilotMicroCore
import Darwin
import Foundation

public enum OSAScriptRunnerError: Error, Equatable, LocalizedError, Sendable {
    case invalidArguments
    case outputTooLarge
    case scriptFailed(Int32, String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "The AppleScript invocation is invalid."
        case .outputTooLarge:
            "The AppleScript response exceeded its safety limit."
        case .scriptFailed(_, let message):
            message
        case .timedOut:
            "The AppleScript operation timed out."
        }
    }
}

public protocol GhosttyScriptRunning: Sendable {
    func run(script: String, arguments: [String]) async throws -> String
}

public struct OSAScriptRunner: GhosttyScriptRunning, Sendable {
    public static let maximumOutputBytes = 65_536
    public static let maximumArgumentCount = 16
    public static let maximumArgumentBytes = 4_096

    public let executableURL: URL
    public let timeoutSeconds: Double

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/osascript"),
        timeoutSeconds: Double = 5
    ) {
        self.executableURL = executableURL
        self.timeoutSeconds = timeoutSeconds
    }

    public func run(script: String, arguments: [String]) async throws -> String {
        guard
            script.utf8.count <= Self.maximumArgumentBytes,
            arguments.count <= Self.maximumArgumentCount,
            arguments.allSatisfy({
                !$0.contains("\0") && $0.utf8.count <= Self.maximumArgumentBytes
            })
        else {
            throw OSAScriptRunnerError.invalidArguments
        }
        return try await Task.detached(priority: .userInitiated) {
            try Self.runBlocking(
                executableURL: executableURL,
                timeoutSeconds: timeoutSeconds,
                script: script,
                arguments: arguments
            )
        }.value
    }

    private static func runBlocking(
        executableURL: URL,
        timeoutSeconds: Double,
        script: String,
        arguments: [String]
    ) throws -> String {
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "com.github.CopilotMicro.OSAScriptRunner.\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let errorURL = captureDirectory.appendingPathComponent("stderr")
        guard
            FileManager.default.createFile(
                atPath: outputURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ),
            FileManager.default.createFile(
                atPath: errorURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw OSAScriptRunnerError.scriptFailed(
                1,
                "Could not create bounded AppleScript output files."
            )
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? errors.close()
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-l", "AppleScript", "-e", script] + arguments
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw OSAScriptRunnerError.timedOut
        }

        try output.synchronize()
        try errors.synchronize()
        let outputBytes = try fileSize(at: outputURL)
        let errorBytes = try fileSize(at: errorURL)
        guard
            outputBytes <= maximumOutputBytes,
            errorBytes <= maximumOutputBytes
        else {
            throw OSAScriptRunnerError.outputTooLarge
        }
        let outputData = try Data(contentsOf: outputURL)
        let errorData = try Data(contentsOf: errorURL)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw OSAScriptRunnerError.scriptFailed(
                process.terminationStatus,
                String(message.prefix(1_024))
            )
        }
        return String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}

public struct GhosttyRunningApplication: Equatable, Sendable {
    public let processIdentifier: Int32
    public let applicationURL: URL

    public init(processIdentifier: Int32, applicationURL: URL) {
        self.processIdentifier = processIdentifier
        self.applicationURL = applicationURL
    }
}

public protocol GhosttyProcessLocating: Sendable {
    func runningApplications() async -> [GhosttyRunningApplication]
}

public struct WorkspaceGhosttyProcessLocator: GhosttyProcessLocating, Sendable {
    public init() {}

    public func runningApplications() async -> [GhosttyRunningApplication] {
        await MainActor.run {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: SupportedTerminal.ghostty.bundleIdentifier
            )
            .filter { !$0.isTerminated }
            .compactMap { application in
                guard let applicationURL = application.bundleURL else { return nil }
                return GhosttyRunningApplication(
                    processIdentifier: application.processIdentifier,
                    applicationURL: applicationURL
                )
            }
            .sorted { $0.processIdentifier < $1.processIdentifier }
        }
    }
}

public enum GhosttyAdapterError: Error, Equatable, LocalizedError, Sendable {
    case automationDenied
    case bindingMissing
    case malformedResponse
    case multipleInstances
    case notRunning
    case selectedInstallationNotRunning
    case scriptFailed(String)
    case surfaceMissing
    case unsafeCLIExecutablePath
    case wrongTerminal

    public var errorDescription: String? {
        switch self {
        case .automationDenied:
            "Automation access to Ghostty is denied."
        case .bindingMissing:
            "No exact Ghostty surface is bound to this Copilot CLI instance."
        case .malformedResponse:
            "Ghostty returned malformed scripting data."
        case .multipleInstances:
            "Multiple Ghostty application processes are running."
        case .notRunning:
            "Ghostty is not running."
        case .selectedInstallationNotRunning:
            "The running Ghostty process is not the selected application installation."
        case .scriptFailed(let message):
            message
        case .surfaceMissing:
            "The bound Ghostty window, tab, or terminal no longer exists."
        case .unsafeCLIExecutablePath:
            "Ghostty Open Copilot requires a CLI path containing only safe command characters."
        case .wrongTerminal:
            "The Ghostty adapter cannot operate on another terminal application."
        }
    }
}

public struct GhosttySurfaceReference: Codable, Equatable, Hashable, Sendable {
    public let windowIdentifier: String
    public let tabIdentifier: String
    public let terminalIdentifier: String

    public init(
        windowIdentifier: String,
        tabIdentifier: String,
        terminalIdentifier: String
    ) throws {
        try validateGhosttyIdentifier(windowIdentifier)
        try validateGhosttyIdentifier(tabIdentifier)
        try validateGhosttyIdentifier(terminalIdentifier)
        self.windowIdentifier = windowIdentifier
        self.tabIdentifier = tabIdentifier
        self.terminalIdentifier = terminalIdentifier
    }
}

public struct GhosttyTargetBinding: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let surface: GhosttySurfaceReference

    public init(
        processIdentifier: Int32,
        surface: GhosttySurfaceReference
    ) throws {
        guard processIdentifier > 0 else {
            throw TerminalContractError.invalidProcessIdentifier
        }
        self.processIdentifier = processIdentifier
        self.surface = surface
    }
}

public struct GhosttySnapshotSurface: Codable, Equatable, Sendable {
    public let reference: GhosttySurfaceReference
    public let tabSelected: Bool
    public let terminalFocused: Bool

    public init(
        reference: GhosttySurfaceReference,
        tabSelected: Bool,
        terminalFocused: Bool
    ) {
        self.reference = reference
        self.tabSelected = tabSelected
        self.terminalFocused = terminalFocused
    }
}

public struct GhosttySnapshot: Codable, Equatable, Sendable {
    public let applicationFrontmost: Bool
    public let frontWindowIdentifier: String?
    public let surfaces: [GhosttySnapshotSurface]

    public init(
        applicationFrontmost: Bool,
        frontWindowIdentifier: String?,
        surfaces: [GhosttySnapshotSurface]
    ) {
        self.applicationFrontmost = applicationFrontmost
        self.frontWindowIdentifier = frontWindowIdentifier
        self.surfaces = surfaces
    }
}

public struct GhosttyQualificationResult: Codable, Equatable, Sendable {
    public let createdWindowIdentifier: String
    public let firstTabIdentifier: String
    public let firstTerminalIdentifier: String
    public let secondTabIdentifier: String
    public let secondTerminalIdentifier: String
    public let splitTerminalIdentifier: String
    public let foregroundDisplacementVerified: Bool
    public let firstFocusOutcome: TerminalFocusOutcome
    public let splitFocusOutcome: TerminalFocusOutcome
    public let cleanupVerified: Bool

    public init(
        createdWindowIdentifier: String,
        firstTabIdentifier: String,
        firstTerminalIdentifier: String,
        secondTabIdentifier: String,
        secondTerminalIdentifier: String,
        splitTerminalIdentifier: String,
        foregroundDisplacementVerified: Bool,
        firstFocusOutcome: TerminalFocusOutcome,
        splitFocusOutcome: TerminalFocusOutcome,
        cleanupVerified: Bool
    ) {
        self.createdWindowIdentifier = createdWindowIdentifier
        self.firstTabIdentifier = firstTabIdentifier
        self.firstTerminalIdentifier = firstTerminalIdentifier
        self.secondTabIdentifier = secondTabIdentifier
        self.secondTerminalIdentifier = secondTerminalIdentifier
        self.splitTerminalIdentifier = splitTerminalIdentifier
        self.foregroundDisplacementVerified = foregroundDisplacementVerified
        self.firstFocusOutcome = firstFocusOutcome
        self.splitFocusOutcome = splitFocusOutcome
        self.cleanupVerified = cleanupVerified
    }
}

public struct GhosttyAdapter: TerminalAdapter, Sendable {
    public static let associationTimeoutMilliseconds: UInt64 = 60_000

    public let terminal = SupportedTerminal.ghostty

    private let installation: TerminalApplicationDescriptor
    private let runner: any GhosttyScriptRunning
    private let processLocator: any GhosttyProcessLocating
    private let bindings: GhosttyTargetBindingStore
    private let associationTokenGenerator: @Sendable () throws -> SurfaceAssociationToken

    public init(
        installation: TerminalApplicationDescriptor,
        runner: any GhosttyScriptRunning = OSAScriptRunner(),
        processLocator: any GhosttyProcessLocating = WorkspaceGhosttyProcessLocator(),
        bindings: GhosttyTargetBindingStore,
        associationTokenGenerator: @escaping @Sendable () throws -> SurfaceAssociationToken = {
            try SurfaceAssociationToken.generate()
        }
    ) throws {
        guard installation.terminal == .ghostty else {
            throw GhosttyAdapterError.wrongTerminal
        }
        self.installation = installation
        self.runner = runner
        self.processLocator = processLocator
        self.bindings = bindings
        self.associationTokenGenerator = associationTokenGenerator
    }

    private func makeOpenCopilotPlan(
        for request: OpenCopilotRequest,
        associationToken: SurfaceAssociationToken
    ) throws -> TerminalLaunchPlan {
        guard
            request.terminal.terminal == .ghostty,
            request.terminal.applicationURL.path == installation.applicationURL.path
        else {
            throw GhosttyAdapterError.wrongTerminal
        }
        let cliPath = request.cliExecutable.candidateURL.path
        guard Self.isSafeGhosttyCommandPath(cliPath) else {
            throw GhosttyAdapterError.unsafeCLIExecutablePath
        }
        return try TerminalLaunchPlan(
            launchExecutableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: [
                "-l",
                "AppleScript",
                "-e",
                GhosttyScripts.newWindow,
                installation.applicationURL.path,
                request.projectDirectoryURL.path,
                cliPath,
                associationToken.rawValue,
            ],
            workingDirectoryURL: request.projectDirectoryURL,
            surfaceDisposition: .newWindow,
            surfaceAssociationToken: associationToken
        )
    }

    public func openCopilot(
        _ request: OpenCopilotRequest
    ) async throws -> GhosttyOpenedSurface {
        let associationToken = try associationTokenGenerator()
        let plan = try makeOpenCopilotPlan(
            for: request,
            associationToken: associationToken
        )
        let initialApplications = await processLocator.runningApplications()
        guard initialApplications.count <= 1 else {
            throw GhosttyAdapterError.multipleInstances
        }
        if let initialApplication = initialApplications.first {
            try validateRunningApplication(initialApplication)
        }
        let nowMilliseconds = Self.uptimeMilliseconds()
        try await bindings.reserve(
            associationToken,
            expiresAtMilliseconds: nowMilliseconds + Self.associationTimeoutMilliseconds,
            nowMilliseconds: nowMilliseconds
        )
        do {
            let output = try await runScript(
                GhosttyScripts.newWindow,
                arguments: Array(plan.arguments.suffix(4))
            )
            let processIdentifier = try await soleProcessIdentifier()
            if let initialProcessIdentifier = initialApplications.first?.processIdentifier,
                processIdentifier != initialProcessIdentifier
            {
                throw GhosttyAdapterError.multipleInstances
            }
            let binding = try GhosttyTargetBinding(
                processIdentifier: processIdentifier,
                surface: Self.parseCreatedSurface(output)
            )
            let claimedInstanceID = try await bindings.attach(
                binding,
                to: associationToken,
                nowMilliseconds: Self.uptimeMilliseconds()
            )
            return GhosttyOpenedSurface(
                associationToken: associationToken,
                binding: binding,
                claimedInstanceID: claimedInstanceID
            )
        } catch {
            await bindings.cancel(associationToken)
            throw error
        }
    }

    public func claim(
        _ associationToken: SurfaceAssociationToken,
        for instanceID: CLIInstanceID
    ) async -> GhosttyAssociationClaimOutcome {
        await claim(
            associationToken,
            for: instanceID,
            nowMilliseconds: Self.uptimeMilliseconds()
        )
    }

    public func claim(
        _ associationToken: SurfaceAssociationToken,
        for instanceID: CLIInstanceID,
        nowMilliseconds: UInt64
    ) async -> GhosttyAssociationClaimOutcome {
        await bindings.claim(
            associationToken,
            for: instanceID,
            nowMilliseconds: nowMilliseconds
        )
    }

    public func discoverTargets(
        for instanceID: CLIInstanceID
    ) async throws -> [TerminalSurfaceTarget] {
        guard let binding = await bindings.binding(for: instanceID) else {
            return []
        }
        let processIdentifier = try await soleProcessIdentifier()
        guard processIdentifier == binding.processIdentifier else {
            throw GhosttyAdapterError.surfaceMissing
        }
        let snapshot = try await snapshot()
        guard snapshot.surfaces.contains(where: { $0.reference == binding.surface }) else {
            throw GhosttyAdapterError.surfaceMissing
        }
        return [
            try TerminalSurfaceTarget(
                terminal: TerminalPreference(installation),
                instanceID: instanceID,
                processIdentifier: processIdentifier,
                windowIdentifier: binding.surface.windowIdentifier,
                tabIdentifier: binding.surface.tabIdentifier,
                paneIdentifier: binding.surface.terminalIdentifier
            )
        ]
    }

    public func observeContext(
        for target: TerminalSurfaceTarget
    ) async throws -> TerminalContextEvidence {
        guard
            target.terminal.bundleIdentifier == installation.bundleIdentifier,
            target.terminal.applicationPath == installation.applicationURL.path
        else {
            throw GhosttyAdapterError.wrongTerminal
        }
        let runningApplications = await processLocator.runningApplications()
        let match: TerminalTargetMatch
        if runningApplications.isEmpty {
            match = .unavailable
        } else if runningApplications.count != 1
            || runningApplications.first?.processIdentifier != target.processIdentifier
            || !isSelectedInstallation(runningApplications[0])
        {
            match = .unknown
        } else {
            match = try await targetMatch(target, snapshot: snapshot())
        }
        return TerminalContextEvidence(
            target: target,
            match: match,
            context: .unknown,
            observedAtUptimeMilliseconds: DispatchTime.now().uptimeNanoseconds / 1_000_000
        )
    }

    public func focus(
        _ target: TerminalSurfaceTarget
    ) async throws -> TerminalFocusOutcome {
        let before = try await observeContext(for: target)
        if before.match == .exact {
            return .alreadyFocused
        }
        guard ![.unavailable, .unknown].contains(before.match) else {
            return .failed
        }
        let result = try await runScript(
            GhosttyScripts.focus,
            arguments: [
                installation.applicationURL.path,
                target.windowIdentifier,
                target.tabIdentifier ?? "",
                target.paneIdentifier ?? "",
            ]
        )
        guard result == "focused" else {
            return .failed
        }
        return try await observeContext(for: target).match == .exact
            ? .focused
            : .failed
    }

    public func snapshot() async throws -> GhosttySnapshot {
        _ = try await soleProcessIdentifier()
        let output = try await runScript(
            GhosttyScripts.snapshot,
            arguments: [installation.applicationURL.path]
        )
        return try Self.parseSnapshot(output)
    }

    public func qualifySurfaceRoundTrip(
        workingDirectoryURL: URL,
        displaceFrontmostApplication: Bool = false
    ) async throws -> GhosttyQualificationResult {
        let processIdentifier = try await soleProcessIdentifier()
        let initialReferences = Set(try await snapshot().surfaces.map(\.reference))
        let qualificationToken = try associationTokenGenerator()
        let createdOutput = try await runScript(
            GhosttyScripts.createQualificationSurfaces,
            arguments: [
                installation.applicationURL.path,
                workingDirectoryURL.path,
                "/usr/bin/true",
                qualificationToken.rawValue,
            ]
        )
        let created = try Self.parseQualificationSurfaces(createdOutput)
        let instanceID = try CLIInstanceID(rawValue: "ghostty-qualification")
        let terminalPreference = TerminalPreference(installation)
        let firstTarget = try TerminalSurfaceTarget(
            terminal: terminalPreference,
            instanceID: instanceID,
            processIdentifier: processIdentifier,
            windowIdentifier: created.windowIdentifier,
            tabIdentifier: created.firstTabIdentifier,
            paneIdentifier: created.firstTerminalIdentifier
        )
        let splitTarget = try TerminalSurfaceTarget(
            terminal: terminalPreference,
            instanceID: instanceID,
            processIdentifier: processIdentifier,
            windowIdentifier: created.windowIdentifier,
            tabIdentifier: created.secondTabIdentifier,
            paneIdentifier: created.splitTerminalIdentifier
        )

        do {
            let foregroundDisplacementVerified: Bool
            if displaceFrontmostApplication {
                let activated = await MainActor.run {
                    NSRunningApplication.runningApplications(
                        withBundleIdentifier: "com.apple.finder"
                    )
                    .first?
                    .activate(options: []) ?? false
                }
                try await Task.sleep(for: .milliseconds(200))
                let displacedEvidence = try await observeContext(for: firstTarget)
                foregroundDisplacementVerified =
                    activated && displacedEvidence.match == .wrongApplication
                guard foregroundDisplacementVerified else {
                    throw GhosttyAdapterError.scriptFailed(
                        "Could not verify exact focus from another foreground application."
                    )
                }
            } else {
                foregroundDisplacementVerified = false
            }
            let firstOutcome = try await focus(firstTarget)
            let splitOutcome = try await focus(splitTarget)
            guard firstOutcome != .failed, splitOutcome != .failed else {
                throw GhosttyAdapterError.surfaceMissing
            }
            try await closeQualificationWindow(created.windowIdentifier)
            let finalReferences = Set(try await snapshot().surfaces.map(\.reference))
            let cleanupVerified =
                !finalReferences.contains {
                    $0.windowIdentifier == created.windowIdentifier
                }
                && finalReferences == initialReferences
            guard cleanupVerified else {
                throw GhosttyAdapterError.scriptFailed(
                    "The temporary Ghostty qualification window did not close."
                )
            }
            return GhosttyQualificationResult(
                createdWindowIdentifier: created.windowIdentifier,
                firstTabIdentifier: created.firstTabIdentifier,
                firstTerminalIdentifier: created.firstTerminalIdentifier,
                secondTabIdentifier: created.secondTabIdentifier,
                secondTerminalIdentifier: created.secondTerminalIdentifier,
                splitTerminalIdentifier: created.splitTerminalIdentifier,
                foregroundDisplacementVerified: foregroundDisplacementVerified,
                firstFocusOutcome: firstOutcome,
                splitFocusOutcome: splitOutcome,
                cleanupVerified: cleanupVerified
            )
        } catch {
            try? await closeQualificationWindow(created.windowIdentifier)
            throw error
        }
    }

    public func qualifyAssociationEnvironment(
        probeExecutableURL: URL,
        resultURL: URL
    ) async throws -> Bool {
        let standardizedProbeExecutableURL = probeExecutableURL.standardizedFileURL
        let standardizedResultURL = resultURL.standardizedFileURL
        guard Self.isSafeGhosttyCommandPath(standardizedProbeExecutableURL.path),
            standardizedResultURL.isFileURL,
            standardizedResultURL.path.hasPrefix(
                FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"
            ),
            !FileManager.default.fileExists(atPath: standardizedResultURL.path)
        else {
            throw GhosttyAdapterError.unsafeCLIExecutablePath
        }
        let processIdentifier = try await soleProcessIdentifier()
        let initialReferences = Set(try await snapshot().surfaces.map(\.reference))
        let associationToken = try associationTokenGenerator()
        let createdOutput = try await runScript(
            GhosttyScripts.newAssociationProbeWindow,
            arguments: [
                installation.applicationURL.path,
                FileManager.default.temporaryDirectory.path,
                standardizedProbeExecutableURL.path,
                associationToken.rawValue,
                standardizedResultURL.path,
            ]
        )
        let created = try Self.parseCreatedSurface(createdOutput)
        do {
            guard try await soleProcessIdentifier() == processIdentifier else {
                throw GhosttyAdapterError.multipleInstances
            }
            let deadline = Date().addingTimeInterval(5)
            var probeResult: GhosttyAssociationProbeResult?
            while probeResult == nil, Date() < deadline {
                if FileManager.default.fileExists(atPath: standardizedResultURL.path) {
                    let data = try Data(contentsOf: standardizedResultURL)
                    probeResult = try JSONDecoder().decode(
                        GhosttyAssociationProbeResult.self,
                        from: data
                    )
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard
                probeResult?.schemaVersion == 1,
                probeResult?.surfaceAssociationToken == associationToken
            else {
                throw GhosttyAdapterError.scriptFailed(
                    "The Ghostty child process did not inherit the expected surface token."
                )
            }
            try await closeQualificationWindow(created.windowIdentifier)
            try? FileManager.default.removeItem(at: standardizedResultURL)
            let finalReferences = Set(try await snapshot().surfaces.map(\.reference))
            guard finalReferences == initialReferences else {
                throw GhosttyAdapterError.scriptFailed(
                    "The Ghostty association probe did not preserve existing surfaces."
                )
            }
            return true
        } catch {
            try? await closeQualificationWindow(created.windowIdentifier)
            try? FileManager.default.removeItem(at: standardizedResultURL)
            throw error
        }
    }

    static func parseSnapshot(_ output: String) throws -> GhosttySnapshot {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        guard let header = lines.first else {
            throw GhosttyAdapterError.malformedResponse
        }
        let headerFields = header.split(separator: "\t", omittingEmptySubsequences: false)
        guard
            headerFields.count == 3,
            headerFields[0] == "snapshot",
            let frontmost = parseBoolean(headerFields[1])
        else {
            throw GhosttyAdapterError.malformedResponse
        }
        let frontWindow = headerFields[2].isEmpty ? nil : String(headerFields[2])
        if let frontWindow {
            try validateGhosttyIdentifier(frontWindow)
        }
        let surfaces = try lines.dropFirst().map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard
                fields.count == 6,
                fields[0] == "surface",
                let selected = parseBoolean(fields[4]),
                let focused = parseBoolean(fields[5])
            else {
                throw GhosttyAdapterError.malformedResponse
            }
            return try GhosttySnapshotSurface(
                reference: GhosttySurfaceReference(
                    windowIdentifier: String(fields[1]),
                    tabIdentifier: String(fields[2]),
                    terminalIdentifier: String(fields[3])
                ),
                tabSelected: selected,
                terminalFocused: focused
            )
        }
        guard surfaces.count <= 256 else {
            throw GhosttyAdapterError.malformedResponse
        }
        return GhosttySnapshot(
            applicationFrontmost: frontmost,
            frontWindowIdentifier: frontWindow,
            surfaces: surfaces
        )
    }

    static func parseCreatedSurface(_ output: String) throws -> GhosttySurfaceReference {
        let fields = output.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "created" else {
            throw GhosttyAdapterError.malformedResponse
        }
        return try GhosttySurfaceReference(
            windowIdentifier: String(fields[1]),
            tabIdentifier: String(fields[2]),
            terminalIdentifier: String(fields[3])
        )
    }

    private struct QualificationSurfaces {
        let windowIdentifier: String
        let firstTabIdentifier: String
        let firstTerminalIdentifier: String
        let secondTabIdentifier: String
        let secondTerminalIdentifier: String
        let splitTerminalIdentifier: String
    }

    private static func parseQualificationSurfaces(
        _ output: String
    ) throws -> QualificationSurfaces {
        let fields = output.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 7, fields[0] == "created" else {
            throw GhosttyAdapterError.malformedResponse
        }
        let values = fields.dropFirst().map(String.init)
        try values.forEach(validateGhosttyIdentifier)
        return QualificationSurfaces(
            windowIdentifier: values[0],
            firstTabIdentifier: values[1],
            firstTerminalIdentifier: values[2],
            secondTabIdentifier: values[3],
            secondTerminalIdentifier: values[4],
            splitTerminalIdentifier: values[5]
        )
    }

    private func closeQualificationWindow(
        _ windowIdentifier: String
    ) async throws {
        let result = try await runScript(
            GhosttyScripts.closeWindow,
            arguments: [installation.applicationURL.path, windowIdentifier]
        )
        guard result == "closed" || result == "missing" else {
            throw GhosttyAdapterError.malformedResponse
        }
    }

    private func soleProcessIdentifier() async throws -> Int32 {
        let applications = await processLocator.runningApplications()
        guard !applications.isEmpty else {
            throw GhosttyAdapterError.notRunning
        }
        guard applications.count == 1, let application = applications.first else {
            throw GhosttyAdapterError.multipleInstances
        }
        try validateRunningApplication(application)
        return application.processIdentifier
    }

    private func validateRunningApplication(
        _ application: GhosttyRunningApplication
    ) throws {
        guard isSelectedInstallation(application) else {
            throw GhosttyAdapterError.selectedInstallationNotRunning
        }
    }

    private func isSelectedInstallation(
        _ application: GhosttyRunningApplication
    ) -> Bool {
        canonicalURL(application.applicationURL) == canonicalURL(installation.applicationURL)
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func targetMatch(
        _ target: TerminalSurfaceTarget,
        snapshot: GhosttySnapshot
    ) -> TerminalTargetMatch {
        let windowSurfaces = snapshot.surfaces.filter {
            $0.reference.windowIdentifier == target.windowIdentifier
        }
        guard !windowSurfaces.isEmpty else { return .wrongWindow }
        let tabSurfaces = windowSurfaces.filter {
            $0.reference.tabIdentifier == target.tabIdentifier
        }
        guard !tabSurfaces.isEmpty else { return .wrongTab }
        guard
            let surface = tabSurfaces.first(where: {
                $0.reference.terminalIdentifier == target.paneIdentifier
            })
        else {
            return .wrongPane
        }
        guard snapshot.applicationFrontmost else { return .wrongApplication }
        guard snapshot.frontWindowIdentifier == target.windowIdentifier else {
            return .wrongWindow
        }
        guard surface.tabSelected else { return .wrongTab }
        guard surface.terminalFocused else { return .wrongPane }
        return .exact
    }

    private func runScript(
        _ script: String,
        arguments: [String]
    ) async throws -> String {
        do {
            return try await runner.run(script: script, arguments: arguments)
        } catch let error as OSAScriptRunnerError {
            if case .scriptFailed(_, let message) = error,
                message.contains("-1743")
                    || message.localizedCaseInsensitiveContains("not authorized")
                    || message.localizedCaseInsensitiveContains("not permitted")
            {
                throw GhosttyAdapterError.automationDenied
            }
            throw GhosttyAdapterError.scriptFailed(
                error.errorDescription ?? "Ghostty automation failed."
            )
        } catch let error as GhosttyAdapterError {
            throw error
        } catch {
            throw GhosttyAdapterError.scriptFailed("Ghostty automation failed.")
        }
    }

    private static func parseBoolean(_ value: Substring) -> Bool? {
        switch value {
        case "true":
            true
        case "false":
            false
        default:
            nil
        }
    }

    private static func isSafeGhosttyCommandPath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && value.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                    || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                    || [0x2F, 0x2E, 0x5F, 0x2D, 0x2B].contains(scalar.value)
            }
    }

    private static func uptimeMilliseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}

enum GhosttyScripts {
    static let snapshot = #"""
        on run argv
            set applicationPath to item 1 of argv
            set textTab to ASCII character 9
            set textLinefeed to ASCII character 10
            set rows to {}
            using terms from application "Ghostty"
                tell application applicationPath
                    set isFrontmost to frontmost
                    set frontWindowID to ""
                    try
                        set frontWindowID to id of front window as text
                    end try
                    set end of rows to "snapshot" & textTab & (isFrontmost as text) & textTab & frontWindowID
                    repeat with currentWindow in windows
                        set windowID to id of currentWindow as text
                        set selectedTabID to ""
                        try
                            set selectedTabID to id of selected tab of currentWindow as text
                        end try
                        repeat with currentTab in tabs of currentWindow
                            set tabID to id of currentTab as text
                            set focusedTerminalID to ""
                            try
                                set focusedTerminalID to id of focused terminal of currentTab as text
                            end try
                            repeat with currentTerminal in terminals of currentTab
                                set terminalID to id of currentTerminal as text
                                set tabSelected to tabID is selectedTabID
                                set terminalFocused to terminalID is focusedTerminalID
                                set end of rows to "surface" & textTab & windowID & textTab & tabID & textTab & terminalID & textTab & (tabSelected as text) & textTab & (terminalFocused as text)
                            end repeat
                        end repeat
                    end repeat
                end tell
            end using terms from
            set AppleScript's text item delimiters to textLinefeed
            return rows as text
        end run
        """#

    static let focus = #"""
        on run argv
            set applicationPath to item 1 of argv
            set wantedWindow to item 2 of argv
            set wantedTab to item 3 of argv
            set wantedTerminal to item 4 of argv
            using terms from application "Ghostty"
                tell application applicationPath
                    repeat with currentWindow in windows
                        if (id of currentWindow as text) is wantedWindow then
                            repeat with currentTab in tabs of currentWindow
                                if (id of currentTab as text) is wantedTab then
                                    repeat with currentTerminal in terminals of currentTab
                                        if (id of currentTerminal as text) is wantedTerminal then
                                            activate window currentWindow
                                            select tab currentTab
                                            focus currentTerminal
                                            return "focused"
                                        end if
                                    end repeat
                                end if
                            end repeat
                        end if
                    end repeat
                end tell
            end using terms from
            return "missing"
        end run
        """#

    static let newWindow = #"""
        on run argv
            set applicationPath to item 1 of argv
            set projectDirectory to item 2 of argv
            set copilotExecutable to item 3 of argv
            set associationToken to item 4 of argv
            set textTab to ASCII character 9
            using terms from application "Ghostty"
                tell application applicationPath
                    set surfaceConfiguration to new surface configuration
                    set initial working directory of surfaceConfiguration to projectDirectory
                    set command of surfaceConfiguration to copilotExecutable
                    set wait after command of surfaceConfiguration to true
                    set environment variables of surfaceConfiguration to {"COPILOT_MICRO_SURFACE_TOKEN=" & associationToken}
                    set createdWindow to new window with configuration surfaceConfiguration
                    set createdTab to selected tab of createdWindow
                    set createdTerminal to focused terminal of createdTab
                    return "created" & textTab & (id of createdWindow as text) & textTab & (id of createdTab as text) & textTab & (id of createdTerminal as text)
                end tell
            end using terms from
        end run
        """#

    static let createQualificationSurfaces = #"""
        on run argv
            set applicationPath to item 1 of argv
            set projectDirectory to item 2 of argv
            set qualificationCommand to item 3 of argv
            set associationToken to item 4 of argv
            set textTab to ASCII character 9
            using terms from application "Ghostty"
                tell application applicationPath
                    set surfaceConfiguration to new surface configuration
                    set initial working directory of surfaceConfiguration to projectDirectory
                    set command of surfaceConfiguration to qualificationCommand
                    set wait after command of surfaceConfiguration to true
                    set environment variables of surfaceConfiguration to {"COPILOT_MICRO_SURFACE_TOKEN=" & associationToken}
                    set createdWindow to new window with configuration surfaceConfiguration
                    try
                        set firstTab to selected tab of createdWindow
                        set firstTerminal to focused terminal of firstTab
                        set secondTab to new tab in createdWindow with configuration surfaceConfiguration
                        set secondTerminal to focused terminal of secondTab
                        set splitTerminal to split secondTerminal direction right with configuration surfaceConfiguration
                        return "created" & textTab & (id of createdWindow as text) & textTab & (id of firstTab as text) & textTab & (id of firstTerminal as text) & textTab & (id of secondTab as text) & textTab & (id of secondTerminal as text) & textTab & (id of splitTerminal as text)
                    on error messageText number errorNumber
                        try
                            close window createdWindow
                        end try
                        error messageText number errorNumber
                    end try
                end tell
            end using terms from
        end run
        """#

    static let newAssociationProbeWindow = #"""
        on run argv
            set applicationPath to item 1 of argv
            set projectDirectory to item 2 of argv
            set probeExecutable to item 3 of argv
            set associationToken to item 4 of argv
            set resultPath to item 5 of argv
            set textTab to ASCII character 9
            using terms from application "Ghostty"
                tell application applicationPath
                    set surfaceConfiguration to new surface configuration
                    set initial working directory of surfaceConfiguration to projectDirectory
                    set command of surfaceConfiguration to probeExecutable
                    set wait after command of surfaceConfiguration to true
                    set environment variables of surfaceConfiguration to {"COPILOT_MICRO_SURFACE_TOKEN=" & associationToken, "COPILOT_MICRO_ASSOCIATION_RESULT_PATH=" & resultPath}
                    set createdWindow to new window with configuration surfaceConfiguration
                    set createdTab to selected tab of createdWindow
                    set createdTerminal to focused terminal of createdTab
                    return "created" & textTab & (id of createdWindow as text) & textTab & (id of createdTab as text) & textTab & (id of createdTerminal as text)
                end tell
            end using terms from
        end run
        """#

    static let closeWindow = #"""
        on run argv
            set applicationPath to item 1 of argv
            set wantedWindow to item 2 of argv
            using terms from application "Ghostty"
                tell application applicationPath
                    repeat with currentWindow in windows
                        if (id of currentWindow as text) is wantedWindow then
                            close window currentWindow
                            return "closed"
                        end if
                    end repeat
                end tell
            end using terms from
            return "missing"
        end run
        """#
}

private func validateGhosttyIdentifier(_ value: String) throws {
    guard
        !value.isEmpty,
        value.utf8.count <= 256,
        value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E })
    else {
        throw GhosttyAdapterError.malformedResponse
    }
}
