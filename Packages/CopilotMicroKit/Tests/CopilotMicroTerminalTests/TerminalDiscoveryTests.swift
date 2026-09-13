import Foundation
import Testing

@testable import CopilotMicroTerminal

@Suite("Terminal and CLI discovery")
struct TerminalDiscoveryTests {
    @Test("Discovery finds supported renamed bundles and deduplicates symlinks")
    func discoversSupportedApplications() throws {
        try withTemporaryDirectory { root in
            let applications = root.appendingPathComponent("Applications", isDirectory: true)
            let userApplications = root.appendingPathComponent(
                "UserApplications",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: applications,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: userApplications,
                withIntermediateDirectories: true
            )
            let ghostty = try createApplication(
                in: applications,
                name: "Renamed Ghostty.app",
                bundleIdentifier: SupportedTerminal.ghostty.bundleIdentifier,
                version: "1.2.3"
            )
            _ = try createApplication(
                in: applications,
                name: "iTerm.app",
                bundleIdentifier: SupportedTerminal.iTerm2.bundleIdentifier
            )
            _ = try createApplication(
                in: applications,
                name: "Notes.app",
                bundleIdentifier: "com.example.Notes"
            )
            try FileManager.default.createSymbolicLink(
                at: userApplications.appendingPathComponent("Ghostty.app"),
                withDestinationURL: ghostty
            )

            let report = TerminalApplicationDiscovery(
                searchRoots: [applications, userApplications]
            ).discover()

            #expect(report.installations.count == 2)
            #expect(report.installations.map(\.terminal) == [.ghostty, .iTerm2])
            #expect(report.installations.first?.version == "1.2.3")
            #expect(report.issues.isEmpty)
        }
    }

