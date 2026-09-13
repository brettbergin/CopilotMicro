import CopilotMicroCore
import Foundation
import Testing

@testable import CopilotMicroTerminal

@Suite("Ghostty adapter")
struct GhosttyAdapterTests {
    @Test("Snapshot parser preserves exact window, tab, and terminal IDs")
    func parsesSnapshot() throws {
        let snapshot = try GhosttyAdapter.parseSnapshot(
            """
            snapshot\ttrue\twindow-1
            surface\twindow-1\ttab-1\tterminal-1\ttrue\ttrue
            surface\twindow-1\ttab-1\tterminal-2\ttrue\tfalse
            """
        )
        #expect(snapshot.applicationFrontmost)
        #expect(snapshot.frontWindowIdentifier == "window-1")
        #expect(snapshot.surfaces.count == 2)
        #expect(snapshot.surfaces.first?.terminalFocused == true)
    }

    @Test("Snapshot parser rejects malformed and oversized responses")
    func rejectsInvalidSnapshots() {
        #expect(throws: GhosttyAdapterError.malformedResponse) {
            _ = try GhosttyAdapter.parseSnapshot("not-a-snapshot")
        }
        let rows = (0...256).map {
            "surface\twindow-\($0)\ttab-\($0)\tterminal-\($0)\tfalse\tfalse"
        }
        #expect(throws: GhosttyAdapterError.malformedResponse) {
            _ = try GhosttyAdapter.parseSnapshot(
                (["snapshot\tfalse\t"] + rows).joined(separator: "\n")
            )
        }
    }

    @Test("Bound Ghostty surfaces are revalidated before becoming targets")
    func discoversOnlyBoundExistingSurface() async throws {
        let runner = FakeGhosttyScriptRunner(
            outputs: [
                """
                snapshot\ttrue\twindow-1
                surface\twindow-1\ttab-1\tterminal-1\ttrue\ttrue
                """
            ]
        )
        let bindings = GhosttyTargetBindingStore()
        let instanceID = try CLIInstanceID(rawValue: "cli-host-42")
        let reference = try GhosttySurfaceReference(
            windowIdentifier: "window-1",
            tabIdentifier: "tab-1",
            terminalIdentifier: "terminal-1"
        )
        await bindings.bind(
            instanceID,
            to: try GhosttyTargetBinding(processIdentifier: 42, surface: reference)
        )
        let adapter = try GhosttyAdapter(
            installation: ghosttyInstallation(),
            runner: runner,
            processLocator: StaticGhosttyProcessLocator([runningGhostty(42)]),
            bindings: bindings
        )

        let targets = try await adapter.discoverTargets(for: instanceID)

        #expect(targets.count == 1)
        #expect(targets.first?.instanceID == instanceID)
        #expect(targets.first?.processIdentifier == 42)
        #expect(targets.first?.paneIdentifier == "terminal-1")
    }

    @Test("Unbound CLI instances never inherit another Ghostty surface")
    func rejectsUnboundInstance() async throws {
        let runner = FakeGhosttyScriptRunner(outputs: [])
        let adapter = try GhosttyAdapter(
            installation: ghosttyInstallation(),
            runner: runner,
            processLocator: StaticGhosttyProcessLocator([runningGhostty(42)]),
            bindings: GhosttyTargetBindingStore(),
            associationTokenGenerator: fixedAssociationToken
        )

        let targets = try await adapter.discoverTargets(
            for: CLIInstanceID(rawValue: "cli-host-42")
        )

        #expect(targets.isEmpty)
        #expect(await runner.invocationCount == 0)
    }

    @Test("Stale binding fails when the exact terminal disappears")
    func rejectsStaleBinding() async throws {
        let runner = FakeGhosttyScriptRunner(
            outputs: [
                """
                snapshot\ttrue\twindow-other
                surface\twindow-other\ttab-other\tterminal-other\ttrue\ttrue
                """
            ]
        )
        let bindings = GhosttyTargetBindingStore()
        let instanceID = try CLIInstanceID(rawValue: "cli-host-42")
        await bindings.bind(
            instanceID,
            to: try GhosttyTargetBinding(
                processIdentifier: 42,
                surface: GhosttySurfaceReference(
                    windowIdentifier: "window-1",
                    tabIdentifier: "tab-1",
                    terminalIdentifier: "terminal-1"
                )
            )
        )
        let adapter = try GhosttyAdapter(
            installation: ghosttyInstallation(),
            runner: runner,
            processLocator: StaticGhosttyProcessLocator([runningGhostty(42)]),
            bindings: bindings
        )

        await #expect(throws: GhosttyAdapterError.surfaceMissing) {
            _ = try await adapter.discoverTargets(for: instanceID)
        }
    }

    @Test("Restarted Ghostty process never matches a stale target")
    func rejectsRestartedProcess() async throws {
        let adapter = try GhosttyAdapter(
            installation: ghosttyInstallation(),
            runner: FakeGhosttyScriptRunner(outputs: []),
            processLocator: StaticGhosttyProcessLocator([runningGhostty(99)]),
            bindings: GhosttyTargetBindingStore()
        )

        let evidence = try await adapter.observeContext(for: target())

        #expect(evidence.match == .unknown)
    }

    @Test("Focus uses exact IDs and requires post-focus revalidation")
    func focusesAndRevalidates() async throws {
        let runner = FakeGhosttyScriptRunner(
            outputs: [
                """
                snapshot\ttrue\twindow-2
                surface\twindow-1\ttab-1\tterminal-1\ttrue\ttrue
                """,
                "focused",
                """
                snapshot\ttrue\twindow-1
                surface\twindow-1\ttab-1\tterminal-1\ttrue\ttrue
                """,
            ]
        )
        let adapter = try GhosttyAdapter(
            installation: ghosttyInstallation(),
            runner: runner,
            processLocator: StaticGhosttyProcessLocator([runningGhostty(42)]),
            bindings: GhosttyTargetBindingStore(),
            associationTokenGenerator: fixedAssociationToken
        )
        let target = try target()

        #expect(try await adapter.focus(target) == .focused)
        let invocations = await runner.invocations
        #expect(invocations.count == 3)
        #expect(
            invocations[1].arguments == [
                "/Applications/Ghostty.app",
                "window-1",
                "tab-1",
                "terminal-1",
            ])
    }

    @Test("Permission denial fails explicitly")
    func reportsAutomationDenial() async throws {
        let runner = FakeGhosttyScriptRunner(
            errors: [.scriptFailed(1, "Not authorized to send Apple events. (-1743)")]
        )
        let adapter = try GhosttyAdapter(
            installation: ghosttyInstallation(),
            runner: runner,
            processLocator: StaticGhosttyProcessLocator([runningGhostty(42)]),
            bindings: GhosttyTargetBindingStore()
        )

        await #expect(throws: GhosttyAdapterError.automationDenied) {
            _ = try await adapter.snapshot()
        }
    }

    @Test("Snapshot never launches Ghostty as a read-only side effect")
    func snapshotRequiresRunningApplication() async throws {
        let runner = FakeGhosttyScriptRunner(outputs: [])
        let adapter = try GhosttyAdapter(
            installation: ghosttyInstallation(),
            runner: runner,
            processLocator: StaticGhosttyProcessLocator([]),
            bindings: GhosttyTargetBindingStore()
        )

        await #expect(throws: GhosttyAdapterError.notRunning) {
            _ = try await adapter.snapshot()
        }
        #expect(await runner.invocationCount == 0)
    }

    @Test("Open Copilot rejects command metacharacters before scripting")
    func rejectsUnsafeOpenCommand() async throws {
        let installation = ghosttyInstallation()
        let runner = FakeGhosttyScriptRunner(outputs: [])
        let adapter = try GhosttyAdapter(
            installation: installation,
            runner: runner,
            bindings: GhosttyTargetBindingStore(),
            associationTokenGenerator: fixedAssociationToken
        )
        let unsafeCLI = CLIExecutableDescriptor(
            candidateURL: URL(fileURLWithPath: "/tmp/copilot;unsafe"),
            resolvedExecutableURL: URL(fileURLWithPath: "/tmp/copilot;unsafe"),
            source: .userSelected
        )
        let unsafeRequest = try OpenCopilotRequest(
            terminal: installation,
            cliExecutable: unsafeCLI,
            projectDirectoryURL: URL(fileURLWithPath: "/tmp")
        )
        await #expect(throws: GhosttyAdapterError.unsafeCLIExecutablePath) {
            _ = try await adapter.openCopilot(unsafeRequest)
        }
        #expect(await runner.invocationCount == 0)
    }

    @Test("Open Copilot returns the created surface bound to the Ghostty process")
    func opensNewWindow() async throws {
        let runner = FakeGhosttyScriptRunner(
            outputs: [
                "created\twindow-1\ttab-1\tterminal-1",
                """
                snapshot\ttrue\twindow-1
                surface\twindow-1\ttab-1\tterminal-1\ttrue\ttrue
                """,
            ]
        )
        let locator = SequencedGhosttyProcessLocator([
            [],
            [runningGhostty(42)],
        ])
        let adapter = try GhosttyAdapter(
            installation: ghosttyInstallation(),
            runner: runner,
            processLocator: locator,
            bindings: GhosttyTargetBindingStore(),
            associationTokenGenerator: fixedAssociationToken
        )

        let openedSurface = try await adapter.openCopilot(openRequest())

        #expect(openedSurface.associationToken.rawValue == fixedAssociationTokenValue)
        #expect(openedSurface.binding.processIdentifier == 42)
        #expect(openedSurface.binding.surface.terminalIdentifier == "terminal-1")
        #expect(openedSurface.claimedInstanceID == nil)
        let invocation = try #require(await runner.invocations.first)
        #expect(
            invocation.arguments == [
                "/Applications/Ghostty.app",
                "/Users/example/Project With Spaces",
                "/opt/homebrew/bin/copilot",
                fixedAssociationTokenValue,
            ])
        let instanceID = try CLIInstanceID(rawValue: "cli-host-42")
        #expect(
            await adapter.claim(
                openedSurface.associationToken,
                for: instanceID,
                nowMilliseconds: 1
            ) == .bound(openedSurface.binding)
        )
        #expect(try await adapter.discoverTargets(for: instanceID).count == 1)
    }

    @Test("Open Copilot reports a registration that arrived during launch")
    func reportsRegistrationThatWinsLaunchRace() async throws {
        let bindings = GhosttyTargetBindingStore()
        let instanceID = try CLIInstanceID(rawValue: "cli-host-42")
        let associationToken = try fixedAssociationToken()
        let runner = FakeGhosttyScriptRunner(
            outputs: [
                "created\twindow-1\ttab-1\tterminal-1",
                """
                snapshot\ttrue\twindow-1
                surface\twindow-1\ttab-1\tterminal-1\ttrue\ttrue
                """,
            ],
            sideEffects: [
                0: {
                    _ = await bindings.claim(
                        associationToken,
                        for: instanceID,
                        nowMilliseconds: 1
                    )
                }
            ]
        )
        let adapter = try GhosttyAdapter(
            installation: ghosttyInstallation(),
            runner: runner,
            processLocator: StaticGhosttyProcessLocator([runningGhostty(42)]),
            bindings: bindings,
            associationTokenGenerator: { associationToken }
        )

        let openedSurface = try await adapter.openCopilot(openRequest())

        #expect(openedSurface.claimedInstanceID == instanceID)
        #expect(try await adapter.discoverTargets(for: instanceID).count == 1)
    }

    @Test("Multiple Ghostty processes block Open Copilot before scripting")
    func rejectsAmbiguousRunningApplications() async throws {
        let runner = FakeGhosttyScriptRunner(outputs: [])
        let adapter = try GhosttyAdapter(
            installation: ghosttyInstallation(),
            runner: runner,
            processLocator: StaticGhosttyProcessLocator([
                runningGhostty(42),
                runningGhostty(43),
            ]),
            bindings: GhosttyTargetBindingStore()
        )

        await #expect(throws: GhosttyAdapterError.multipleInstances) {
            _ = try await adapter.openCopilot(openRequest())
        }
        #expect(await runner.invocationCount == 0)
    }

    @Test("Failed launch cancels its reserved surface token")
    func failedLaunchCancelsAssociation() async throws {
        let runner = FakeGhosttyScriptRunner(
            errors: [.scriptFailed(1, "launch failed")]
        )
        let bindings = GhosttyTargetBindingStore()
        let adapter = try GhosttyAdapter(
            installation: ghosttyInstallation(),
            runner: runner,
            processLocator: StaticGhosttyProcessLocator([runningGhostty(42)]),
            bindings: bindings,
            associationTokenGenerator: fixedAssociationToken
        )

        await #expect(throws: GhosttyAdapterError.scriptFailed("launch failed")) {
            _ = try await adapter.openCopilot(openRequest())
        }
        #expect(
            await bindings.claim(
                try fixedAssociationToken(),
                for: try CLIInstanceID(rawValue: "cli-host-42"),
                nowMilliseconds: 1
            ) == .unknownToken
        )
    }

    @Test("Production scripts never read text or send terminal input")
    func scriptsAvoidTerminalContentAndInput() {
        let scripts = [
            GhosttyScripts.snapshot,
            GhosttyScripts.focus,
            GhosttyScripts.newWindow,
        ]
        for script in scripts {
            #expect(!script.contains("input text"))
            #expect(!script.contains("send key"))
            #expect(!script.contains("working directory of currentTerminal"))
            #expect(!script.contains("name of currentTerminal"))
        }
        #expect(
            GhosttyScripts.newWindow.contains(
                "COPILOT_MICRO_SURFACE_TOKEN="
            )
        )
    }

    @Test("Qualification exercises two tabs and a split then verifies cleanup")
    func qualifiesFocusAndCleanup() async throws {
        let runner = FakeGhosttyScriptRunner(
            outputs: [
                """
                snapshot\ttrue\twindow-original
                surface\twindow-original\ttab-original\tterminal-original\ttrue\ttrue
                """,
                "created\twindow-q\ttab-1\tterminal-1\ttab-2\tterminal-2\tterminal-3",
                """
                snapshot\ttrue\twindow-q
                surface\twindow-q\ttab-1\tterminal-1\tfalse\tfalse
                surface\twindow-q\ttab-2\tterminal-2\ttrue\tfalse
                surface\twindow-q\ttab-2\tterminal-3\ttrue\ttrue
                """,
                "focused",
                """
                snapshot\ttrue\twindow-q
                surface\twindow-q\ttab-1\tterminal-1\ttrue\ttrue
                surface\twindow-q\ttab-2\tterminal-2\tfalse\tfalse
                surface\twindow-q\ttab-2\tterminal-3\tfalse\tfalse
                """,
                """
                snapshot\ttrue\twindow-q
                surface\twindow-q\ttab-1\tterminal-1\ttrue\ttrue
                surface\twindow-q\ttab-2\tterminal-2\tfalse\tfalse
                surface\twindow-q\ttab-2\tterminal-3\tfalse\tfalse
                """,
                "focused",
                """
                snapshot\ttrue\twindow-q
                surface\twindow-q\ttab-1\tterminal-1\tfalse\tfalse
                surface\twindow-q\ttab-2\tterminal-2\ttrue\tfalse
                surface\twindow-q\ttab-2\tterminal-3\ttrue\ttrue
                """,
                "closed",
                """
                snapshot\ttrue\twindow-original
                surface\twindow-original\ttab-original\tterminal-original\ttrue\ttrue
                """,
            ]
        )
        let adapter = try GhosttyAdapter(
            installation: ghosttyInstallation(),
            runner: runner,
            processLocator: StaticGhosttyProcessLocator([runningGhostty(42)]),
            bindings: GhosttyTargetBindingStore(),
            associationTokenGenerator: fixedAssociationToken
        )

        let result = try await adapter.qualifySurfaceRoundTrip(
            workingDirectoryURL: URL(fileURLWithPath: "/tmp")
        )

        #expect(result.firstFocusOutcome == .focused)
        #expect(result.splitFocusOutcome == .focused)
        #expect(!result.foregroundDisplacementVerified)
        #expect(result.cleanupVerified)
        let invocations = await runner.invocations
        #expect(
            invocations[1].arguments == [
                "/Applications/Ghostty.app",
                "/tmp",
                "/usr/bin/true",
                fixedAssociationTokenValue,
            ])
        #expect(
            invocations[8].arguments == [
                "/Applications/Ghostty.app",
                "window-q",
            ])
    }

    @Test("Association qualification verifies child environment and cleanup")
    func qualifiesAssociationEnvironment() async throws {
        let resultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CopilotMicroGhosttyAssociationTests.\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: resultDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: resultDirectory) }
        let resultURL = resultDirectory.appendingPathComponent("result.json")
        let resultData = try JSONEncoder().encode(
            GhosttyAssociationProbeResult(
                surfaceAssociationToken: fixedAssociationToken()
            )
        )
        let runner = FakeGhosttyScriptRunner(
            outputs: [
                """
                snapshot\ttrue\twindow-original
                surface\twindow-original\ttab-original\tterminal-original\ttrue\ttrue
                """,
                "created\twindow-q\ttab-q\tterminal-q",
                "closed",
                """
                snapshot\ttrue\twindow-original
                surface\twindow-original\ttab-original\tterminal-original\ttrue\ttrue
                """,
            ],
            sideEffects: [
                1: {
                    guard
                        FileManager.default.createFile(
                            atPath: resultURL.path,
                            contents: resultData,
                            attributes: [.posixPermissions: 0o600]
                        )
                    else {
                        throw OSAScriptRunnerError.scriptFailed(
                            1,
                            "Could not create fake association result."
                        )
                    }
                }
            ]
        )
        let adapter = try GhosttyAdapter(
            installation: ghosttyInstallation(),
            runner: runner,
            processLocator: StaticGhosttyProcessLocator([runningGhostty(42)]),
            bindings: GhosttyTargetBindingStore(),
            associationTokenGenerator: fixedAssociationToken
        )

        #expect(
            try await adapter.qualifyAssociationEnvironment(
                probeExecutableURL: URL(fileURLWithPath: "/tmp/association-probe"),
                resultURL: resultURL
            )
        )
        #expect(!FileManager.default.fileExists(atPath: resultURL.path))
    }

    private func ghosttyInstallation() -> TerminalApplicationDescriptor {
        TerminalApplicationDescriptor(
            terminal: .ghostty,
            bundleIdentifier: SupportedTerminal.ghostty.bundleIdentifier,
            applicationURL: URL(fileURLWithPath: "/Applications/Ghostty.app"),
            executableURL: URL(
                fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"
            ),
            version: "1.3.1",
            source: .commonLocation
        )
    }

    private func target() throws -> TerminalSurfaceTarget {
        try TerminalSurfaceTarget(
            terminal: TerminalPreference(ghosttyInstallation()),
            instanceID: CLIInstanceID(rawValue: "cli-host-42"),
            processIdentifier: 42,
            windowIdentifier: "window-1",
            tabIdentifier: "tab-1",
            paneIdentifier: "terminal-1"
        )
    }

    private func openRequest() throws -> OpenCopilotRequest {
        let cli = CLIExecutableDescriptor(
            candidateURL: URL(fileURLWithPath: "/opt/homebrew/bin/copilot"),
            resolvedExecutableURL: URL(fileURLWithPath: "/opt/homebrew/bin/copilot"),
            source: .commonLocation
        )
        return try OpenCopilotRequest(
            terminal: ghosttyInstallation(),
            cliExecutable: cli,
            projectDirectoryURL: URL(fileURLWithPath: "/Users/example/Project With Spaces")
        )
    }

    private func runningGhostty(_ processIdentifier: Int32) -> GhosttyRunningApplication {
        GhosttyRunningApplication(
            processIdentifier: processIdentifier,
            applicationURL: URL(fileURLWithPath: "/Applications/Ghostty.app")
        )
    }

    private var fixedAssociationTokenValue: String {
        "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    }

    private func fixedAssociationToken() throws -> SurfaceAssociationToken {
        try SurfaceAssociationToken(rawValue: fixedAssociationTokenValue)
    }
}

