import CopilotMicroDevice
import Foundation
import Testing

@Suite("Read-only device snapshots")
struct DeviceSnapshotTests {
    @Test("Active profile IDs are matched by identity rather than array position")
    func activeProfileIsMatchedByID() throws {
        let inner: [String: Any] = [
            "version": 1,
            "activeProfileId": 7,
            "profiles": [
                ["id": 0, "layers": []],
                [
                    "id": 7,
                    "layers": [
                        ["layout": ["keymap": [["A", "B"], ["C", "D", "E", "F"]]]]
                    ],
                ],
            ],
        ]
        let innerData = try JSONSerialization.data(withJSONObject: inner)
        let result: [String: Any] = [
            "data": String(decoding: innerData, as: UTF8.self)
        ]
        let summary = try DeviceSnapshotParser.keymap(from: result, activeLayerIndex: 0)
        #expect(summary.activeProfileID == 7)
        #expect(summary.activeProfileMatched)
        #expect(summary.profileCount == 2)
        #expect(summary.activeProfileLayerCount == 1)
        #expect(summary.activeLayerAvailable == true)
        #expect(summary.activeLayerKeyRowLengths == [2, 4])
    }

    @Test("Firmware and status expose only bounded operational fields")
    func operationalFieldsAreBounded() throws {
        #expect(
            try DeviceSnapshotParser.firmwareVersion(
                from: ["version": "v0.6.0-rc.10"]
            ) == "v0.6.0-rc.10"
        )
        let status = try DeviceSnapshotParser.status(
            from: ["battery": 0.75, "is_charging": true, "layer_index": 2]
        )
        #expect(status == DeviceStatusSummary(battery: 0.75, charging: true, activeLayerIndex: 2))
        #expect(throws: DeviceSnapshotError.malformedFirmware) {
            _ = try DeviceSnapshotParser.firmwareVersion(
                from: ["version": String(repeating: "x", count: 65)]
            )
        }
        #expect(throws: DeviceSnapshotError.malformedStatus) {
            _ = try DeviceSnapshotParser.status(
                from: ["battery": true, "is_charging": true, "layer_index": 2]
            )
        }
        #expect(throws: DeviceSnapshotError.malformedStatus) {
            _ = try DeviceSnapshotParser.status(
                from: ["battery": 99, "is_charging": true, "layer_index": 256]
            )
        }
    }

    @Test("Keymap metadata must fit the evidence contract")
    func keymapMetadataIsBounded() throws {
        let oversizedRows = Array(repeating: ["A"], count: 17)
        let inner: [String: Any] = [
            "version": 1,
            "activeProfileId": 0,
            "profiles": [
                [
                    "id": 0,
                    "layers": [
                        ["layout": ["keymap": oversizedRows]]
                    ],
                ]
            ],
        ]
        let innerData = try JSONSerialization.data(withJSONObject: inner)
        let result: [String: Any] = [
            "data": String(decoding: innerData, as: UTF8.self)
        ]
        #expect(throws: DeviceSnapshotError.malformedKeymap) {
            _ = try DeviceSnapshotParser.keymap(from: result, activeLayerIndex: 0)
        }
    }

    @Test("Complete hardware evidence validates before emission")
    func hardwareEvidenceIsValidated() throws {
        let status = DeviceStatusSummary(battery: 99, charging: true, activeLayerIndex: 2)
        let keymap = DeviceKeymapSummary(
            byteCount: 2078,
            schemaVersion: 1,
            activeProfileID: 0,
            activeProfileMatched: true,
            profileCount: 1,
            activeProfileLayerCount: 3,
            activeLayerAvailable: true,
            activeLayerKeyRowLengths: [2, 4, 4, 3]
        )
        let evidence = HardwareCapabilityEvidence(
            generatedAt: "2026-09-12T12:00:00Z",
            product: "Creator Micro 2",
            productID: "0x8298",
            transport: .usb,
            inputReportBytes: 64,
            outputReportBytes: 64,
            serialPresent: true,
            firmwareVersion: "0.6.2",
            status: status,
            keymap: keymap,
            unexpectedResponseCount: 0,
            notificationCount: 0
        )
        try evidence.validate()

        let invalidEvidence = HardwareCapabilityEvidence(
            generatedAt: "2026-09-12T12:00:00Z",
            product: "Creator Micro 2",
            productID: "0x8298",
            transport: .unknown,
            inputReportBytes: 64,
            outputReportBytes: 64,
            serialPresent: true,
            firmwareVersion: "0.6.2",
            status: status,
            keymap: keymap,
            unexpectedResponseCount: 0,
            notificationCount: 0
        )
        #expect(throws: HardwareCapabilityEvidenceError.outOfBounds) {
            try invalidEvidence.validate()
        }
    }
}
