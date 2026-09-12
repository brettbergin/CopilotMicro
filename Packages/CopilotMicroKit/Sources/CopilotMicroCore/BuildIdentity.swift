public enum BuildIdentity {
    public static let productName = "Copilot Micro"
    public static let bundleIdentifier = "com.github.copilot-micro"
    public static let version = "0.1.0"
}

public struct EmulatorConfiguration: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case emulator
    }

    public enum ValidationError: Error {
        case unsupportedSchema
        case liveIntegrationsForbidden
    }

    public let schemaVersion: Int
    public let mode: Mode
    public let liveIntegrationsEnabled: Bool

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw ValidationError.unsupportedSchema
        }
        guard !liveIntegrationsEnabled else {
            throw ValidationError.liveIntegrationsForbidden
        }
    }
}
