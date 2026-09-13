import CopilotMicroCore
import Foundation

public enum DeviceInputNotificationError: Error, Equatable, LocalizedError, Sendable {
    case invalidAction
    case invalidKey
    case malformedParameters

    public var errorDescription: String? {
        switch self {
        case .invalidAction:
            "The HID notification action must be 0 or 1."
        case .invalidKey:
            "The HID notification key must be AG00 through AG18."
        case .malformedParameters:
            "The HID notification parameters are malformed."
        }
    }
}

public struct DeviceHIDNotification: Equatable, Sendable {
    public static let method = "v.oai.hid"

    public let keyIndex: Int
    public let isPressed: Bool

    public init(keyIndex: Int, isPressed: Bool) throws {
        guard (0...18).contains(keyIndex) else {
            throw DeviceInputNotificationError.invalidKey
        }
        self.keyIndex = keyIndex
        self.isPressed = isPressed
    }

    public static func parse(method: String, params: Any?) throws -> DeviceHIDNotification? {
        guard method == Self.method else { return nil }
        guard
            let object = params as? [String: Any],
            let key = object["k"] as? String,
            key.wholeMatch(of: /^AG[0-9]{2}$/) != nil,
            let keyIndex = Int(key.dropFirst(2))
        else {
            throw DeviceInputNotificationError.malformedParameters
        }
        guard (0...18).contains(keyIndex) else {
            throw DeviceInputNotificationError.invalidKey
        }
        guard let action = HIDJSONNumber.integer(object["act"]), action == 0 || action == 1 else {
            throw DeviceInputNotificationError.invalidAction
        }
        return try DeviceHIDNotification(keyIndex: keyIndex, isPressed: action == 1)
    }
}

public struct DeviceRadialNotification: Equatable, Sendable {
    public static let method = "kb.radial"

    public let angle: Double
    public let distance: Double

    public init(angle: Double, distance: Double) throws {
        guard angle.isFinite, (0...1).contains(angle) else {
            throw DeviceInputNotificationError.malformedParameters
        }
        guard distance.isFinite, (0...1).contains(distance) else {
            throw DeviceInputNotificationError.malformedParameters
        }
        self.angle = angle
        self.distance = distance
    }

    public static func parse(method: String, params: Any?) throws -> DeviceRadialNotification? {
        guard method == Self.method else { return nil }
        guard
            let object = params as? [String: Any],
            let angle = HIDJSONNumber.finiteDouble(object["a"]),
            let distance = HIDJSONNumber.finiteDouble(object["d"])
        else {
            throw DeviceInputNotificationError.malformedParameters
        }
        return try DeviceRadialNotification(angle: angle, distance: distance)
    }
}

public enum DeviceInputPhase: String, Codable, Equatable, Sendable {
    case pressed
    case released
    case detent
}

public enum DeviceDialDirection: String, Codable, Equatable, Sendable {
    case clockwise
    case counterClockwise
}

public enum DeviceInputControl: Equatable, Sendable {
    case dial(DeviceDialDirection)
    case joystick(JoystickDirection)
    case key(PhysicalControlID)
}

public struct NormalizedDeviceInput: Equatable, Sendable {
    public let rawKeyIndex: Int?
    public let control: DeviceInputControl
    public let phase: DeviceInputPhase

    public init(
        rawKeyIndex: Int?,
        control: DeviceInputControl,
        phase: DeviceInputPhase
    ) {
        self.rawKeyIndex = rawKeyIndex
        self.control = control
        self.phase = phase
    }
}

public struct CreatorMicroInputNormalizer: Sendable {
    static let radialActivationDistance = 0.5
    static let radialReleaseDistance = 0.2
    static let radialCardinalHalfWidth = 0.0625

    private var keys: KeyInputNormalizer
    private var pressedDialDirections: Set<Int> = []
    private var hidJoystick = JoystickNormalizer()
    private var activeHIDJoystick: (keyIndex: Int, direction: JoystickDirection)?
    private var radialJoystick = JoystickNormalizer()
    private var activeRadialJoystick: JoystickDirection?
    private var hasSeenRadialNotification = false

    public init(wideKeyCoalescingMilliseconds: UInt64 = 50) {
        keys = KeyInputNormalizer(
            wideKeyCoalescingMilliseconds: wideKeyCoalescingMilliseconds
        )
    }

