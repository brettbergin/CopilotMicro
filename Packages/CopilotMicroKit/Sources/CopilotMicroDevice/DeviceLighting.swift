import CopilotMicroCore
import Foundation

public enum DeviceLightingError: Error, Equatable, LocalizedError, Sendable {
    case invalidBrightness
    case invalidColor
    case invalidMagic
    case invalidSpeed
    case invalidThreadID
    case malformedAcknowledgement

    public var errorDescription: String? {
        switch self {
        case .invalidBrightness:
            "Lighting brightness must be finite and between 0 and 1."
        case .invalidColor:
            "Lighting color must be a packed 24-bit RGB value."
        case .invalidMagic:
            "Lighting magic must be finite and between 0 and 1."
        case .invalidSpeed:
            "Lighting speed must be finite and between 0 and 1."
        case .invalidThreadID:
            "Lighting thread ID must be between 0 and 19."
        case .malformedAcknowledgement:
            "The device returned an invalid lighting acknowledgement."
        }
    }
}

public enum DeviceLightingEffect: Int, Equatable, Sendable {
    case off = 0
    case solid = 1
    case snake = 2
    case rainbow = 3
    case breath = 4
    case gradient = 5
    case shallowBreath = 6
}

public struct DeviceRGBColor: Equatable, Sendable {
    public let packedValue: Int

    public init(packedValue: Int) throws {
        guard (0...0xFF_FFFF).contains(packedValue) else {
            throw DeviceLightingError.invalidColor
        }
        self.packedValue = packedValue
    }

    public init(_ color: LightingColor) {
        packedValue =
            switch color {
            case .off: 0x00_0000
            case .white: 0xFF_FFFF
            case .blue: 0x44_93F8
            case .purple: 0xA3_71F7
            case .red: 0xF8_5149
            case .amber: 0xD2_9922
            case .green: 0x3F_B950
            }
    }
}

public struct DeviceKeyLighting: Equatable, Sendable {
    public static let visibleKeyIDs = Array(0...12)
    public static let maximumThreadID = 19

    public let id: Int
    public let color: DeviceRGBColor
    public let brightness: Double
    public let effect: DeviceLightingEffect
    public let speed: Double

    public init(
        id: Int,
        color: DeviceRGBColor,
        brightness: Double,
        effect: DeviceLightingEffect,
        speed: Double = 0.5
    ) throws {
        guard (0...Self.maximumThreadID).contains(id) else {
            throw DeviceLightingError.invalidThreadID
        }
        guard brightness.isFinite, (0...1).contains(brightness) else {
            throw DeviceLightingError.invalidBrightness
        }
        guard speed.isFinite, (0...1).contains(speed) else {
            throw DeviceLightingError.invalidSpeed
        }
        self.id = id
        self.color = color
        self.brightness = brightness
        self.effect = effect
        self.speed = speed
    }

    private init(
        validatedID id: Int,
        color: DeviceRGBColor,
        brightness: Double,
        effect: DeviceLightingEffect,
        speed: Double
    ) {
        self.id = id
        self.color = color
        self.brightness = brightness
        self.effect = effect
        self.speed = speed
    }

    var wireValue: [String: Any] {
        [
            "id": id,
            "c": color.packedValue,
            "b": brightness,
            "e": effect.rawValue,
            "s": speed,
            "sk": 0,
            "sa": 0,
        ]
    }

    public static func allVisibleKeys(
        color: DeviceRGBColor,
        brightness: Double,
        effect: DeviceLightingEffect = .solid
    ) throws -> [DeviceKeyLighting] {
        try visibleKeyIDs.map {
            try DeviceKeyLighting(
                id: $0,
                color: color,
                brightness: brightness,
                effect: brightness == 0 ? .off : effect
            )
        }
    }

    public static func allThreadsOff() -> [DeviceKeyLighting] {
        (0...maximumThreadID).map {
            DeviceKeyLighting(
                validatedID: $0,
                color: DeviceRGBColor(.off),
                brightness: 0,
                effect: .off,
                speed: 0.5
            )
        }
    }
}

public struct DeviceLightingZone: Equatable, Sendable {
    public let color: DeviceRGBColor
    public let brightness: Double
    public let effect: DeviceLightingEffect
    public let speed: Double
    public let magic: Double

    public init(
        color: DeviceRGBColor,
        brightness: Double,
        effect: DeviceLightingEffect,
        speed: Double = 0.5,
        magic: Double = 1
    ) throws {
        guard brightness.isFinite, (0...1).contains(brightness) else {
            throw DeviceLightingError.invalidBrightness
        }
        guard speed.isFinite, (0...1).contains(speed) else {
            throw DeviceLightingError.invalidSpeed
        }
        guard magic.isFinite, (0...1).contains(magic) else {
            throw DeviceLightingError.invalidMagic
        }
        self.color = color
        self.brightness = brightness
        self.effect = effect
        self.speed = speed
        self.magic = magic
    }

    var wireValue: [String: Any] {
        [
            "c": color.packedValue,
            "b": brightness,
            "e": effect.rawValue,
            "s": speed,
            "m": magic,
        ]
    }
}

public struct DeviceLightingReceipt: Equatable, Sendable {
    public let acknowledged: Bool

    init(result: Any?) throws {
        guard
            let object = result as? [String: Any],
            HIDJSONNumber.integer(object["ok"]) == 1
        else {
            throw DeviceLightingError.malformedAcknowledgement
        }
        acknowledged = true
    }
}

public enum DeviceLightingRenderer {
    public static func render(
        _ projection: LightingProjection,
        atMilliseconds milliseconds: UInt64
    ) throws -> [DeviceKeyLighting] {
        let intensity = projection.intensity(atMilliseconds: milliseconds)
        return try DeviceKeyLighting.allVisibleKeys(
            color: DeviceRGBColor(projection.color),
            brightness: intensity,
            effect: intensity > 0 ? .solid : .off
        )
    }
}
