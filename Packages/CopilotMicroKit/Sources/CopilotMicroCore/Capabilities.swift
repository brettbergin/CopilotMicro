public enum CapabilityStatus: String, Codable, CaseIterable, Sendable {
    case supported
    case unavailable
    case blocked
    case unknown
}

public struct Capability: Codable, Equatable, Sendable {
    public let status: CapabilityStatus
    public let reason: String?
    public let gapReference: String?
    public let recoveryAction: String?

    public init(
        status: CapabilityStatus,
        reason: String? = nil,
        gapReference: String? = nil,
        recoveryAction: String? = nil
    ) {
        self.status = status
        self.reason = reason
        self.gapReference = gapReference
        self.recoveryAction = recoveryAction
    }

    public static let supported = Capability(status: .supported)
}

public enum ConnectionState: String, Codable, CaseIterable, Sendable {
    case disconnected
    case connecting
    case synchronizing
    case ready
    case reconnecting
    case paused
    case shuttingDown
}
