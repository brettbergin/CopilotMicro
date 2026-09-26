import CopilotMicroTerminal
import Foundation
import Testing

@testable import CopilotMicroStorage

@Suite("Explicit terminal selection")
struct TerminalSelectionTests {
    @Test("Launch requires exact saved paths, never an available alternative")
    func resolvesOnlySelectedInstallations() async throws {
        try await withSelectionDirectory { root in
            let selectedApp = try makeTerminal(
                in: root, bundleID: SupportedTerminal.ghostty.bundleIdentifier
            )
            let secondRoot = root.appendingPathComponent("other", isDirectory: true)
            try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
            let otherApp = try makeTerminal(
                in: secondRoot, bundleID: SupportedTerminal.ghostty.bundleIdentifier
            )
            let selectedCLI = try makeCLI(in: root)
            let otherCLI = try makeCLI(in: secondRoot)
            let store = LocalConfigurationStore(
                rootURL: root.appendingPathComponent("settings", isDirectory: true)
            )
            await #expect(throws: TerminalSelectionError.terminalNotSelected) {
                _ = try await store.resolveSelectedGhosttyLaunch()
            }
            _ = try await store.selectTerminal(at: selectedApp)
            await #expect(throws: TerminalSelectionError.cliNotSelected) {
                _ = try await store.resolveSelectedGhosttyLaunch()
            }
            _ = try await store.selectCLI(at: selectedCLI)
            let (terminal, cli) = try await store.resolveSelectedGhosttyLaunch()
            #expect(terminal.applicationURL == selectedApp)
            #expect(cli.candidateURL == selectedCLI)

            try FileManager.default.removeItem(at: selectedApp)
            await #expect(throws: TerminalSelectionError.terminalChanged) {
                _ = try await store.resolveSelectedGhosttyLaunch()
            }
            _ = try await store.selectTerminal(at: otherApp)
            try FileManager.default.removeItem(at: selectedCLI)
            await #expect(throws: TerminalSelectionError.cliChanged) {
                _ = try await store.resolveSelectedGhosttyLaunch()
            }
            _ = try await store.selectCLI(at: otherCLI)
            #expect(try await store.resolveSelectedGhosttyLaunch().1.candidateURL == otherCLI)

            let terminalApp = try makeTerminal(
                in: root,
                bundleID: SupportedTerminal.terminal.bundleIdentifier,
                name: "Terminal.app"
            )
            _ = try await store.selectTerminal(at: terminalApp)
            await #expect(throws: TerminalSelectionError.terminalNotQualified) {
                _ = try await store.resolveSelectedGhosttyLaunch()
            }
        }
    }

    @Test("Selected terminal and CLI persist without changing other settings")
    func savesSelections() async throws {
        try await withSelectionDirectory { root in
            let app = try makeTerminal(in: root, bundleID: SupportedTerminal.ghostty.bundleIdentifier)
            let cli = try makeCLI(in: root)
            let store = LocalConfigurationStore(
                rootURL: root.appendingPathComponent("settings", isDirectory: true)
            )
            var original = try await store.load()
            original.lighting.brightness = 0.42
            try await store.save(original)

            let selectedTerminal = try await store.selectTerminal(at: app)
            #expect(selectedTerminal.terminal.preferredBundleIdentifier == SupportedTerminal.ghostty.bundleIdentifier)
            #expect(selectedTerminal.terminal.preferredApplicationPath == app.path)
            #expect(selectedTerminal.terminal.cliExecutableHint == nil)

            let selectedCLI = try await store.selectCLI(at: cli)
            #expect(selectedCLI.terminal.cliExecutableHint == cli.path)
            #expect(selectedCLI.terminal.preferredApplicationPath == app.path)
            #expect(selectedCLI.lighting.brightness == 0.42)
            let reopened = LocalConfigurationStore(rootURL: await store.rootURL)
            #expect(try await reopened.load() == selectedCLI)
            let exported = try ConfigurationCodec.encodePortable(selectedCLI)
            #expect(!String(decoding: exported, as: UTF8.self).contains(app.path))
            #expect(!String(decoding: exported, as: UTF8.self).contains(cli.path))
        }
    }

    @Test("Invalid manual choices do not replace saved selections")
    func rejectsInvalidSelections() async throws {
        try await withSelectionDirectory { root in
            let app = try makeTerminal(in: root, bundleID: SupportedTerminal.ghostty.bundleIdentifier)
            let cli = try makeCLI(in: root)
            let store = LocalConfigurationStore(
                rootURL: root.appendingPathComponent("settings", isDirectory: true)
            )
            _ = try await store.selectTerminal(at: app)
            let selected = try await store.selectCLI(at: cli)
            let other = try makeTerminal(in: root, bundleID: "com.example.other", name: "Other.app")
            await #expect(throws: TerminalApplicationValidationError.unsupportedBundleIdentifier) {
                _ = try await store.selectTerminal(at: other)
            }
            await #expect(throws: CLIExecutableValidationError.executableMissing) {
                _ = try await store.selectCLI(at: root.appendingPathComponent("missing/copilot"))
            }
            #expect(try await store.load() == selected)
        }
    }
}

private func makeTerminal(in root: URL, bundleID: String, name: String = "Ghostty.app") throws -> URL {
    let app = root.appendingPathComponent(name, isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
    let executable = executables.appendingPathComponent("terminal")
    #expect(
        FileManager.default.createFile(
            atPath: executable.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
    let info: [String: Any] = [
        "CFBundleIdentifier": bundleID, "CFBundleExecutable": "terminal", "CFBundlePackageType": "APPL",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    return app
}

private func makeCLI(in root: URL) throws -> URL {
    let cli = root.appendingPathComponent("copilot")
    #expect(FileManager.default.createFile(atPath: cli.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
    return cli
}

private func withSelectionDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "copilot-micro-selection-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}
