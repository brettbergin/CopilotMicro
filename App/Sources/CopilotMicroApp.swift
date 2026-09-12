import AppKit
import CopilotMicroCore
import CopilotMicroStorage
import Foundation

private protocol StartupFailure: Error {
    var errorCode: String { get }
    var message: String { get }
}

private enum StartupError: String, StartupFailure {
    case invalidArguments = "invalid_arguments"
    case invalidBundle = "invalid_bundle"
    case missingResource = "missing_resource"
    case invalidConfiguration = "invalid_emulator_configuration"
    case activationPolicyRejected = "activation_policy_rejected"

    var errorCode: String { rawValue }

    var message: String {
        switch self {
        case .invalidArguments:
            "Expected no arguments, --help, --smoke-test, or --smoke-test=accessory."
        case .invalidBundle:
            "The executable is not running from the expected Copilot Micro app bundle."
        case .missingResource:
            "The packaged foundation resource is missing or outside the app bundle."
        case .invalidConfiguration:
            "The packaged foundation resource is not a valid emulator-only configuration."
        case .activationPolicyRejected:
            "AppKit did not enter the required activation policy."
        }
    }
}

private struct SmokeInvariantError: StartupFailure {
    let errorCode = "smoke_invariant_failed"
    let failures: [String]

    var message: String {
        "Native startup smoke invariants failed: \(failures.joined(separator: ", "))."
    }
}

private enum SmokeMode: String {
    case hidden
    case accessory
}

private struct FailureReport: Encodable {
    let schemaVersion = 1
    let outcome = "failed"
    let errorCode: String
    let message: String
}

private struct SmokeReport: Encodable {
    let schemaVersion = 1
    let outcome = "passed"
    let smokeMode: String
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
    let applicationDelegateInstalled: Bool
    let applicationDidFinishLaunching: Bool
    let mainMenuInstalled: Bool
    let mainMenuActionsValidated: Bool
    let statusItemInstalled: Bool
    let statusItemMenuInstalled: Bool
    let menuActionsValidated: Bool
    let keepsRunningAfterManagerClose: Bool
    let managerAreasValidated: Bool
    let emulatorJourneyValidated: Bool
    let liveServicesDisabled: Bool
    let storageDisabledForSmoke: Bool
    let portableConfigurationValidated: Bool
    let diagnosticRedactionValidated: Bool
    let fittingWidth: Double
    let fittingHeight: Double
}

