import CopilotMicroCore
import Foundation
import Testing

@testable import CopilotMicroTerminal

@Suite("Terminal adapter contract")
struct TerminalContractsTests {
    @Test("Exact targets require a process and opaque window identity")
    func validatesTargetIdentity() throws {
        let preference = try TerminalPreference(
            bundleIdentifier: SupportedTerminal.ghostty.bundleIdentifier,
            applicationPath: "/Applications/Ghostty.app"
        )
        #expect(throws: TerminalContractError.invalidProcessIdentifier) {
            _ = try TerminalSurfaceTarget(
                terminal: preference,
                instanceID: try CLIInstanceID(rawValue: "instance-1"),
                processIdentifier: 0,
                windowIdentifier: "window-1"
            )
        }
        #expect(throws: TerminalContractError.invalidIdentifier) {
            _ = try TerminalSurfaceTarget(
                terminal: preference,
                instanceID: try CLIInstanceID(rawValue: "instance-1"),
                processIdentifier: 42,
                windowIdentifier: ""
            )
        }
        let target = try TerminalSurfaceTarget(
            terminal: preference,
            instanceID: CLIInstanceID(rawValue: "instance-1"),
            processIdentifier: 42,
            windowIdentifier: "window-1",
            tabIdentifier: "tab-2",
            paneIdentifier: "pane-3"
        )
        #expect(target.instanceID.rawValue == "instance-1")
        #expect(target.processIdentifier == 42)
        #expect(target.paneIdentifier == "pane-3")
    }

    @Test("Context evidence distinguishes exact targeting from application focus")
    func preservesTargetMatchAndContext() throws {
        let preference = try TerminalPreference(
            bundleIdentifier: SupportedTerminal.iTerm2.bundleIdentifier,
            applicationPath: "/Applications/iTerm.app"
        )
        let target = try TerminalSurfaceTarget(
            terminal: preference,
            instanceID: CLIInstanceID(rawValue: "instance-2"),
            processIdentifier: 100,
            windowIdentifier: "window",
            tabIdentifier: "tab",
            paneIdentifier: "session"
        )
        let evidence = TerminalContextEvidence(
            target: target,
            match: .applicationOnly,
            context: .unknown,
            observedAtUptimeMilliseconds: 1234
        )
        #expect(evidence.match != .exact)
        #expect(evidence.context == .unknown)
    }

    @Test("Launch plans preserve argument boundaries without shell encoding")
    func preservesArgumentVector() throws {
        let associationToken = try SurfaceAssociationToken(
            rawValue: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )
        let plan = try TerminalLaunchPlan(
            launchExecutableURL: URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            arguments: [
                "--working-directory",
                "/Users/example/Project With Spaces",
                "/opt/homebrew/bin/copilot",
                "text; still one argument",
            ],
            workingDirectoryURL: URL(fileURLWithPath: "/Users/example/Project With Spaces"),
            surfaceDisposition: .newWindow,
            surfaceAssociationToken: associationToken
        )
        #expect(plan.arguments.count == 4)
        #expect(plan.arguments.last == "text; still one argument")
        #expect(plan.surfaceDisposition == .newWindow)
        #expect(plan.surfaceAssociationToken == associationToken)

        #expect(throws: TerminalContractError.invalidArguments) {
            _ = try TerminalLaunchPlan(
                launchExecutableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["bad\0argument"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                surfaceDisposition: .newTab
            )
        }
    }

    @Test("Open Copilot request binds one validated terminal, CLI, and project")
    func bindsOpenRequest() throws {
        let terminal = TerminalApplicationDescriptor(
            terminal: .terminal,
            bundleIdentifier: SupportedTerminal.terminal.bundleIdentifier,
            applicationURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            executableURL: URL(
                fileURLWithPath:
                    "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
            ),
            version: "2.14",
            source: .commonLocation
        )
        let cli = CLIExecutableDescriptor(
            candidateURL: URL(fileURLWithPath: "/opt/homebrew/bin/copilot"),
            resolvedExecutableURL: URL(fileURLWithPath: "/opt/homebrew/bin/copilot"),
            source: .commonLocation
        )
        let request = try OpenCopilotRequest(
            terminal: terminal,
            cliExecutable: cli,
            projectDirectoryURL: URL(fileURLWithPath: "/Users/example/project")
        )
        #expect(request.terminal.terminal == .terminal)
        #expect(request.cliExecutable.candidateURL.path == "/opt/homebrew/bin/copilot")
    }
}
