import Foundation
import Testing

@testable import CopilotMicroDevice

@Suite("Device keymap document")
struct DeviceKeymapDocumentTests {
    @Test("Plans update exact flattened contacts and preserve unrelated data")
    func plansPreserveUnrelatedData() throws {
        let source = try fixtureData()
        let document = try DeviceKeymapDocument(data: source, activeLayerIndex: 1)
        let plan = try document.replacing(
            keyBindings: [
                0: "KV_OAI_AG00",
                12: "KV_OAI_AG12",
            ]
        )

        #expect(plan.activeProfileID == 7)
        #expect(plan.activeLayerIndex == 1)
        #expect(plan.keyChanges.map(\.contact) == [0, 12])
        #expect(
            plan.keyChanges.map(\.coordinate) == [
                DeviceKeymapCoordinate(row: 0, column: 0),
                DeviceKeymapCoordinate(row: 3, column: 2),
            ]
        )
        #expect(plan.sourceSHA256 == document.sha256)
        #expect(plan.resultSHA256 != plan.sourceSHA256)

        let result = try #require(
            JSONSerialization.jsonObject(with: plan.resultData) as? [String: Any]
        )
        #expect(result["unrelated"] as? String == "preserve")
        let profiles = try #require(result["profiles"] as? [[String: Any]])
        let inactiveProfile = try #require(profiles.first)
        #expect(inactiveProfile["name"] as? String == "inactive")
        let activeProfile = try #require(profiles.last)
        let layers = try #require(activeProfile["layers"] as? [[String: Any]])
        let activeLayout = try #require(layers[1]["layout"] as? [String: Any])
        let keymap = try #require(activeLayout["keymap"] as? [[Any]])
        #expect(keymap[0][0] as? String == "KV_OAI_AG00")
        #expect(keymap[3][2] as? String == "KV_OAI_AG12")
        #expect(keymap[2][1] as? String == "L1-7")
        #expect(layers[0]["marker"] as? String == "preserve-layer")
    }

    @Test("Plans reject contacts and bindings outside the bounded layout")
    func plansRejectInvalidChanges() throws {
        let document = try DeviceKeymapDocument(
            data: fixtureData(),
            activeLayerIndex: 1
        )
        #expect(throws: DeviceKeymapDocumentError.invalidContact) {
            _ = try document.replacing(keyBindings: [13: "KV_OAI_AG13"])
        }
        #expect(throws: DeviceKeymapDocumentError.invalidBinding) {
            _ = try document.replacing(
                keyBindings: [0: String(repeating: "x", count: 65)]
            )
        }
    }

    @Test("Production plan maps keys, dial directions, and cardinal joystick sectors")
    func productionPlanUsesQualifiedBindings() throws {
        let document = try DeviceKeymapDocument(
            data: fixtureData(),
            activeLayerIndex: 1
        )
        let plan = try document.planForCopilotMicro()
        #expect(plan.keyChanges.count == 13)
        #expect(plan.peripheralChanges.count == 6)
        #expect(plan.changeCount == 19)
        #expect(plan.keyChanges.first?.replacementValue == "KV_OAI_AG00")
        #expect(plan.keyChanges.last?.replacementValue == "KV_OAI_AG12")
        #expect(
            plan.peripheralChanges.map(\.replacementValue)
                == [
                    "KV_OAI_AG13",
                    "KV_OAI_AG14",
                    "KV_OAI_AG15",
                    "KV_OAI_AG16",
                    "KV_OAI_AG17",
                    "KV_OAI_AG18",
                ]
        )

        let result = try #require(
            JSONSerialization.jsonObject(with: plan.resultData) as? [String: Any]
        )
        let profiles = try #require(result["profiles"] as? [[String: Any]])
        let activeProfile = try #require(profiles.last)
        let layers = try #require(activeProfile["layers"] as? [[String: Any]])
        let layout = try #require(layers[1]["layout"] as? [String: Any])
        let encoders = try #require(layout["encoders"] as? [[Any]])
        #expect(encoders[0][0] as? String == "KV_OAI_AG13")
        #expect(encoders[0][1] as? String == "KV_OAI_AG14")
        #expect(encoders[0][2] as? String == "PRESERVE_PRESS")
        let joystick = try #require(layout["joystick"] as? [String: Any])
        let sectors = try #require(joystick["sectors"] as? [[String: Any]])
        #expect(sectors[0]["k"] as? String == "KV_OAI_AG18")
        #expect(sectors[1]["k"] as? String == "PRESERVE_DIAGONAL")
        #expect(sectors[2]["k"] as? String == "KV_OAI_AG15")
        #expect(sectors[4]["k"] as? String == "KV_OAI_AG16")
        #expect(sectors[6]["k"] as? String == "KV_OAI_AG17")
    }

    @Test("Semantic verification tolerates JSON formatting but detects changed values")
    func semanticVerificationUsesJSONValues() throws {
        let source = try fixtureData()
        let document = try DeviceKeymapDocument(data: source, activeLayerIndex: 1)
        let object = try JSONSerialization.jsonObject(with: source)
        let reformatted = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        #expect(document.isSemanticallyEqual(to: reformatted))

        var changed = try #require(object as? [String: Any])
        changed["unrelated"] = "changed"
        let changedData = try JSONSerialization.data(withJSONObject: changed)
        #expect(!document.isSemanticallyEqual(to: changedData))
    }

    private func fixtureData() throws -> Data {
        let rows = [
            ["L1-0", "L1-1"],
            ["L1-2", "L1-3", "L1-4", "L1-5"],
            ["L1-6", "L1-7", "L1-8", "L1-9"],
            ["L1-10", "L1-11", "L1-12"],
        ]
        let object: [String: Any] = [
            "version": 1,
            "activeProfileId": 7,
            "unrelated": "preserve",
            "profiles": [
                ["id": 0, "name": "inactive", "layers": []],
                [
                    "id": 7,
                    "name": "active",
                    "layers": [
                        [
                            "marker": "preserve-layer",
                            "layout": ["keymap": rows],
                        ],
                        [
                            "layout": [
                                "keymap": rows,
                                "encoders": [
                                    ["CW", "CCW", "PRESERVE_PRESS"]
                                ],
                                "joystick": [
                                    "type": "RADIAL",
                                    "sectors": [
                                        ["k": "N", "a1": 0.875, "a2": 0.125],
                                        ["k": "PRESERVE_DIAGONAL", "a1": 0.125, "a2": 0.25],
                                        ["k": "E", "a1": 0.125, "a2": 0.375],
                                        ["k": "SE", "a1": 0.375, "a2": 0.5],
                                        ["k": "S", "a1": 0.375, "a2": 0.625],
                                        ["k": "SW", "a1": 0.625, "a2": 0.75],
                                        ["k": "W", "a1": 0.625, "a2": 0.875],
                                        ["k": "NW", "a1": 0.875, "a2": 1.0],
                                    ],
                                ],
                            ]
                        ],
                    ],
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
