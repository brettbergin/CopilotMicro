import AppKit
import CopilotMicroCore
import Foundation

private protocol StartupFailure: Error {
    var errorCode: String { get }
    var message: String { get }
}

private enum StartupError: String, StartupFailure {
    case invalidArguments = "invalid_arguments"
    case invalidBundle = "invalid_bundle"
    case missingResource = "missing_resource"
    case invalidConfiguration = "invalid_application_configuration"
    case activationPolicyRejected = "activation_policy_rejected"

    var errorCode: String { rawValue }

    var message: String {
        switch self {
        case .invalidArguments:
            "Expected no arguments, --help, --smoke-test, or --smoke-test=accessory."
        case .invalidBundle:
            "The executable is not running from the expected Copilot Micro app bundle."
        case .missingResource:
            "The packaged application resource is missing or outside the app bundle."
        case .invalidConfiguration:
            "The packaged resource does not enable the Creator Micro device assembly."
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
    let configuration: ApplicationConfiguration
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
    let directDeviceUIValidated: Bool
    let deviceServiceSuppressedForSmoke: Bool
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
                    "Copilot Micro: native Creator Micro 2 controller.\n"
                        .appending("Run the packaged app normally to connect to the device.\n")
                        .appending(
                            "--smoke-test validates hidden UI without opening hardware.\n"
                        )
                        .appending(
                            "--smoke-test=accessory validates menu-bar startup without opening hardware.\n"
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
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == BuildIdentity.version,
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
        let configuration: ApplicationConfiguration
        do {
            configuration = try JSONDecoder().decode(
                ApplicationConfiguration.self,
                from: Data(contentsOf: resource)
            )
            try configuration.validate()
        } catch {
            throw StartupError.invalidConfiguration
        }

        let application = NSApplication.shared
        try setActivationPolicy(
            smokeMode == .hidden ? .prohibited : .accessory,
            on: application
        )
        let controller = MenuBarController(
            hardwareEnabled: smokeMode == nil && configuration.deviceIntegrationEnabled
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
        configuration: ApplicationConfiguration,
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
        configuration: ApplicationConfiguration,
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
        let managerAreasValidated = ManagerArea.allCases.count == 4
        let directDeviceUIValidated = PhysicalControlID.allCases.count == 12
        let deviceServiceSuppressed =
            LiveDeviceStore.validateHardwareSuppressionForSmoke()
            && manager.store.connectionState == .suppressedForSmoke
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
            ("direct_device_ui", directDeviceUIValidated),
            ("device_service_suppressed", deviceServiceSuppressed),
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
            directDeviceUIValidated: directDeviceUIValidated,
            deviceServiceSuppressedForSmoke: deviceServiceSuppressed,
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
