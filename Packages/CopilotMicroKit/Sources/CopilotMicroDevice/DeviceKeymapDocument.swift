import CryptoKit
import Foundation

public enum DeviceKeymapDocumentError: Error, Equatable, Sendable {
    case invalidActiveLayer
    case invalidBinding
    case invalidContact
    case malformed
    case tooLarge
}

public struct DeviceKeymapCoordinate: Codable, Equatable, Sendable {
    public let row: Int
    public let column: Int
}

public struct DeviceKeymapChange: Codable, Equatable, Sendable {
    public let contact: Int
    public let coordinate: DeviceKeymapCoordinate
    public let previousValue: String
    public let replacementValue: String
}

public struct DevicePeripheralChange: Codable, Equatable, Sendable {
    public let location: String
    public let previousValue: String
    public let replacementValue: String
}

public struct DeviceKeymapPlan: Equatable, Sendable {
    public let activeProfileID: Int
    public let activeLayerIndex: Int
    public let sourceSHA256: String
    public let resultSHA256: String
    public let keyChanges: [DeviceKeymapChange]
    public let peripheralChanges: [DevicePeripheralChange]
    public let resultData: Data

    public var changeCount: Int {
        keyChanges.count + peripheralChanges.count
    }
}

public struct DeviceKeymapDocument: Equatable, Sendable {
    public let data: Data
    public let sha256: String
    public let schemaVersion: Int
    public let activeProfileID: Int
    public let activeLayerIndex: Int
    public let profileCount: Int
    public let activeProfileLayerCount: Int
    public let activeLayerKeyRowLengths: [Int]

    public init(rpcResult: Any?, activeLayerIndex: Int) throws {
        guard
            let wrapper = rpcResult as? [String: Any],
            let encoded = wrapper["data"] as? String,
            let data = encoded.data(using: .utf8)
        else {
            throw DeviceKeymapDocumentError.malformed
        }
        try self.init(data: data, activeLayerIndex: activeLayerIndex)
    }

    public init(data: Data, activeLayerIndex: Int) throws {
        guard !data.isEmpty else {
            throw DeviceKeymapDocumentError.malformed
        }
        guard data.count <= DeviceSnapshotParser.maximumKeymapBytes else {
            throw DeviceKeymapDocumentError.tooLarge
        }
        let parsed = try Self.parse(data: data, activeLayerIndex: activeLayerIndex)
        self.data = data
        sha256 = Self.digest(data)
        schemaVersion = parsed.schemaVersion
        activeProfileID = parsed.activeProfileID
        self.activeLayerIndex = activeLayerIndex
        profileCount = parsed.profiles.count
        activeProfileLayerCount = parsed.layers.count
        activeLayerKeyRowLengths = parsed.keymap.map(\.count)
    }

    public var summary: DeviceKeymapSummary {
        DeviceKeymapSummary(
            byteCount: data.count,
            schemaVersion: schemaVersion,
            activeProfileID: activeProfileID,
            activeProfileMatched: true,
            profileCount: profileCount,
            activeProfileLayerCount: activeProfileLayerCount,
            activeLayerAvailable: true,
            activeLayerKeyRowLengths: activeLayerKeyRowLengths
        )
    }

    public func isSemanticallyEqual(to otherData: Data) -> Bool {
        guard
            let lhs = try? JSONSerialization.jsonObject(with: data),
            let rhs = try? JSONSerialization.jsonObject(with: otherData)
        else {
            return false
        }
        return (lhs as AnyObject).isEqual(rhs)
    }

    public func planForCopilotMicro() throws -> DeviceKeymapPlan {
        guard activeLayerKeyRowLengths == [2, 4, 4, 3] else {
            throw DeviceKeymapDocumentError.malformed
        }
        return try replacing(
            keyBindings: Dictionary(
                uniqueKeysWithValues: (0...12).map {
                    ($0, String(format: "KV_OAI_AG%02d", $0))
                }
            ),
            encoderBindings: [
                0: "KV_OAI_AG13",
                1: "KV_OAI_AG14",
            ],
            joystickBindings: [
                0.25: "KV_OAI_AG15",
                0.50: "KV_OAI_AG16",
                0.75: "KV_OAI_AG17",
                0.00: "KV_OAI_AG18",
            ]
        )
    }

