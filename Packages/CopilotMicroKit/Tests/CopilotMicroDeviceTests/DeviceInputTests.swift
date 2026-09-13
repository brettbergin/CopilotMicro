import CopilotMicroCore
import Foundation
import Testing

@testable import CopilotMicroDevice

@Suite("Creator Micro device input")
struct DeviceInputTests {
    @Test("HID notifications require exact method, AG key, and binary action")
    func parsesHIDNotificationsStrictly() throws {
        #expect(
            try DeviceHIDNotification.parse(
                method: "v.oai.hid",
                params: ["k": "AG13", "act": 1]
            ) == DeviceHIDNotification(keyIndex: 13, isPressed: true)
        )
        #expect(
            try DeviceHIDNotification.parse(
                method: "v.oai.rad",
                params: ["k": "AG13", "act": 1]
            ) == nil
        )
        #expect(throws: DeviceInputNotificationError.malformedParameters) {
            _ = try DeviceHIDNotification.parse(
                method: "v.oai.hid",
                params: ["k": "AG1", "act": 1]
            )
        }
        #expect(throws: DeviceInputNotificationError.invalidKey) {
            _ = try DeviceHIDNotification.parse(
                method: "v.oai.hid",
                params: ["k": "AG19", "act": 1]
            )
        }
        #expect(throws: DeviceInputNotificationError.invalidAction) {
            _ = try DeviceHIDNotification.parse(
                method: "v.oai.hid",
                params: ["k": "AG00", "act": 2]
            )
        }
    }

    @Test("Radial notifications require bounded finite angle and distance")
    func parsesRadialNotificationsStrictly() throws {
        #expect(
            try DeviceRadialNotification.parse(
                method: "kb.radial",
                params: ["a": 0.25, "d": 0.75]
            ) == DeviceRadialNotification(angle: 0.25, distance: 0.75)
        )
        #expect(
            try DeviceRadialNotification.parse(
                method: "v.oai.hid",
                params: ["a": 0.25, "d": 0.75]
            ) == nil
        )
        #expect(throws: DeviceInputNotificationError.malformedParameters) {
            _ = try DeviceRadialNotification.parse(
                method: "kb.radial",
                params: ["a": -0.1, "d": 0.75]
            )
        }
        #expect(throws: DeviceInputNotificationError.malformedParameters) {
            _ = try DeviceRadialNotification.parse(
                method: "kb.radial",
                params: ["a": 0.25, "d": 1.1]
            )
        }
    }

    @Test("Wide key contacts produce one logical press and release")
    func coalescesWideKeyContacts() throws {
        var normalizer = CreatorMicroInputNormalizer()

        #expect(
            normalizer.process(
                try DeviceHIDNotification(keyIndex: 10, isPressed: true),
                atMilliseconds: 0
            )?.control == .key(.submit)
        )
        #expect(
            normalizer.process(
                try DeviceHIDNotification(keyIndex: 11, isPressed: true),
                atMilliseconds: 1
            ) == nil
        )
        #expect(
            normalizer.process(
                try DeviceHIDNotification(keyIndex: 10, isPressed: false),
                atMilliseconds: 2
            ) == nil
        )
        let release = normalizer.process(
            try DeviceHIDNotification(keyIndex: 11, isPressed: false),
            atMilliseconds: 3
        )
        #expect(release?.control == .key(.submit))
        #expect(release?.phase == .released)
    }

    @Test("Dial emits one detent per press edge")
    func normalizesDialDetents() throws {
        var normalizer = CreatorMicroInputNormalizer()
        let press = try DeviceHIDNotification(keyIndex: 13, isPressed: true)
        let release = try DeviceHIDNotification(keyIndex: 13, isPressed: false)

        #expect(normalizer.process(press, atMilliseconds: 0)?.control == .dial(.clockwise))
        #expect(normalizer.process(press, atMilliseconds: 1) == nil)
        #expect(normalizer.process(release, atMilliseconds: 2) == nil)
        #expect(normalizer.process(press, atMilliseconds: 3)?.phase == .detent)
    }

    @Test("Joystick requires release before another cardinal direction")
    func normalizesJoystickNeutralTransitions() throws {
        var normalizer = CreatorMicroInputNormalizer()
        let eastPress = try DeviceHIDNotification(keyIndex: 18, isPressed: true)
        let eastRelease = try DeviceHIDNotification(keyIndex: 18, isPressed: false)
        let westPress = try DeviceHIDNotification(keyIndex: 16, isPressed: true)

        #expect(normalizer.process(eastPress, atMilliseconds: 0)?.control == .joystick(.east))
        #expect(normalizer.process(westPress, atMilliseconds: 1) == nil)
        let release = normalizer.process(eastRelease, atMilliseconds: 2)
        #expect(release?.control == .joystick(.east))
        #expect(release?.phase == .released)
        #expect(normalizer.process(westPress, atMilliseconds: 3)?.control == .joystick(.west))
    }

    @Test("Radial joystick uses measured cardinals and requires neutral")
    func normalizesRadialJoystick() throws {
        var normalizer = CreatorMicroInputNormalizer()

        let north = try DeviceRadialNotification(angle: 0.762, distance: 1)
        let west = try DeviceRadialNotification(angle: 0.487, distance: 1)
        let center = try DeviceRadialNotification(angle: 0.125, distance: 0)

        let press = normalizer.process(north)
        #expect(press?.rawKeyIndex == nil)
        #expect(press?.control == .joystick(.north))
        #expect(press?.phase == .pressed)
        #expect(normalizer.process(west) == nil)

        let release = normalizer.process(center)
        #expect(release?.control == .joystick(.north))
        #expect(release?.phase == .released)
        #expect(normalizer.process(west)?.control == .joystick(.west))
    }

    @Test("Native radial notifications supersede the HID joystick fallback")
    func radialJoystickSupersedesHIDFallback() throws {
        var normalizer = CreatorMicroInputNormalizer()

        let hidNorth = try DeviceHIDNotification(keyIndex: 15, isPressed: true)
        #expect(normalizer.process(hidNorth, atMilliseconds: 0)?.control == .joystick(.north))

        let radialEast = try DeviceRadialNotification(angle: 0.013, distance: 1)
        let radialPress = normalizer.process(radialEast)
        #expect(radialPress?.control == .joystick(.east))
        #expect(radialPress?.phase == .pressed)

        let ignoredHIDRelease = try DeviceHIDNotification(keyIndex: 15, isPressed: false)
        #expect(normalizer.process(ignoredHIDRelease, atMilliseconds: 1) == nil)

        let neutral = try DeviceRadialNotification(angle: 0.125, distance: 0)
        let radialRelease = normalizer.process(neutral)
        #expect(radialRelease?.control == .joystick(.east))
        #expect(radialRelease?.phase == .released)
    }

    @Test("Radial joystick applies hysteresis and ignores diagonal sectors")
    func filtersRadialJoystickNoiseAndDiagonals() throws {
        var normalizer = CreatorMicroInputNormalizer()

        #expect(
            normalizer.process(
                try DeviceRadialNotification(angle: 0.762, distance: 0.49)
            ) == nil
        )
        #expect(
            normalizer.process(
                try DeviceRadialNotification(angle: 0.625, distance: 1)
            ) == nil
        )
        #expect(
            normalizer.process(
                try DeviceRadialNotification(angle: 0.012, distance: 0.5)
            )?.control == .joystick(.east)
        )
        #expect(
            normalizer.process(
                try DeviceRadialNotification(angle: 0.2, distance: 0.21)
            ) == nil
        )
        #expect(
            normalizer.process(
                try DeviceRadialNotification(angle: 0.2, distance: 0.2)
            )?.phase == .released
        )
    }
}