@Suite("Ghostty surface association")
struct GhosttyAssociationTests {
    @Test("Registration can arrive before the Ghostty surface is attached")
    func registrationCanWinTheRace() async throws {
        let store = GhosttyTargetBindingStore()
        let token = try surfaceToken()
        let instanceID = try CLIInstanceID(rawValue: "cli-host-42")
        let binding = try targetBinding()
        try await store.reserve(
            token,
            expiresAtMilliseconds: 1_100,
            nowMilliseconds: 1_000
        )

        #expect(
            await store.claim(token, for: instanceID, nowMilliseconds: 1_001)
                == .pending
        )
        #expect(
            try await store.attach(binding, to: token, nowMilliseconds: 1_002)
                == instanceID
        )
        #expect(await store.binding(for: instanceID) == binding)
    }

    @Test("Claimed tokens reconnect only the same CLI instance")
    func tokenCannotMoveBetweenInstances() async throws {
        let store = GhosttyTargetBindingStore()
        let token = try surfaceToken()
        let firstInstance = try CLIInstanceID(rawValue: "cli-host-42")
        let secondInstance = try CLIInstanceID(rawValue: "cli-host-43")
        let binding = try targetBinding()
        try await store.reserve(
            token,
            expiresAtMilliseconds: 1_100,
            nowMilliseconds: 1_000
        )
        try await store.attach(binding, to: token, nowMilliseconds: 1_001)

        #expect(
            await store.claim(token, for: firstInstance, nowMilliseconds: 1_002)
                == .bound(binding)
        )
        #expect(
            await store.claim(token, for: firstInstance, nowMilliseconds: 1_003)
                == .reconnected(binding)
        )
        #expect(
            await store.claim(token, for: secondInstance, nowMilliseconds: 1_004)
                == .tokenClaimedByAnotherInstance
        )
        #expect(await store.binding(for: secondInstance) == nil)
    }

    @Test("Unclaimed reservations expire without creating a target")
    func reservationsExpire() async throws {
        let store = GhosttyTargetBindingStore()
        let token = try surfaceToken()
        let instanceID = try CLIInstanceID(rawValue: "cli-host-42")
        try await store.reserve(
            token,
            expiresAtMilliseconds: 1_100,
            nowMilliseconds: 1_000
        )

        #expect(
            await store.claim(token, for: instanceID, nowMilliseconds: 1_100)
                == .unknownToken
        )
        #expect(await store.binding(for: instanceID) == nil)
    }

    @Test("Pending claims expire when no surface is attached")
    func pendingClaimsExpire() async throws {
        let store = GhosttyTargetBindingStore()
        let token = try surfaceToken()
        let instanceID = try CLIInstanceID(rawValue: "cli-host-42")
        try await store.reserve(
            token,
            expiresAtMilliseconds: 1_100,
            nowMilliseconds: 1_000
        )
        #expect(
            await store.claim(token, for: instanceID, nowMilliseconds: 1_001)
                == .pending
        )

        await #expect(throws: GhosttyAssociationError.unknownToken) {
            try await store.attach(
                targetBinding(),
                to: token,
                nowMilliseconds: 1_100
            )
        }
        #expect(await store.binding(for: instanceID) == nil)
    }

    private func surfaceToken() throws -> SurfaceAssociationToken {
        try SurfaceAssociationToken(
            rawValue: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )
    }

    private func targetBinding() throws -> GhosttyTargetBinding {
        try GhosttyTargetBinding(
            processIdentifier: 42,
            surface: GhosttySurfaceReference(
                windowIdentifier: "window-1",
                tabIdentifier: "tab-1",
                terminalIdentifier: "terminal-1"
            )
        )
    }
}