    func replacing(
        keyBindings: [Int: String],
        encoderBindings: [Int: String] = [:],
        joystickBindings: [Double: String] = [:]
    ) throws -> DeviceKeymapPlan {
        let parsed = try Self.parse(data: data, activeLayerIndex: activeLayerIndex)
        var root = parsed.root
        var profiles = parsed.profiles
        var profile = profiles[parsed.profileIndex]
        var layers = parsed.layers
        var layer = layers[activeLayerIndex]
        var layout = parsed.layout
        var keymap = parsed.keymap
        var keyChanges: [DeviceKeymapChange] = []
        var peripheralChanges: [DevicePeripheralChange] = []

        for (contact, replacement) in keyBindings.sorted(by: { $0.key < $1.key }) {
            try Self.validateBinding(replacement)
            guard let coordinate = Self.coordinate(for: contact, rowLengths: activeLayerKeyRowLengths)
            else {
                throw DeviceKeymapDocumentError.invalidContact
            }
            let previous = keymap[coordinate.row][coordinate.column]
            guard !Self.jsonValuesEqual(previous, replacement) else { continue }
            keyChanges.append(
                DeviceKeymapChange(
                    contact: contact,
                    coordinate: coordinate,
                    previousValue: Self.boundedDescription(previous),
                    replacementValue: replacement
                )
            )
            keymap[coordinate.row][coordinate.column] = replacement
        }

        layout["keymap"] = keymap
        if !encoderBindings.isEmpty {
            guard
                var encoders = layout["encoders"] as? [[Any]],
                !encoders.isEmpty,
                encoders[0].count >= 3
            else {
                throw DeviceKeymapDocumentError.malformed
            }
            for (slot, replacement) in encoderBindings.sorted(by: { $0.key < $1.key }) {
                try Self.validateBinding(replacement)
                guard (0...1).contains(slot) else {
                    throw DeviceKeymapDocumentError.invalidContact
                }
                let previous = encoders[0][slot]
                guard !Self.jsonValuesEqual(previous, replacement) else { continue }
                peripheralChanges.append(
                    DevicePeripheralChange(
                        location: slot == 0 ? "encoder.clockwise" : "encoder.counterClockwise",
                        previousValue: Self.boundedDescription(previous),
                        replacementValue: replacement
                    )
                )
                encoders[0][slot] = replacement
            }
            layout["encoders"] = encoders
        }
        if !joystickBindings.isEmpty {
            guard
                var joystick = layout["joystick"] as? [String: Any],
                var sectors = joystick["sectors"] as? [[String: Any]]
            else {
                throw DeviceKeymapDocumentError.malformed
            }
            var matchedCenters: Set<Double> = []
            for index in sectors.indices {
                guard
                    let start = HIDJSONNumber.finiteDouble(sectors[index]["a1"]),
                    let end = HIDJSONNumber.finiteDouble(sectors[index]["a2"]),
                    let center = Self.sectorCenter(start: start, end: end)
                else {
                    throw DeviceKeymapDocumentError.malformed
                }
                guard
                    let target = joystickBindings.keys.first(where: {
                        Self.anglesEqual(center, $0)
                    }),
                    let replacement = joystickBindings[target]
                else {
                    continue
                }
                try Self.validateBinding(replacement)
                guard matchedCenters.insert(target).inserted else {
                    throw DeviceKeymapDocumentError.malformed
                }
                let previous = sectors[index]["k"] ?? NSNull()
                guard !Self.jsonValuesEqual(previous, replacement) else { continue }
                peripheralChanges.append(
                    DevicePeripheralChange(
                        location: String(format: "joystick.center.%.2f", target),
                        previousValue: Self.boundedDescription(previous),
                        replacementValue: replacement
                    )
                )
                sectors[index]["k"] = replacement
            }
            guard matchedCenters.count == joystickBindings.count else {
                throw DeviceKeymapDocumentError.malformed
            }
            joystick["sectors"] = sectors
            layout["joystick"] = joystick
        }
        peripheralChanges.sort { $0.replacementValue < $1.replacementValue }
        layer["layout"] = layout
        layers[activeLayerIndex] = layer
        profile["layers"] = layers
        profiles[parsed.profileIndex] = profile
        root["profiles"] = profiles

        if keyChanges.isEmpty, peripheralChanges.isEmpty {
            return DeviceKeymapPlan(
                activeProfileID: activeProfileID,
                activeLayerIndex: activeLayerIndex,
                sourceSHA256: sha256,
                resultSHA256: sha256,
                keyChanges: [],
                peripheralChanges: [],
                resultData: data
            )
        }

        let resultData: Data
        do {
            resultData = try JSONSerialization.data(
                withJSONObject: root,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw DeviceKeymapDocumentError.malformed
        }
        guard resultData.count <= DeviceSnapshotParser.maximumKeymapBytes else {
            throw DeviceKeymapDocumentError.tooLarge
        }
        _ = try Self.parse(data: resultData, activeLayerIndex: activeLayerIndex)
        return DeviceKeymapPlan(
            activeProfileID: activeProfileID,
            activeLayerIndex: activeLayerIndex,
            sourceSHA256: sha256,
            resultSHA256: Self.digest(resultData),
            keyChanges: keyChanges,
            peripheralChanges: peripheralChanges,
            resultData: resultData
        )
    }

    private struct ParsedDocument {
        let root: [String: Any]
        let schemaVersion: Int
        let activeProfileID: Int
        let profiles: [[String: Any]]
        let profileIndex: Int
        let layers: [[String: Any]]
        let layout: [String: Any]
        let keymap: [[Any]]
    }

    private static func parse(data: Data, activeLayerIndex: Int) throws -> ParsedDocument {
        do {
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let schemaVersion = HIDJSONNumber.integer(root["version"]),
                schemaVersion >= 1,
                let activeProfileID = HIDJSONNumber.integer(root["activeProfileId"]),
                activeProfileID >= 0,
                let profiles = root["profiles"] as? [[String: Any]],
                (1...64).contains(profiles.count),
                let profileIndex = profiles.firstIndex(where: {
                    HIDJSONNumber.integer($0["id"]) == activeProfileID
                }),
                let layers = profiles[profileIndex]["layers"] as? [[String: Any]],
                (1...64).contains(layers.count),
                layers.indices.contains(activeLayerIndex),
                let layout = layers[activeLayerIndex]["layout"] as? [String: Any],
                let keymap = layout["keymap"] as? [[Any]],
                !keymap.isEmpty,
                keymap.count <= 16,
                keymap.allSatisfy({ (1...64).contains($0.count) })
            else {
                throw DeviceKeymapDocumentError.malformed
            }
            return ParsedDocument(
                root: root,
                schemaVersion: schemaVersion,
                activeProfileID: activeProfileID,
                profiles: profiles,
                profileIndex: profileIndex,
                layers: layers,
                layout: layout,
                keymap: keymap
            )
        } catch let error as DeviceKeymapDocumentError {
            throw error
        } catch {
            throw DeviceKeymapDocumentError.malformed
        }
    }

    private static func coordinate(
        for contact: Int,
        rowLengths: [Int]
    ) -> DeviceKeymapCoordinate? {
        guard contact >= 0 else { return nil }
        var remaining = contact
        for (row, length) in rowLengths.enumerated() {
            if remaining < length {
                return DeviceKeymapCoordinate(row: row, column: remaining)
            }
            remaining -= length
        }
        return nil
    }

    private static func jsonValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as AnyObject).isEqual(rhs)
    }

    private static func validateBinding(_ binding: String) throws {
        guard
            binding.wholeMatch(of: /^KV_OAI_AG[0-9]{2}$/) != nil
        else {
            throw DeviceKeymapDocumentError.invalidBinding
        }
    }

    private static func sectorCenter(start: Double, end: Double) -> Double? {
        guard
            start.isFinite,
            end.isFinite,
            (0...1).contains(start),
            (0...1).contains(end)
        else {
            return nil
        }
        let distance = end >= start ? end - start : (1 - start) + end
        return (start + (distance / 2)).truncatingRemainder(dividingBy: 1)
    }

    private static func anglesEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        let difference = abs(lhs - rhs)
        return min(difference, 1 - difference) <= 0.000_001
    }

    private static func boundedDescription(_ value: Any) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
            )
        else {
            return "<unsupported>"
        }
        return String(String(decoding: data, as: UTF8.self).prefix(128))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
