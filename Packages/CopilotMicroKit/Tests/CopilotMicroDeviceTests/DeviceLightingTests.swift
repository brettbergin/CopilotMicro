import CopilotMicroCore
import Foundation
import Testing

@testable import CopilotMicroDevice

@Suite("Creator Micro device lighting")
struct DeviceLightingTests {
    @Test("Lighting wire values use bounded abbreviated firmware fields")
    func encodesThreadWireValues() throws {
        let lighting = try DeviceKeyLighting(
            id: 12,
            color: DeviceRGBColor(packedValue: 0x12_3456),
            brightness: 0.35,
            effect: .solid,
            speed: 0.5
        )

        #expect(HIDJSONNumber.integer(lighting.wireValue["id"]) == 12)
        #expect(HIDJSONNumber.integer(lighting.wireValue["c"]) == 0x12_3456)
        #expect(HIDJSONNumber.finiteDouble(lighting.wireValue["b"]) == 0.35)
        #expect(HIDJSONNumber.integer(lighting.wireValue["e"]) == 1)
        #expect(HIDJSONNumber.finiteDouble(lighting.wireValue["s"]) == 0.5)
        #expect(HIDJSONNumber.integer(lighting.wireValue["sk"]) == 0)
        #expect(HIDJSONNumber.integer(lighting.wireValue["sa"]) == 0)
    }

    @Test("Lighting validates thread, color, brightness, and speed bounds")
    func rejectsInvalidLighting() throws {
        #expect(throws: DeviceLightingError.invalidThreadID) {
            _ = try DeviceKeyLighting(
                id: 20,
                color: DeviceRGBColor(.white),
                brightness: 0.5,
                effect: .solid
            )
        }
        #expect(throws: DeviceLightingError.invalidColor) {
            _ = try DeviceRGBColor(packedValue: 0x1_00_0000)
        }
        #expect(throws: DeviceLightingError.invalidBrightness) {
            _ = try DeviceKeyLighting(
                id: 0,
                color: DeviceRGBColor(.white),
                brightness: .nan,
                effect: .solid
            )
        }
        #expect(throws: DeviceLightingError.invalidSpeed) {
            _ = try DeviceKeyLighting(
                id: 0,
                color: DeviceRGBColor(.white),
                brightness: 0.5,
                effect: .solid,
                speed: 2
            )
        }
        #expect(throws: DeviceLightingError.invalidMagic) {
            _ = try DeviceLightingZone(
                color: DeviceRGBColor(.white),
                brightness: 0.5,
                effect: .solid,
                magic: 2
            )
        }
    }

    @Test("Core projection renders all visible keys with host-driven intensity")
    func rendersCoreProjection() throws {
        let projection = LightingProjection(
            semanticState: .working,
            color: .blue,
            animation: .blink,
            textualState: "Working",
            brightness: try Brightness(clamping: 0.65),
            appliesToAllKeys: true
        )

        let on = try DeviceLightingRenderer.render(projection, atMilliseconds: 0)
        #expect(on.map(\.id) == Array(0...12))
        #expect(on.allSatisfy { $0.color == DeviceRGBColor(.blue) })
        #expect(on.allSatisfy { $0.brightness == 0.65 })
        #expect(on.allSatisfy { $0.effect == .solid })

        let off = try DeviceLightingRenderer.render(projection, atMilliseconds: 250)
        #expect(off.allSatisfy { $0.brightness == 0 })
        #expect(off.allSatisfy { $0.effect == .off })
    }

    @Test("Lighting acknowledgement requires ok equal to one")
    func validatesAcknowledgement() throws {
        #expect(try DeviceLightingReceipt(result: ["ok": 1]).acknowledged)
        #expect(throws: DeviceLightingError.malformedAcknowledgement) {
            _ = try DeviceLightingReceipt(result: ["ok": 0])
        }
        #expect(throws: DeviceLightingError.malformedAcknowledgement) {
            _ = try DeviceLightingReceipt(result: nil)
        }
    }
}
