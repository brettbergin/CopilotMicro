import Foundation

public enum HardwareCapabilityEvidenceError: Error, LocalizedError, Sendable {
    case outOfBounds

    public var errorDescription: String? {
        "Read-only hardware evidence exceeded the supported contract bounds."
    }
}

public struct HardwareCapabilityEvidence: Encodable, Sendable {
    public let schemaVersion = 1
    public let generatedAt: String
    public let outcome = "read-only-qualified"
    public let product: String
    public let productID: String
    public let transport: DeviceTransport
    public let vendorCollection = "0xFF00/1"
    public let inputReportBytes: Int
    public let outputReportBytes: Int
    public let serialPresent: Bool
    public let firmwareVersion: String
    public let status: DeviceStatusSummary
    public let keymap: DeviceKeymapSummary
    public let unexpectedResponseCount: Int
    public let notificationCount: Int
    public let mutatingOperationsPerformed = false

    public init(
        generatedAt: String = ISO8601DateFormatter().string(from: Date()),
        product: String,
        productID: String,
        transport: DeviceTransport,
        inputReportBytes: Int,
        outputReportBytes: Int,
        serialPresent: Bool,
        firmwareVersion: String,
        status: DeviceStatusSummary,
        keymap: DeviceKeymapSummary,
        unexpectedResponseCount: Int,
        notificationCount: Int
    ) {
        self.generatedAt = generatedAt
        self.product = product
        self.productID = productID
        self.transport = transport
        self.inputReportBytes = inputReportBytes
        self.outputReportBytes = outputReportBytes
        self.serialPresent = serialPresent
        self.firmwareVersion = firmwareVersion
        self.status = status
        self.keymap = keymap
        self.unexpectedResponseCount = unexpectedResponseCount
        self.notificationCount = notificationCount
    }

    public func validate() throws {
        guard
            ISO8601DateFormatter().date(from: generatedAt) != nil,
            !product.isEmpty,
            product.unicodeScalars.count <= 128,
            ["0x8297", "0x8298"].contains(productID),
            transport == .usb || transport == .bluetooth,
            (64...4096).contains(inputReportBytes),
            (64...4096).contains(outputReportBytes),
            !firmwareVersion.isEmpty,
            firmwareVersion.utf8.count <= 64,
            (0...255).contains(status.activeLayerIndex),
            (0...100).contains(status.battery),
            (1...DeviceSnapshotParser.maximumKeymapBytes).contains(keymap.byteCount),
            keymap.schemaVersion >= 1,
            keymap.activeProfileID >= 0,
            keymap.activeProfileMatched,
            (1...64).contains(keymap.profileCount),
            (1...64).contains(keymap.activeProfileLayerCount),
            keymap.activeLayerAvailable,
            keymap.activeLayerKeyRowLengths.count <= 16,
            keymap.activeLayerKeyRowLengths.allSatisfy { (1...64).contains($0) },
            (0...1_000_000).contains(unexpectedResponseCount),
            (0...1_000_000).contains(notificationCount)
        else {
            throw HardwareCapabilityEvidenceError.outOfBounds
        }
    }
}
