import Foundation
import IOKit
import IOKit.hid

public enum HIDDiscoveryError: Error, LocalizedError, Sendable {
    case managerOpenFailed(UInt32)

    public var errorDescription: String? {
        switch self {
        case .managerOpenFailed(let code):
            String(format: "IOHIDManagerOpen failed with 0x%08X.", code)
        }
    }
}

public enum HIDListenAccessStatus: String, Codable, Sendable {
    case denied
    case granted
    case unknown
}

public enum HIDDeviceDiscovery {
    public static var listenAccessStatus: HIDListenAccessStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            .granted
        case kIOHIDAccessTypeDenied:
            .denied
        default:
            .unknown
        }
    }

    @discardableResult
    public static func requestListenAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public static func discover() throws -> [HIDDeviceDescriptor] {
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDVendorIDKey: CreatorMicro2Hardware.vendorID] as CFDictionary
        )
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw HIDDiscoveryError.managerOpenFailed(UInt32(bitPattern: result))
        }
        defer {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        return HIDNativeDiscovery.records(from: manager)
            .map(\.descriptor)
            .sorted { $0.registryID < $1.registryID }
    }
}

struct HIDNativeRecord {
    let descriptor: HIDDeviceDescriptor
    let device: IOHIDDevice
}

enum HIDNativeDiscovery {
    static func makeManager() throws -> IOHIDManager {
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDVendorIDKey: CreatorMicro2Hardware.vendorID] as CFDictionary
        )
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw HIDDiscoveryError.managerOpenFailed(UInt32(bitPattern: result))
        }
        return manager
    }

    static func records(from manager: IOHIDManager) -> [HIDNativeRecord] {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }
        return devices.compactMap { device in
            guard let registryID = registryID(device) else { return nil }
            let vendorID = integer(device, kIOHIDVendorIDKey) ?? 0
            let productID = integer(device, kIOHIDProductIDKey) ?? 0
            let serialNumber = string(device, kIOHIDSerialNumberKey)
            let descriptor = HIDDeviceDescriptor(
                registryID: registryID,
                vendorID: vendorID,
                productID: productID,
                product: string(device, kIOHIDProductKey) ?? "Unknown HID device",
                transport: DeviceTransport(
                    rawValueFromHID: string(device, kIOHIDTransportKey)
                ),
                primaryUsagePage: integer(device, kIOHIDPrimaryUsagePageKey),
                primaryUsage: integer(device, kIOHIDPrimaryUsageKey),
                usagePairs: usagePairs(device),
                maximumInputReportBytes: integer(device, kIOHIDMaxInputReportSizeKey) ?? 0,
                maximumOutputReportBytes: integer(device, kIOHIDMaxOutputReportSizeKey) ?? 0,
                serialPresent: !(serialNumber ?? "").isEmpty,
                associationID: DeviceAssociationIdentifier.make(
                    vendorID: vendorID,
                    productID: productID,
                    serialNumber: serialNumber
                )
            )
            return HIDNativeRecord(descriptor: descriptor, device: device)
        }
    }

    private static func registryID(_ device: IOHIDDevice) -> UInt64? {
        var identifier: UInt64 = 0
        let result = IORegistryEntryGetRegistryEntryID(
            IOHIDDeviceGetService(device),
            &identifier
        )
        return result == kIOReturnSuccess ? identifier : nil
    }

    private static func integer(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func usagePairs(_ device: IOHIDDevice) -> [HIDUsagePair] {
        guard
            let values = IOHIDDeviceGetProperty(
                device,
                kIOHIDDeviceUsagePairsKey as CFString
            ) as? [[String: Any]]
        else {
            return []
        }
        return values.compactMap { value in
            guard
                let page = (value[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue,
                let usage = (value[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue
            else {
                return nil
            }
            return HIDUsagePair(page: page, usage: usage)
        }
    }
}
