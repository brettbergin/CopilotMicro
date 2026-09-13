import Foundation

public enum DeviceSnapshotError: Error, Equatable, Sendable {
    case malformedFirmware
    case malformedStatus
    case malformedKeymap
    case keymapTooLarge
}

public struct DeviceStatusSummary: Codable, Equatable, Sendable {
    public let battery: Double
    public let charging: Bool
    public let activeLayerIndex: Int

    public init(battery: Double, charging: Bool, activeLayerIndex: Int) {
        self.battery = battery
        self.charging = charging
        self.activeLayerIndex = activeLayerIndex
    }
}

public struct DeviceKeymapSummary: Codable, Equatable, Sendable {
    public let byteCount: Int
    public let schemaVersion: Int
    public let activeProfileID: Int
    public let activeProfileMatched: Bool
    public let profileCount: Int
    public let activeProfileLayerCount: Int
    public let activeLayerAvailable: Bool
    public let activeLayerKeyRowLengths: [Int]

    public init(
        byteCount: Int,
        schemaVersion: Int,
        activeProfileID: Int,
        activeProfileMatched: Bool,
        profileCount: Int,
        activeProfileLayerCount: Int,
        activeLayerAvailable: Bool,
        activeLayerKeyRowLengths: [Int]
    ) {
        self.byteCount = byteCount
        self.schemaVersion = schemaVersion
        self.activeProfileID = activeProfileID
        self.activeProfileMatched = activeProfileMatched
        self.profileCount = profileCount
        self.activeProfileLayerCount = activeProfileLayerCount
        self.activeLayerAvailable = activeLayerAvailable
        self.activeLayerKeyRowLengths = activeLayerKeyRowLengths
    }
}

public enum DeviceSnapshotParser {
    public static let maximumKeymapBytes = 524_288

    public static func firmwareVersion(from result: Any?) throws -> String {
        let value: String?
        if let string = result as? String {
            value = string
        } else {
            value = (result as? [String: Any])?["version"] as? String
        }
        guard
            let value,
            !value.isEmpty,
            value.utf8.count <= 64,
            value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E })
        else {
            throw DeviceSnapshotError.malformedFirmware
        }
        return value
    }

    public static func status(from result: Any?) throws -> DeviceStatusSummary {
        guard
            let dictionary = result as? [String: Any],
            let battery = number(dictionary["battery"]),
            battery >= 0,
            battery <= 100,
            let charging = dictionary["is_charging"] as? Bool,
            let activeLayerNumber = integer(dictionary["layer_index"]),
            (1...256).contains(activeLayerNumber)
        else {
            throw DeviceSnapshotError.malformedStatus
        }
        return DeviceStatusSummary(
            battery: battery,
            charging: charging,
            activeLayerIndex: activeLayerNumber - 1
        )
    }

    public static func keymap(
        from result: Any?,
        activeLayerIndex: Int
    ) throws -> DeviceKeymapSummary {
        do {
            return try DeviceKeymapDocument(
                rpcResult: result,
                activeLayerIndex: activeLayerIndex
            ).summary
        } catch DeviceKeymapDocumentError.tooLarge {
            throw DeviceSnapshotError.keymapTooLarge
        } catch {
            throw DeviceSnapshotError.malformedKeymap
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        HIDJSONNumber.integer(value)
    }

    private static func number(_ value: Any?) -> Double? {
        HIDJSONNumber.finiteDouble(value)
    }
}