@Suite("AppleScript runner")
struct OSAScriptRunnerTests {
    @Test("Runner bounds execution time")
    func boundsExecutionTime() async throws {
        let helper = try makeHelperScript("sleep 5")
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        let runner = OSAScriptRunner(executableURL: helper, timeoutSeconds: 0.05)

        await #expect(throws: OSAScriptRunnerError.timedOut) {
            _ = try await runner.run(script: "ignored", arguments: [])
        }
    }

    @Test("Runner rejects oversized output")
    func rejectsOversizedOutput() async throws {
        let helper = try makeHelperScript(
            "i=0; while [ \"$i\" -lt 70000 ]; do printf x; i=$((i + 1)); done"
        )
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        let runner = OSAScriptRunner(executableURL: helper, timeoutSeconds: 5)

        await #expect(throws: OSAScriptRunnerError.outputTooLarge) {
            _ = try await runner.run(script: "ignored", arguments: [])
        }
    }

    @Test("Runner preserves bounded nonzero failures")
    func reportsNonzeroExit() async throws {
        let helper = try makeHelperScript("printf 'bounded failure' >&2; exit 7")
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        let runner = OSAScriptRunner(executableURL: helper, timeoutSeconds: 1)

        await #expect(
            throws: OSAScriptRunnerError.scriptFailed(7, "bounded failure")
        ) {
            _ = try await runner.run(script: "ignored", arguments: [])
        }
    }

    @Test("Runner rejects oversized arguments before launching")
    func rejectsOversizedArgument() async throws {
        let runner = OSAScriptRunner(executableURL: URL(fileURLWithPath: "/usr/bin/false"))

        await #expect(throws: OSAScriptRunnerError.invalidArguments) {
            _ = try await runner.run(
                script: "ignored",
                arguments: [String(repeating: "x", count: 4_097)]
            )
        }
    }

    private func makeHelperScript(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CopilotMicroGhosttyTests.\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let script = directory.appendingPathComponent("helper.sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )
        return script
    }
}