@main
struct CopilotMicroApp {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            FileHandle.standardOutput.write(
                Data(
                    "Copilot Micro: emulator-only native foundation.\n"
                        .appending("Run the packaged app normally for its menu bar item.\n")
                        .appending(
                            "--smoke-test constructs hidden UI, reads its bundled resource, and exits as JSON.\n"
                        )
                        .appending(
                            "--smoke-test=accessory verifies production app-delegate and menu-bar startup, then exits.\n"
                        ).utf8
                ))
            return
        }
        let smokeMode: SmokeMode?
        switch arguments {
        case []:
            smokeMode = nil
        case ["--smoke-test"]:
            smokeMode = .hidden
        case ["--smoke-test=accessory"]:
            smokeMode = .accessory
        default:
            smokeMode = nil
        }
        do {
            guard arguments.isEmpty || smokeMode != nil else {
                throw StartupError.invalidArguments
            }
            try run(smokeMode: smokeMode)
        } catch {
            let startupFailure = error as? StartupFailure
            let report = FailureReport(
                errorCode: startupFailure?.errorCode ?? "startup_failed",
                message: startupFailure?.message ?? "Copilot Micro failed during startup."
            )
            let output = smokeMode == nil ? FileHandle.standardError : FileHandle.standardOutput
            if let data = try? JSONEncoder().encode(report) {
                output.write(data)
                output.write(Data("\n".utf8))
            }
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func run(smokeMode: SmokeMode?) throws {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
            bundle.bundleIdentifier == BuildIdentity.bundleIdentifier,
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == BuildIdentity.version,
            bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String == "26.0"
        else {
            throw StartupError.invalidBundle
        }
        let expectedResource = normalizedFileURL(
            bundle.bundleURL.appendingPathComponent("Contents/Resources/foundation.json")
        )
        guard let foundResource = bundle.url(forResource: "foundation", withExtension: "json") else {
            throw StartupError.missingResource
        }
        let resource = normalizedFileURL(foundResource)
        guard resource == expectedResource else {
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

        let storage: LocalConfigurationStore?
        let diagnostics: DiagnosticStore?
        let initialStorageError: String?
        if smokeMode == nil {
            do {
                let root = try LocalConfigurationStore.defaultRootURL()
                storage = LocalConfigurationStore(rootURL: root)
                diagnostics = DiagnosticStore(
                    directoryURL: root.appendingPathComponent("diagnostics", isDirectory: true)
                )
                initialStorageError = nil
            } catch {
                storage = nil
                diagnostics = nil
                initialStorageError = ConfigurationError.fileSystem.userMessage
            }
        } else {
            storage = nil
            diagnostics = nil
            initialStorageError = nil
        }

        let application = NSApplication.shared
        try setActivationPolicy(
            smokeMode == .hidden ? .prohibited : .accessory,
            on: application
        )
        let controller = MenuBarController(
            configuration: configuration,
            localConfigurationStore: storage,
            diagnosticStore: diagnostics,
            initialStorageError: initialStorageError
        )
        if smokeMode == .hidden {
            try smokeTest(
                mode: .hidden,
                controller: controller,
                configuration: configuration,
                resource: resource
            )
            return
        }
        installAccessoryLifecycle(controller: controller, on: application)
        if smokeMode == .accessory {
            try runAccessorySmoke(
                controller: controller,
                configuration: configuration,
                resource: resource,
                application: application
            )
            return
        }
        withExtendedLifetime(controller) {
            application.run()
        }
    }

    @MainActor
    private static func runAccessorySmoke(
        controller: MenuBarController,
        configuration: EmulatorConfiguration,
        resource: URL,
        application: NSApplication
    ) throws {
        var failure: (any Error)?
        DispatchQueue.main.async {
            do {
                try smokeTest(
                    mode: .accessory,
                    controller: controller,
                    configuration: configuration,
                    resource: resource
                )
            } catch {
                failure = error
            }
            application.stop(nil)
        }
        withExtendedLifetime(controller) {
            application.run()
        }
        if let failure {
            throw failure
        }
    }

    private static func normalizedFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    @MainActor
    private static func setActivationPolicy(
        _ policy: NSApplication.ActivationPolicy,
        on application: NSApplication
    ) throws {
        if application.activationPolicy() != policy {
            _ = application.setActivationPolicy(policy)
        }
        guard application.activationPolicy() == policy else {
            throw StartupError.activationPolicyRejected
        }
    }

    @MainActor
    private static func installAccessoryLifecycle(
        controller: MenuBarController,
        on application: NSApplication
    ) {
        application.mainMenu = controller.mainMenu
        application.delegate = controller
    }

    @MainActor
    private static func smokeTest(
        mode: SmokeMode,
        controller: MenuBarController,
        configuration: EmulatorConfiguration,
        resource: URL
    ) throws {
        let application = NSApplication.shared
        let manager = controller.manager
        manager.hostingView.layoutSubtreeIfNeeded()
        let size = manager.hostingView.fittingSize
        let menuValid = controller.hasExpectedMenuActions()
        let mainMenuValid = controller.hasExpectedMainMenuActions()
        let staysRunning = !controller.applicationShouldTerminateAfterLastWindowClosed(application)
        let accessory = mode == .accessory
        let delegateInstalled = application.delegate as AnyObject? === controller
        let mainMenuInstalled = application.mainMenu === controller.mainMenu
        let statusItemInstalled = controller.statusItem != nil
        let statusItemMenuInstalled = controller.statusItem?.menu === controller.menu
        let managerAreasValidated = ManagerArea.allCases.count == 7
        let emulatorJourneyValidated = EmulatorStore.validateDemoJourney(configuration: configuration)
        let liveServicesDisabled = manager.store.liveServicesDisabled
        let storageDisabledForSmoke = manager.store.storageState == .disabledForSmoke
        let portableConfigurationValidated = validatePortableConfiguration()
        let diagnosticRedactionValidated = validateDiagnosticRedaction()
        let invariants: [(String, Bool)] = [
            ("main_thread", Thread.isMainThread),
            (
                "activation_policy",
                application.activationPolicy() == (accessory ? .accessory : .prohibited)
            ),
            ("window_hidden", !manager.window.isVisible),
            ("window_not_key", !manager.window.isKeyWindow),
            ("window_not_main", !manager.window.isMainWindow),
            ("hosting_view_installed", manager.window.contentView === manager.hostingView),
            ("application_delegate", delegateInstalled == accessory),
            ("application_finished_launching", controller.didFinishLaunching == accessory),
            ("main_menu_installed", mainMenuInstalled == accessory),
            ("status_item_installed", statusItemInstalled == accessory),
            ("status_item_menu_installed", statusItemMenuInstalled == accessory),
            ("status_menu_actions", menuValid),
            ("main_menu_actions", mainMenuValid),
            ("manager_close_lifecycle", staysRunning),
            ("manager_areas", managerAreasValidated),
            ("emulator_journey", emulatorJourneyValidated),
            ("live_services_disabled", liveServicesDisabled),
            ("storage_disabled_for_smoke", storageDisabledForSmoke),
            ("portable_configuration", portableConfigurationValidated),
            ("diagnostic_redaction", diagnosticRedactionValidated),
            ("finite_layout", size.width.isFinite && size.height.isFinite),
            ("minimum_layout", size.width >= 600 && size.height >= 380),
        ]
        let failures = invariants.compactMap { name, passed in passed ? nil : name }
        if !failures.isEmpty {
            throw SmokeInvariantError(failures: failures)
        }
        let report = SmokeReport(
            smokeMode: mode.rawValue,
            bundleIdentifier: BuildIdentity.bundleIdentifier,
            bundlePath: normalizedFileURL(Bundle.main.bundleURL).path,
            resourcePath: resource.path,
            configuration: configuration,
            processID: ProcessInfo.processInfo.processIdentifier,
            mainThread: Thread.isMainThread,
            activationPolicy: accessory ? "accessory" : "prohibited",
            windowCreated: true,
            hostingViewCreated: manager.window.contentView === manager.hostingView,
            windowVisible: manager.window.isVisible,
            windowKey: manager.window.isKeyWindow,
            windowMain: manager.window.isMainWindow,
            applicationDelegateInstalled: delegateInstalled,
            applicationDidFinishLaunching: controller.didFinishLaunching,
            mainMenuInstalled: mainMenuInstalled,
            mainMenuActionsValidated: mainMenuValid,
            statusItemInstalled: statusItemInstalled,
            statusItemMenuInstalled: statusItemMenuInstalled,
            menuActionsValidated: menuValid,
            keepsRunningAfterManagerClose: staysRunning,
            managerAreasValidated: managerAreasValidated,
            emulatorJourneyValidated: emulatorJourneyValidated,
            liveServicesDisabled: liveServicesDisabled,
            storageDisabledForSmoke: storageDisabledForSmoke,
            portableConfigurationValidated: portableConfigurationValidated,
            diagnosticRedactionValidated: diagnosticRedactionValidated,
            fittingWidth: size.width,
            fittingHeight: size.height
        )
        manager.window.close()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func validatePortableConfiguration() -> Bool {
        do {
            var configuration = StoredConfiguration()
            configuration.terminal = StoredTerminalPreferences(
                preferredBundleIdentifier: "com.example.Terminal",
                preferredApplicationPath: "/private/example/Terminal.app",
                cliExecutableHint: "/private/example/copilot"
            )
            configuration.recentProjectDirectories = ["/private/example/repository"]
            let data = try ConfigurationCodec.encodePortable(configuration)
            let text = String(decoding: data, as: UTF8.self)
            let plan = try ConfigurationCodec.decodePortable(
                data,
                against: configuration
            )
            return !plan.hasChanges
                && !text.contains("/private/example")
                && !text.contains("preferredApplicationPath")
                && !text.contains("recentProjectDirectories")
        } catch {
            return false
        }
    }

    private static func validateDiagnosticRedaction() -> Bool {
        do {
            let secret = "github_pat_smoke12345678"
            let message =
                try DiagnosticEvent(
                    timestamp: Date(timeIntervalSince1970: 0),
                    component: .application,
                    operation: "smoke",
                    outcome: .failed,
                    errorCategory: .invalidInput,
                    message: "Bearer abc.def \(secret) /Users/example/repo command=/bin/rm",
                    sensitiveValues: [secret]
                ).message ?? ""
            return message.contains("[redacted]")
                && !message.contains(secret)
                && !message.contains("/Users/example")
                && !message.contains("/bin/rm")
        } catch {
            return false
        }
    }
}
