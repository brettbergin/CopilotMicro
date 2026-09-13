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
            associationID: Self.associationID,
            verifiedBackupSHA256: backupSHA256,
            expectedTransactionSHA256: plan.transactionSHA256(
                associationID: Self.associationID,
                verifiedBackupSHA256: backupSHA256
            ),
            consent: "I-closed-other-device-configurators-and-authorize-one-write"
        )
        #expect(authorization.associationID == associationID)
        #expect(authorization.resultSHA256 == plan.resultSHA256)

        let legacyTransactionSHA256 = DeviceKeymapDocument.digest(
            Data(
                [
                    "copilot-micro-device-transaction-v1",
                    plan.operation.rawValue,
                    Self.associationID,
                    plan.sourceSHA256,
                    plan.resultSHA256,
                    backupSHA256,
                    String(plan.activeProfileID),
                    String(plan.activeLayerIndex),
                    String(plan.changeCount),
                    plan.changeManifestSHA256,
                ].joined(separator: "\n").utf8
            )
        )
        #expect(
            legacyTransactionSHA256
                != plan.transactionSHA256(
                    associationID: Self.associationID,
                    verifiedBackupSHA256: backupSHA256
                )
        )
        #expect(throws: DeviceConfigurationWriteError.invalidAuthorization) {
            _ = try DeviceWriteAuthorization.authorize(
                plan: plan,
                associationID: Self.associationID,
                verifiedBackupSHA256: backupSHA256,
                expectedTransactionSHA256: legacyTransactionSHA256,
                consent: "I-closed-other-device-configurators-and-authorize-one-write"
            )
        }
        #expect(throws: DeviceConfigurationWriteError.invalidAuthorization) {
            _ = try DeviceWriteAuthorization.authorize(
                plan: plan,
                associationID: Self.associationID,
                verifiedBackupSHA256: backupSHA256,
                expectedTransactionSHA256: plan.sourceSHA256,
                consent: "I-closed-other-device-configurators-and-authorize-one-write"
            )
        }
        #expect(throws: DeviceConfigurationWriteError.invalidAuthorization) {
            _ = try DeviceWriteAuthorization.authorize(
                plan: plan,
                associationID: Self.associationID,
                verifiedBackupSHA256: backupSHA256,
                expectedTransactionSHA256: plan.transactionSHA256(
                    associationID: Self.associationID,
                    verifiedBackupSHA256: backupSHA256
                ),
                consent: "yes"
            )
        }
    }

    @Test("Read-only HID access cannot apply configuration")
    func configurationRequiresConfigurationAccess() {
        #expect(!HIDAccessMode.sharedReadOnly.allowsConfiguration)
        #expect(HIDAccessMode.sharedConfiguration.allowsConfiguration)
        #expect(HIDAccessMode.exclusiveConfiguration.allowsConfiguration)
    }

    @Test("Competing traffic detected before write leaves the device untouched")
    func competingTrafficBlocksWrite() throws {
        let preview = try keymapDocument(valuePrefix: "preview")
        let plan = try DeviceConfigurationWritePlan(
            managedMapping: preview.planForCopilotMicro()
        )
        let authorization = try authorize(plan: plan, backupSHA256: preview.sha256)
        var writeCount = 0

        #expect(throws: DeviceConfigurationWriteError.competingTrafficDetected) {
            _ = try DeviceConfigurationExecutor.apply(
                plan: plan,
                authorization: authorization,
                associationID: Self.associationID,
                readKeymap: { Self.rpcResult(preview.data) },
                writeKeymap: { _ in
                    writeCount += 1
                    return ["ok": 1]
                },
                preWriteCheck: {
                    throw DeviceConfigurationWriteError.competingTrafficDetected
                }
            )
        }
        #expect(writeCount == 0)
    }

    @Test("A reviewed transaction cannot authorize a different source or device")
    func transactionDigestBindsCompleteContext() throws {
        let reviewedSource = try keymapDocument(valuePrefix: "reviewed")
        let reviewedPlan = try DeviceConfigurationWritePlan(
            managedMapping: reviewedSource.planForCopilotMicro()
        )
        let backupSHA256 = reviewedSource.sha256
        let reviewedTransaction = reviewedPlan.transactionSHA256(
            associationID: Self.associationID,
            verifiedBackupSHA256: backupSHA256
        )

        let changedSource = try keymapDocument(valuePrefix: "changed")
        let changedPlan = try DeviceConfigurationWritePlan(
            managedMapping: changedSource.planForCopilotMicro()
        )
        #expect(changedPlan.resultSHA256 == reviewedPlan.resultSHA256)
        #expect(changedPlan.sourceSHA256 != reviewedPlan.sourceSHA256)
        #expect(throws: DeviceConfigurationWriteError.invalidAuthorization) {
            _ = try DeviceWriteAuthorization.authorize(
                plan: changedPlan,
                associationID: Self.associationID,
                verifiedBackupSHA256: backupSHA256,
                expectedTransactionSHA256: reviewedTransaction,
                consent: "I-closed-other-device-configurators-and-authorize-one-write"
            )
        }
        #expect(
            reviewedTransaction
                != reviewedPlan.transactionSHA256(
                    associationID: String(repeating: "b", count: 64),
                    verifiedBackupSHA256: backupSHA256
                )
        )
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
            expectedTransactionSHA256: restore.transactionSHA256(
                associationID: associationID,
                verifiedBackupSHA256: original.sha256
            ),
            consent: "I-closed-other-device-configurators-and-authorize-one-restore"
        )
        #expect(authorization.operation == .restoreOriginal)
        #expect(authorization.verifiedBackupSHA256 == original.sha256)

        #expect(throws: DeviceConfigurationWriteError.backupMismatch) {
            _ = try DeviceWriteAuthorization.authorize(
                plan: restore,
                associationID: associationID,
                verifiedBackupSHA256: String(repeating: "b", count: 64),
                expectedTransactionSHA256: restore.transactionSHA256(
                    associationID: associationID,
                    verifiedBackupSHA256: String(repeating: "b", count: 64)
                ),
                consent: "I-closed-other-device-configurators-and-authorize-one-restore"
            )
        }
    }

    @Test("Executor rejects stale state before writing")
    func staleStateDoesNotWrite() throws {
        let preview = try keymapDocument(valuePrefix: "preview")
        let plan = try DeviceConfigurationWritePlan(
            managedMapping: preview.planForCopilotMicro()
        )
        let authorization = try authorize(plan: plan, backupSHA256: preview.sha256)
        let changed = try keymapDocument(valuePrefix: "changed")
        var writeCount = 0

        #expect(throws: DeviceConfigurationWriteError.stalePlan) {
            _ = try DeviceConfigurationExecutor.apply(
                plan: plan,
                authorization: authorization,
                associationID: Self.associationID,
                readKeymap: { Self.rpcResult(changed.data) },
                writeKeymap: { _ in
                    writeCount += 1
                    return ["ok": 1]
                }
            )
        }
        #expect(writeCount == 0)
    }

    @Test("Executor requires read-back rather than trusting acknowledgement")
    func acknowledgementIsNotVerification() throws {
        let preview = try keymapDocument(valuePrefix: "preview")
        let plan = try DeviceConfigurationWritePlan(
            managedMapping: preview.planForCopilotMicro()
        )
        let authorization = try authorize(plan: plan, backupSHA256: preview.sha256)
        var reads = 0

        #expect(throws: DeviceConfigurationWriteError.readBackMismatch) {
            _ = try DeviceConfigurationExecutor.apply(
                plan: plan,
                authorization: authorization,
                associationID: Self.associationID,
                readKeymap: {
                    defer { reads += 1 }
                    return Self.rpcResult(preview.data)
                },
                writeKeymap: { _ in ["ok": 1] }
            )
        }
        #expect(reads == 2)
    }

    @Test("Executor verifies a successful semantic read-back")
    func verifiedWriteReturnsReceipt() throws {
        let preview = try keymapDocument(valuePrefix: "preview")
        let plan = try DeviceConfigurationWritePlan(
            managedMapping: preview.planForCopilotMicro()
        )
        let authorization = try authorize(plan: plan, backupSHA256: preview.sha256)
        var reads = 0
        let receipt = try DeviceConfigurationExecutor.apply(
            plan: plan,
            authorization: authorization,
            associationID: Self.associationID,
            readKeymap: {
                defer { reads += 1 }
                return Self.rpcResult(reads == 0 ? preview.data : plan.resultData)
            },
            writeKeymap: { data in
                #expect(data == plan.resultData)
                return ["ok": 1]
            }
        )
        #expect(receipt.readBackVerified)
        #expect(receipt.expectedResultSHA256 == plan.resultSHA256)
        #expect(receipt.observedResultSHA256 == plan.resultSHA256)
        #expect(receipt.activeProfileID == plan.activeProfileID)
        #expect(receipt.activeLayerIndex == plan.activeLayerIndex)
        #expect(!receipt.competingTrafficObservedAfterWrite)
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

    private func authorize(
        plan: DeviceConfigurationWritePlan,
        backupSHA256: String
    ) throws -> DeviceWriteAuthorization {
        try DeviceWriteAuthorization.authorize(
            plan: plan,
            associationID: Self.associationID,
            verifiedBackupSHA256: backupSHA256,
            expectedTransactionSHA256: plan.transactionSHA256(
                associationID: Self.associationID,
                verifiedBackupSHA256: backupSHA256
            ),
            consent: "I-closed-other-device-configurators-and-authorize-one-write"
        )
    }

    private static func rpcResult(_ data: Data) -> [String: Any] {
        ["data": String(decoding: data, as: UTF8.self)]
    }

    private static let associationID = String(repeating: "a", count: 64)
}
