import AppKit
import Foundation

public enum DeviceConfiguratorGuardError: Error, Equatable, LocalizedError, Sendable {
    case knownConfiguratorRunning(String)

    public var errorDescription: String? {
        switch self {
        case .knownConfiguratorRunning(let name):
            "Quit \(name) before accessing device configuration or lighting."
        }
    }
}

public enum DeviceConfiguratorGuard {
    @MainActor
    public static func requireNoKnownConfiguratorRunning() throws {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != currentProcessID && !$0.isTerminated
        }
        if let application = running.first(where: {
            let name = $0.localizedName?.lowercased() ?? ""
            let bundleIdentifier = $0.bundleIdentifier?.lowercased() ?? ""
            return name == "input"
                || name == "work louder input"
                || bundleIdentifier.contains("worklouder")
        }) {
            throw DeviceConfiguratorGuardError.knownConfiguratorRunning(
                application.localizedName ?? "Work Louder Input"
            )
        }
    }
}
