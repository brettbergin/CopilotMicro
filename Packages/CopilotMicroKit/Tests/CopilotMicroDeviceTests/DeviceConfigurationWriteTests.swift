import Foundation
import Testing

@testable import CopilotMicroDevice

@Suite("Guarded device configuration writes")
struct DeviceConfigurationWriteTests {
    @Test("Managed writes require exact plan digest and one-write consent")
    func managedWriteAuthorizationIsExact() throws {
        let keymapPlan = try keymapDocument(valuePrefix: "stock").planForCopilotMicro()
        let plan = try DeviceConfigurationWritePlan(managedMapping: keymapPlan)
        let associationID = String(repeating: "a", count: 64)
        let backupSHA256 = String(repeating: "b", count: 64)
        let authorization = try DeviceWriteAuthorization.authorize(
            plan: plan,
            associationID: associationID,
            verifiedBackupSHA256: backupSHA256,
            expectedPlanSHA256: plan.resultSHA256,
            consent: "I-reviewed-the-device-mapping-and-authorize-one-write"
        )
        #expect(authorization.associationID == associationID)
        #expect(authorization.resultSHA256 == plan.resultSHA256)

        #expect(throws: DeviceConfigurationWriteError.invalidAuthorization) {
            _ = try DeviceWriteAuthorization.authorize(
                plan: plan,
                associationID: associationID,
                verifiedBackupSHA256: backupSHA256,
                expectedPlanSHA256: plan.sourceSHA256,
                consent: "I-reviewed-the-device-mapping-and-authorize-one-write"
            )
        }
        #expect(throws: DeviceConfigurationWriteError.invalidAuthorization) {
            _ = try DeviceWriteAuthorization.authorize(
                plan: plan,
                associationID: associationID,
                verifiedBackupSHA256: backupSHA256,
                expectedPlanSHA256: plan.resultSHA256,
                consent: "yes"
            )
        }
    }

    @Test("Restore requires compatible original data and its verified checksum")
    func restoreIsBoundToBackup() throws {
        let original = try keymapDocument(valuePrefix: "stock")
        let managed = try original.planForCopilotMicro()
        let current = try DeviceKeymapDocument(
            data: managed.resultData,
            activeLayerIndex: original.activeLayerIndex
        )
        let restore = try DeviceConfigurationWritePlan.restore(
            current: current,
            originalData: original.data
        )
        let associationID = String(repeating: "a", count: 64)
        let authorization = try DeviceWriteAuthorization.authorize(
            plan: restore,
            associationID: associationID,
            verifiedBackupSHA256: original.sha256,
            expectedPlanSHA256: restore.resultSHA256,
            consent: "I-reviewed-the-original-backup-and-authorize-one-restore"
        )
        #expect(authorization.operation == .restoreOriginal)
        #expect(authorization.verifiedBackupSHA256 == original.sha256)

        #expect(throws: DeviceConfigurationWriteError.backupMismatch) {
            _ = try DeviceWriteAuthorization.authorize(
                plan: restore,
                associationID: associationID,
                verifiedBackupSHA256: String(repeating: "b", count: 64),
                expectedPlanSHA256: restore.resultSHA256,
                consent: "I-reviewed-the-original-backup-and-authorize-one-restore"
            )
        }
    }

    private func keymapDocument(valuePrefix: String) throws -> DeviceKeymapDocument {
        let rows = [
            ["\(valuePrefix)-0", "\(valuePrefix)-1"],
            (2...5).map { "\(valuePrefix)-\($0)" },
            (6...9).map { "\(valuePrefix)-\($0)" },
            (10...12).map { "\(valuePrefix)-\($0)" },
        ]
        let object: [String: Any] = [
            "version": 1,
            "activeProfileId": 0,
            "profiles": [
                [
                    "id": 0,
                    "layers": [
                        [
                            "layout": [
                                "keymap": rows,
                                "encoders": [
                                    ["CW", "CCW", "PRESS"]
                                ],
                                "joystick": [
                                    "type": "RADIAL",
                                    "sectors": [
                                        ["k": "N", "a1": 0.875, "a2": 0.125],
                                        ["k": "NE", "a1": 0.125, "a2": 0.25],
                                        ["k": "E", "a1": 0.125, "a2": 0.375],
                                        ["k": "SE", "a1": 0.375, "a2": 0.5],
                                        ["k": "S", "a1": 0.375, "a2": 0.625],
                                        ["k": "SW", "a1": 0.625, "a2": 0.75],
                                        ["k": "W", "a1": 0.625, "a2": 0.875],
                                        ["k": "NW", "a1": 0.875, "a2": 1.0],
                                    ],
                                ],
                            ]
                        ]
                    ],
                ]
            ],
        ]
        return try DeviceKeymapDocument(
            data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            activeLayerIndex: 0
        )
    }
}
