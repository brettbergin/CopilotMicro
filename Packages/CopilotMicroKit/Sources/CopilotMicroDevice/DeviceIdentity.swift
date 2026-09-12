import Foundation

public enum DeviceTransport: String, Codable, Sendable {
    case bluetooth
    case usb
    case unknown

    init(rawValueFromHID value: String?) {
        switch value?.lowercased() {
        case let transport? where transport.contains("bluetooth"):
            self = .bluetooth
        case let transport? where transport.contains("usb"):
            self = .usb
        default:
            self = .unknown
        }
    }
}

public struct HIDUsagePair: Codable, Equatable, Sendable {
    public let page: Int
    public let usage: Int

    public init(page: Int, usage: Int) {
        self.page = page
        self.usage = usage
    }
}

public enum DeviceQualification: String, Codable, Sendable {
    case supportedCandidate
    case unsupported
}

public struct HIDDeviceDescriptor: Codable, Equatable, Sendable {
    public let registryID: UInt64
    public let vendorID: Int
    public let productID: Int
    public let product: String
    public let transport: DeviceTransport
    public let primaryUsagePage: Int?
    public let primaryUsage: Int?
    public let usagePairs: [HIDUsagePair]
    public let maximumInputReportBytes: Int
    public let maximumOutputReportBytes: Int
    public let serialPresent: Bool
    public let qualification: DeviceQualification
    public let qualificationReason: String

    public init(
        registryID: UInt64,
        vendorID: Int,
        productID: Int,
        product: String,
        transport: DeviceTransport,
        primaryUsagePage: Int?,
        primaryUsage: Int?,
        usagePairs: [HIDUsagePair],
        maximumInputReportBytes: Int,
        maximumOutputReportBytes: Int,
        serialPresent: Bool
    ) {
        self.registryID = registryID
        self.vendorID = vendorID
        self.productID = productID
        self.product = product
        self.transport = transport
        self.primaryUsagePage = primaryUsagePage
        self.primaryUsage = primaryUsage
        self.usagePairs = usagePairs
        self.maximumInputReportBytes = maximumInputReportBytes
        self.maximumOutputReportBytes = maximumOutputReportBytes
        self.serialPresent = serialPresent
        let result = CreatorMicro2Hardware.qualify(
            vendorID: vendorID,
            productID: productID,
            product: product,
            transport: transport,
            primaryUsagePage: primaryUsagePage,
            primaryUsage: primaryUsage,
            usagePairs: usagePairs,
            maximumInputReportBytes: maximumInputReportBytes,
            maximumOutputReportBytes: maximumOutputReportBytes
        )
        self.qualification = result.qualification
        self.qualificationReason = result.reason
    }
}

public enum CreatorMicro2Hardware {
    public static let vendorID = 0x303A
    public static let candidateProductIDs: Set<Int> = [0x8297, 0x8298]
    public static let vendorUsagePage = 0xFF00
    public static let vendorUsage = 1
    public static let reportBytes = 64

    static func qualify(
        vendorID: Int,
        productID: Int,
        product: String,
        transport: DeviceTransport,
        primaryUsagePage: Int?,
        primaryUsage: Int?,
        usagePairs: [HIDUsagePair],
        maximumInputReportBytes: Int,
        maximumOutputReportBytes: Int
    ) -> (qualification: DeviceQualification, reason: String) {
        guard vendorID == self.vendorID else {
            return (.unsupported, "Vendor ID is not Work Louder 0x303A.")
        }
        guard candidateProductIDs.contains(productID) else {
            return (.unsupported, "Product ID is not in the qualified Creator Micro 2 candidate set.")
        }
        guard product.localizedCaseInsensitiveContains("Creator Micro 2") else {
            return (.unsupported, "Product name does not identify Creator Micro 2.")
        }
        guard !product.isEmpty, product.unicodeScalars.count <= 128 else {
            return (.unsupported, "Product name exceeds the supported evidence bounds.")
        }
        guard transport == .usb || transport == .bluetooth else {
            return (.unsupported, "Transport is not qualified as USB or Bluetooth.")
        }
        let hasVendorCollection =
            (primaryUsagePage == vendorUsagePage && primaryUsage == vendorUsage)
            || usagePairs.contains(HIDUsagePair(page: vendorUsagePage, usage: vendorUsage))
        guard hasVendorCollection else {
            return (.unsupported, "The required vendor usage page 0xFF00 usage 1 is absent.")
        }
        guard
            (reportBytes...4096).contains(maximumInputReportBytes),
            (reportBytes...4096).contains(maximumOutputReportBytes)
        else {
            return (.unsupported, "The vendor collection report sizes are outside supported bounds.")
        }
        return (
            .supportedCandidate,
            "Identity and vendor collection match; firmware and configuration still require read-only qualification."
        )
    }
}