    @Test("Manual selection reports unsupported and malformed applications")
    func reportsInvalidManualSelections() throws {
        try withTemporaryDirectory { root in
            let unsupported = try createApplication(
                in: root,
                name: "Other.app",
                bundleIdentifier: "com.example.Other"
            )
            let broken = root.appendingPathComponent("Ghostty.app", isDirectory: true)
            try FileManager.default.createDirectory(
                at: broken.appendingPathComponent("Contents", isDirectory: true),
                withIntermediateDirectories: true
            )

            let report = TerminalApplicationDiscovery(searchRoots: []).discover(
                userSelectedApplicationURLs: [unsupported, broken]
            )

            #expect(report.installations.isEmpty)
            #expect(
                Set(report.issues.map(\.error))
                    == Set([.unsupportedBundleIdentifier, .bundleMetadataUnreadable])
            )
        }
    }

    @Test("A moved preferred terminal never silently selects another installation")
    func movedPreferenceRequiresReselection() throws {
        try withTemporaryDirectory { root in
            let originalRoot = root.appendingPathComponent("Original", isDirectory: true)
            let movedRoot = root.appendingPathComponent("Moved", isDirectory: true)
            try FileManager.default.createDirectory(
                at: originalRoot,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: movedRoot,
                withIntermediateDirectories: true
            )
            let original = try createApplication(
                in: originalRoot,
                name: "Ghostty.app",
                bundleIdentifier: SupportedTerminal.ghostty.bundleIdentifier
            )
            let originalDescriptor = try TerminalApplicationDiscovery(searchRoots: [])
                .validateApplication(at: original)
            let preference = TerminalPreference(originalDescriptor)
            guard
                case .available(let available) =
                    TerminalPreferenceResolver.resolve(
                        preference,
                        in: [originalDescriptor]
                    )
            else {
                Issue.record("Expected the exact saved terminal path to resolve.")
                return
            }
            #expect(available == originalDescriptor)
            try FileManager.default.removeItem(at: original)
            _ = try createApplication(
                in: movedRoot,
                name: "Ghostty.app",
                bundleIdentifier: SupportedTerminal.ghostty.bundleIdentifier
            )
            let current = TerminalApplicationDiscovery(searchRoots: [movedRoot]).discover()

            guard
                case .missing(let missing, let alternatives) =
                    TerminalPreferenceResolver.resolve(
                        preference,
                        in: current.installations
                    )
            else {
                Issue.record("Expected the moved preference to remain unavailable.")
                return
            }
            #expect(missing == preference)
            #expect(alternatives.count == 1)
            #expect(alternatives.first?.applicationURL.path.contains("/Moved/") == true)
        }
    }

    @Test("Application executable directories cannot escape through symlinks")
    func rejectsEscapingExecutableDirectory() throws {
        try withTemporaryDirectory { root in
            let application = root.appendingPathComponent("Ghostty.app", isDirectory: true)
            let contents = application.appendingPathComponent("Contents", isDirectory: true)
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let executable = outside.appendingPathComponent("ghostty")
            #expect(
                FileManager.default.createFile(
                    atPath: executable.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o755]
                )
            )
            try FileManager.default.createSymbolicLink(
                at: contents.appendingPathComponent("MacOS"),
                withDestinationURL: outside
            )
            let metadata: [String: Any] = [
                "CFBundleIdentifier": SupportedTerminal.ghostty.bundleIdentifier,
                "CFBundleExecutable": "ghostty",
            ]
            try PropertyListSerialization.data(
                fromPropertyList: metadata,
                format: .xml,
                options: 0
            ).write(to: contents.appendingPathComponent("Info.plist"))

            #expect(throws: TerminalApplicationValidationError.executableEscapesBundle) {
                _ = try TerminalApplicationDiscovery(searchRoots: [])
                    .validateApplication(at: application)
            }
        }
    }

    @Test("CLI discovery validates executable files and deduplicates resolved targets")
    func discoversCLIExecutables() throws {
        try withTemporaryDirectory { root in
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            let selected = root.appendingPathComponent("selected", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
            let executable = bin.appendingPathComponent("copilot")
            #expect(
                FileManager.default.createFile(
                    atPath: executable.path,
                    contents: Data("#!/bin/sh\n".utf8),
                    attributes: [.posixPermissions: 0o755]
                )
            )
            let selectedLink = selected.appendingPathComponent("copilot")
            try FileManager.default.createSymbolicLink(
                at: selectedLink,
                withDestinationURL: executable
            )
            let wrongName = selected.appendingPathComponent("other")
            #expect(
                FileManager.default.createFile(
                    atPath: wrongName.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o755]
                )
            )

            let report = CLIExecutableDiscovery(candidateURLs: [executable]).discover(
                userSelectedExecutableURLs: [selectedLink, wrongName]
            )

            #expect(report.executables.count == 1)
            #expect(report.executables.first?.candidateURL == selectedLink)
            #expect(report.executables.first?.source == .userSelected)
            #expect(report.issues.map(\.error) == [.invalidExecutableName])
        }
    }

    @Test("CLI preference requires the same validated path after changes")
    func cliPreferenceDoesNotFallback() throws {
        try withTemporaryDirectory { root in
            let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
            let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
            try FileManager.default.createDirectory(
                at: firstDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: secondDirectory,
                withIntermediateDirectories: true
            )
            let first = firstDirectory.appendingPathComponent("copilot")
            let second = secondDirectory.appendingPathComponent("copilot")
            for url in [first, second] {
                #expect(
                    FileManager.default.createFile(
                        atPath: url.path,
                        contents: Data(),
                        attributes: [.posixPermissions: 0o755]
                    )
                )
            }
            let discovery = CLIExecutableDiscovery(candidateURLs: [])
            let selected = try discovery.validateExecutable(at: first)
            let preference = CLIExecutablePreference(selected)
            guard
                case .available(let available) =
                    TerminalPreferenceResolver.resolve(preference, in: [selected])
            else {
                Issue.record("Expected the exact saved CLI path to resolve.")
                return
            }
            #expect(available == selected)
            try FileManager.default.removeItem(at: first)
            let current = discovery.discover(userSelectedExecutableURLs: [second])

            guard
                case .missing(let missing, let alternatives) =
                    TerminalPreferenceResolver.resolve(
                        preference,
                        in: current.executables
                    )
            else {
                Issue.record("Expected the missing CLI path to require reselection.")
                return
            }
            #expect(missing == preference)
            #expect(alternatives.count == 1)
        }
    }
}

private func createApplication(
    in root: URL,
    name: String,
    bundleIdentifier: String,
    version: String? = nil
) throws -> URL {
    let application = root.appendingPathComponent(name, isDirectory: true)
    let contents = application.appendingPathComponent("Contents", isDirectory: true)
    let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
    let executableName = "terminal"
    let executable = executables.appendingPathComponent(executableName)
    #expect(
        FileManager.default.createFile(
            atPath: executable.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
    )
    var metadata: [String: Any] = [
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleExecutable": executableName,
        "CFBundlePackageType": "APPL",
    ]
    if let version {
        metadata["CFBundleShortVersionString"] = version
    }
    let data = try PropertyListSerialization.data(
        fromPropertyList: metadata,
        format: .xml,
        options: 0
    )
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return application
}

private func withTemporaryDirectory(
    _ body: (URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "copilot-micro-terminal-\(UUID().uuidString)",
        isDirectory: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try body(root)
}
