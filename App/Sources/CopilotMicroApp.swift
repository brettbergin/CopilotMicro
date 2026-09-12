import AppKit
import CopilotMicroCore
import Foundation

private enum StartupError: String, Error {
    case invalidArguments = "invalid_arguments"
    case invalidBundle = "invalid_bundle"
    case missingResource = "missing_resource"
    case invalidConfiguration = "invalid_emulator_configuration"
    case activationPolicyRejected = "activation_policy_rejected"
    case smokeInvariantFailed = "smoke_invariant_failed"
}

private struct SmokeReport: Encodable {
    let schemaVersion = 1
    let outcome = "passed"
    let bundleIdentifier: String
    let bundlePath: String
    let resourcePath: String
    let configuration: EmulatorConfiguration
    let processID: Int32
    let mainThread: Bool
    let activationPolicy: String
    let windowCreated: Bool
    let hostingViewCreated: Bool
    let windowVisible: Bool
    let windowKey: Bool
    let windowMain: Bool
    let statusItemInstalled: Bool
    let menuActionsValidated: Bool
    let keepsRunningAfterManagerClose: Bool
    let fittingWidth: Double
    let fittingHeight: Double
}

@main
struct CopilotMicroApp {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            FileHandle.standardOutput.write(Data(
                "Copilot Micro: emulator-only native foundation.\n"
                    .appending("Run the packaged app normally for its menu bar item.\n")
                    .appending("--smoke-test constructs hidden UI, reads its bundled resource, and exits as JSON.\n").utf8
            ))
            return
        }
        do {
            guard arguments.isEmpty || arguments == ["--smoke-test"] else {
                throw StartupError.invalidArguments
            }
            try run(smoke: arguments == ["--smoke-test"])
        } catch {
            let code = (error as? StartupError)?.rawValue ?? "startup_failed"
            let message = "{\"schemaVersion\":1,\"outcome\":\"failed\",\"errorCode\":\"\(code)\"}\n"
            let output = arguments == ["--smoke-test"]
                ? FileHandle.standardOutput : FileHandle.standardError
            output.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func run(smoke: Bool) throws {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              bundle.bundleIdentifier == BuildIdentity.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == BuildIdentity.version,
              bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String == "26.0" else {
            throw StartupError.invalidBundle
        }
        guard let resource = bundle.url(forResource: "foundation", withExtension: "json"),
              resource.resolvingSymlinksInPath() == bundle.bundleURL
                .appendingPathComponent("Contents/Resources/foundation.json") else {
            throw StartupError.missingResource
        }
        let configuration: EmulatorConfiguration
        do {
            configuration = try JSONDecoder().decode(
                EmulatorConfiguration.self, from: Data(contentsOf: resource)
            )
            try configuration.validate()
        } catch {
            throw StartupError.invalidConfiguration
        }

        let application = NSApplication.shared
        guard application.setActivationPolicy(smoke ? .prohibited : .accessory) else {
            throw StartupError.activationPolicyRejected
        }
        let controller = MenuBarController(configuration: configuration)
        if smoke {
            try smokeTest(controller: controller, configuration: configuration, resource: resource)
            return
        }
        application.delegate = controller
        withExtendedLifetime(controller) {
            application.run()
        }
    }

    @MainActor
    private static func smokeTest(
        controller: MenuBarController,
        configuration: EmulatorConfiguration,
        resource: URL
    ) throws {
        let application = NSApplication.shared
        let manager = controller.manager
        manager.hostingView.layoutSubtreeIfNeeded()
        let size = manager.hostingView.fittingSize
        let menuValid = controller.hasExpectedMenuActions()
        let staysRunning = !controller.applicationShouldTerminateAfterLastWindowClosed(application)
        guard Thread.isMainThread,
              application.activationPolicy() == .prohibited,
              !manager.window.isVisible, !manager.window.isKeyWindow, !manager.window.isMainWindow,
              manager.window.contentView === manager.hostingView,
              controller.statusItem == nil, menuValid, staysRunning,
              size.width.isFinite, size.height.isFinite,
              size.width >= 600, size.height >= 380 else {
            throw StartupError.smokeInvariantFailed
        }
        let report = SmokeReport(
            bundleIdentifier: BuildIdentity.bundleIdentifier,
            bundlePath: Bundle.main.bundleURL.path,
            resourcePath: resource.path,
            configuration: configuration,
            processID: ProcessInfo.processInfo.processIdentifier,
            mainThread: Thread.isMainThread,
            activationPolicy: "prohibited",
            windowCreated: true,
            hostingViewCreated: manager.window.contentView === manager.hostingView,
            windowVisible: manager.window.isVisible,
            windowKey: manager.window.isKeyWindow,
            windowMain: manager.window.isMainWindow,
            statusItemInstalled: controller.statusItem != nil,
            menuActionsValidated: menuValid,
            keepsRunningAfterManagerClose: staysRunning,
            fittingWidth: size.width,
            fittingHeight: size.height
        )
        manager.window.close()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
