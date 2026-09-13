public enum BuildIdentity {
    public static let productName = "Copilot Micro"
    public static let bundleIdentifier = "com.github.copilot-micro"
    public static let version = "0.1.0"
}

public struct ApplicationConfiguration: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case device
    }

    public enum ValidationError: Error, Equatable {
        case unsupportedSchema
        case deviceIntegrationRequired
    }

    public let schemaVersion: Int
    public let mode: Mode
    public let deviceIntegrationEnabled: Bool

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw ValidationError.unsupportedSchema
        }
        guard deviceIntegrationEnabled else {
            throw ValidationError.deviceIntegrationRequired
        }
    }
}