private actor FakeGhosttyScriptRunner: GhosttyScriptRunning {
    struct Invocation: Sendable {
        let script: String
        let arguments: [String]
    }

    private var outputs: [String]
    private var errors: [OSAScriptRunnerError]
    private var sideEffects: [Int: @Sendable () async throws -> Void]
    private(set) var invocations: [Invocation] = []

    init(
        outputs: [String] = [],
        errors: [OSAScriptRunnerError] = [],
        sideEffects: [Int: @Sendable () async throws -> Void] = [:]
    ) {
        self.outputs = outputs
        self.errors = errors
        self.sideEffects = sideEffects
    }

    var invocationCount: Int {
        invocations.count
    }

    func run(script: String, arguments: [String]) async throws -> String {
        invocations.append(Invocation(script: script, arguments: arguments))
        try await sideEffects.removeValue(forKey: invocations.count - 1)?()
        if !errors.isEmpty {
            throw errors.removeFirst()
        }
        guard !outputs.isEmpty else {
            throw OSAScriptRunnerError.scriptFailed(1, "No fake output.")
        }
        return outputs.removeFirst()
    }
}

private struct StaticGhosttyProcessLocator: GhosttyProcessLocating {
    let applications: [GhosttyRunningApplication]

    init(_ applications: [GhosttyRunningApplication]) {
        self.applications = applications
    }

    func runningApplications() async -> [GhosttyRunningApplication] {
        applications
    }
}

private actor SequencedGhosttyProcessLocator: GhosttyProcessLocating {
    private var results: [[GhosttyRunningApplication]]

    init(_ results: [[GhosttyRunningApplication]]) {
        self.results = results
    }

    func runningApplications() -> [GhosttyRunningApplication] {
        guard results.count > 1 else {
            return results.first ?? []
        }
        return results.removeFirst()
    }
}