    public mutating func process(
        _ notification: DeviceHIDNotification,
        atMilliseconds milliseconds: UInt64
    ) -> NormalizedDeviceInput? {
        switch notification.keyIndex {
        case 0...12:
            guard
                let contact = try? MatrixContactID(rawValue: notification.keyIndex),
                let transition = keys.process(
                    contact: contact,
                    isPressed: notification.isPressed,
                    atMilliseconds: milliseconds
                )
            else {
                return nil
            }
            switch transition {
            case .pressed(let control):
                return NormalizedDeviceInput(
                    rawKeyIndex: notification.keyIndex,
                    control: .key(control),
                    phase: .pressed
                )
            case .released(let control):
                return NormalizedDeviceInput(
                    rawKeyIndex: notification.keyIndex,
                    control: .key(control),
                    phase: .released
                )
            }
        case 13, 14:
            if notification.isPressed {
                guard pressedDialDirections.insert(notification.keyIndex).inserted else {
                    return nil
                }
                return NormalizedDeviceInput(
                    rawKeyIndex: notification.keyIndex,
                    control: .dial(notification.keyIndex == 13 ? .clockwise : .counterClockwise),
                    phase: .detent
                )
            }
            pressedDialDirections.remove(notification.keyIndex)
            return nil
        case 15...18:
            guard !hasSeenRadialNotification else { return nil }
            guard let direction = Self.joystickDirection(for: notification.keyIndex) else {
                return nil
            }
            if notification.isPressed {
                guard activeHIDJoystick == nil else { return nil }
                guard let normalized = hidJoystick.process(Self.position(for: direction)) else {
                    return nil
                }
                activeHIDJoystick = (notification.keyIndex, normalized)
                return NormalizedDeviceInput(
                    rawKeyIndex: notification.keyIndex,
                    control: .joystick(normalized),
                    phase: .pressed
                )
            }
            guard activeHIDJoystick?.keyIndex == notification.keyIndex else {
                return nil
            }
            let released = activeHIDJoystick?.direction
            activeHIDJoystick = nil
            _ = hidJoystick.process(.neutral)
            guard let released else { return nil }
            return NormalizedDeviceInput(
                rawKeyIndex: notification.keyIndex,
                control: .joystick(released),
                phase: .released
            )
        default:
            return nil
        }
    }

    public mutating func process(
        _ notification: DeviceRadialNotification
    ) -> NormalizedDeviceInput? {
        let supersededHIDDirection = activeHIDJoystick?.direction
        if !hasSeenRadialNotification {
            hasSeenRadialNotification = true
            activeHIDJoystick = nil
            hidJoystick.reset()
        }
        if notification.distance <= Self.radialReleaseDistance {
            let released = activeRadialJoystick ?? supersededHIDDirection
            activeRadialJoystick = nil
            _ = radialJoystick.process(.neutral)
            guard let released else { return nil }
            return NormalizedDeviceInput(
                rawKeyIndex: nil,
                control: .joystick(released),
                phase: .released
            )
        }
        guard
            notification.distance >= Self.radialActivationDistance,
            activeRadialJoystick == nil,
            let position = Self.radialPosition(for: notification.angle),
            let direction = radialJoystick.process(position)
        else {
            return nil
        }
        activeRadialJoystick = direction
        return NormalizedDeviceInput(
            rawKeyIndex: nil,
            control: .joystick(direction),
            phase: .pressed
        )
    }

    public mutating func reset() {
        keys.reset()
        pressedDialDirections.removeAll()
        activeHIDJoystick = nil
        hidJoystick.reset()
        activeRadialJoystick = nil
        radialJoystick.reset()
        hasSeenRadialNotification = false
    }

    private static func joystickDirection(for keyIndex: Int) -> JoystickDirection? {
        switch keyIndex {
        case 15: .north
        case 16: .west
        case 17: .south
        case 18: .east
        default: nil
        }
    }

    private static func position(for direction: JoystickDirection) -> JoystickPosition {
        switch direction {
        case .north: .north
        case .south: .south
        case .east: .east
        case .west: .west
        }
    }

    private static func radialPosition(for angle: Double) -> JoystickPosition? {
        let cardinals: [(Double, JoystickPosition)] = [
            (0, .east),
            (0.25, .south),
            (0.5, .west),
            (0.75, .north),
        ]
        return cardinals.first { center, _ in
            let difference = abs(angle - center)
            return min(difference, 1 - difference) < radialCardinalHalfWidth
        }?.1
    }
}
