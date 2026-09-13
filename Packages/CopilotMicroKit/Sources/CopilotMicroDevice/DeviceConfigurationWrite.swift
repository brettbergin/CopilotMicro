import CryptoKit
import Foundation

public enum DeviceWriteOperation: String, Codable, Sendable {
    case managedMapping
    case restoreOriginal

    public var consent: String {
        switch self {
        case .managedMapping:
            "I-closed-other-device-configurators-and-authorize-one-write"
        case .restoreOriginal:
            "I-closed-other-device-configurators-and-authorize-one-restore"
        }
    }
}

public enum DeviceConfigurationWriteError: Error, Equatable, LocalizedError, Sendable {
    case authorizationMismatch
    case backupMismatch
    case competingTrafficDetected
    case configurationAccessRequired
    case invalidAuthorization
    case noChanges
    case readBackMismatch
    case stalePlan
    case unsupportedRestore
    case writeRejected

    public var errorDescription: String? {
        switch self {
        case .authorizationMismatch:
            "The device write authorization does not match this device and plan."
        case .backupMismatch:
            "The verified backup does not match the requested restore."
        case .competingTrafficDetected:
            "Another client exchanged device RPC traffic during the configuration transaction."
        case .configurationAccessRequired:
            "Device configuration writes require the guarded configuration connection."
        case .invalidAuthorization:
            "The exact one-write consent and plan digest are required."
        case .noChanges:
            "The device configuration already matches the requested state."
        case .readBackMismatch:
            "The device acknowledged the write but read-back did not match."
        case .stalePlan:
            "The device configuration changed after preview. Review a new plan."
        case .unsupportedRestore:
            "The original backup is not compatible with the current keymap schema."
        case .writeRejected:
            "The device did not acknowledge the configuration write."
        }
    }
}

public struct DeviceConfigurationWritePlan: Equatable, Sendable {
    public let operation: DeviceWriteOperation
    public let activeProfileID: Int
    public let activeLayerIndex: Int
    public let sourceSHA256: String
    public let resultSHA256: String
    public let changeManifestSHA256: String
    public let resultData: Data
    public let changeCount: Int

    public init(managedMapping plan: DeviceKeymapPlan) throws {
        guard plan.changeCount > 0 else {
            throw DeviceConfigurationWriteError.noChanges
        }
        operation = .managedMapping
        activeProfileID = plan.activeProfileID
        activeLayerIndex = plan.activeLayerIndex
        sourceSHA256 = plan.sourceSHA256
        resultSHA256 = plan.resultSHA256
        changeManifestSHA256 = try Self.managedChangeManifestSHA256(plan)
        resultData = plan.resultData
        changeCount = plan.changeCount
    }

    public static func restore(
        current: DeviceKeymapDocument,
        originalData: Data
    ) throws -> DeviceConfigurationWritePlan {
        let original: DeviceKeymapDocument
        do {
            original = try DeviceKeymapDocument(
                data: originalData,
                activeLayerIndex: current.activeLayerIndex
            )
        } catch {
            throw DeviceConfigurationWriteError.unsupportedRestore
        }
        guard original.schemaVersion == current.schemaVersion else {
            throw DeviceConfigurationWriteError.unsupportedRestore
        }
        guard !current.isSemanticallyEqual(to: originalData) else {
            throw DeviceConfigurationWriteError.noChanges
        }
        return DeviceConfigurationWritePlan(
            operation: .restoreOriginal,
            activeProfileID: original.activeProfileID,
            activeLayerIndex: current.activeLayerIndex,
            sourceSHA256: current.sha256,
            resultSHA256: original.sha256,
            changeManifestSHA256: DeviceKeymapDocument.digest(
                Data("complete-keymap-restore".utf8)
            ),
            resultData: originalData,
            changeCount: 1
        )
    }

    private init(
        operation: DeviceWriteOperation,
        activeProfileID: Int,
        activeLayerIndex: Int,
        sourceSHA256: String,
        resultSHA256: String,
        changeManifestSHA256: String,
        resultData: Data,
        changeCount: Int
    ) {
        self.operation = operation
        self.activeProfileID = activeProfileID
        self.activeLayerIndex = activeLayerIndex
        self.sourceSHA256 = sourceSHA256
        self.resultSHA256 = resultSHA256
        self.changeManifestSHA256 = changeManifestSHA256
        self.resultData = resultData
        self.changeCount = changeCount
    }

    public func transactionSHA256(
        associationID: String,
        verifiedBackupSHA256: String
    ) -> String {
        let fields = [
            "copilot-micro-device-transaction-v2",
            operation.rawValue,
            associationID,
            sourceSHA256,
            resultSHA256,
            verifiedBackupSHA256,
            String(activeProfileID),
            String(activeLayerIndex),
            String(changeCount),
            changeManifestSHA256,
        ]
        return DeviceKeymapDocument.digest(Data(fields.joined(separator: "\n").utf8))
    }

    private struct ChangeManifestEntry: Encodable {
        let location: String
        let previousValue: String
        let replacementValue: String
    }

    private static func managedChangeManifestSHA256(_ plan: DeviceKeymapPlan) throws -> String {
        var entries = plan.keyChanges.map {
            ChangeManifestEntry(
                location: "key:\($0.contact):\($0.coordinate.row):\($0.coordinate.column)",
                previousValue: $0.previousValue,
                replacementValue: $0.replacementValue
            )
        }
        entries += plan.peripheralChanges.map {
            ChangeManifestEntry(
                location: $0.location,
                previousValue: $0.previousValue,
                replacementValue: $0.replacementValue
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(entries)
        return DeviceKeymapDocument.digest(data)
    }
}

public struct DeviceWriteAuthorization: Equatable, Sendable {
    public let operation: DeviceWriteOperation
    public let associationID: String
    public let sourceSHA256: String
    public let resultSHA256: String
    public let verifiedBackupSHA256: String
    public let transactionSHA256: String

    public static func authorize(
        plan: DeviceConfigurationWritePlan,
        associationID: String,
        verifiedBackupSHA256: String,
        expectedTransactionSHA256: String,
        consent: String
    ) throws -> DeviceWriteAuthorization {
        let transactionSHA256 = plan.transactionSHA256(
            associationID: associationID,
            verifiedBackupSHA256: verifiedBackupSHA256
        )
        guard
            isDigest(associationID),
            isDigest(verifiedBackupSHA256),
            expectedTransactionSHA256 == transactionSHA256,
            consent == plan.operation.consent
        else {
            throw DeviceConfigurationWriteError.invalidAuthorization
        }
        if plan.operation == .restoreOriginal {
            guard plan.resultSHA256 == verifiedBackupSHA256 else {
                throw DeviceConfigurationWriteError.backupMismatch
            }
        }
        return DeviceWriteAuthorization(
            operation: plan.operation,
            associationID: associationID,
            sourceSHA256: plan.sourceSHA256,
            resultSHA256: plan.resultSHA256,
            verifiedBackupSHA256: verifiedBackupSHA256,
            transactionSHA256: transactionSHA256
        )
    }

    private init(
        operation: DeviceWriteOperation,
        associationID: String,
        sourceSHA256: String,
        resultSHA256: String,
        verifiedBackupSHA256: String,
        transactionSHA256: String
    ) {
        self.operation = operation
        self.associationID = associationID
        self.sourceSHA256 = sourceSHA256
        self.resultSHA256 = resultSHA256
        self.verifiedBackupSHA256 = verifiedBackupSHA256
        self.transactionSHA256 = transactionSHA256
    }

    private static func isDigest(_ value: String) -> Bool {
        value.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
    }
}

public struct DeviceWriteReceipt: Codable, Equatable, Sendable {
    public let operation: DeviceWriteOperation
    public let sourceSHA256: String
    public let expectedResultSHA256: String
    public let observedResultSHA256: String
    public let activeProfileID: Int
    public let activeLayerIndex: Int
    public let readBackVerified: Bool
    public let competingTrafficObservedAfterWrite: Bool

    func recordingCompetingTrafficAfterWrite(_ observed: Bool) -> DeviceWriteReceipt {
        DeviceWriteReceipt(
            operation: operation,
            sourceSHA256: sourceSHA256,
            expectedResultSHA256: expectedResultSHA256,
            observedResultSHA256: observedResultSHA256,
            activeProfileID: activeProfileID,
            activeLayerIndex: activeLayerIndex,
            readBackVerified: readBackVerified,
            competingTrafficObservedAfterWrite: observed
        )
    }
}

enum DeviceConfigurationExecutor {
    static func apply(
        plan: DeviceConfigurationWritePlan,
        authorization: DeviceWriteAuthorization,
        associationID: String?,
        readKeymap: () throws -> Any?,
        writeKeymap: (Data) throws -> Any?,
        preWriteCheck: () throws -> Void = {}
    ) throws -> DeviceWriteReceipt {
        guard
            associationID == authorization.associationID,
            plan.operation == authorization.operation,
            plan.sourceSHA256 == authorization.sourceSHA256,
            plan.resultSHA256 == authorization.resultSHA256,
            plan.transactionSHA256(
                associationID: authorization.associationID,
                verifiedBackupSHA256: authorization.verifiedBackupSHA256
            ) == authorization.transactionSHA256
        else {
            throw DeviceConfigurationWriteError.authorizationMismatch
        }
        let current = try DeviceKeymapDocument(
            rpcResult: readKeymap(),
            activeLayerIndex: plan.activeLayerIndex
        )
        guard current.sha256 == plan.sourceSHA256 else {
            throw DeviceConfigurationWriteError.stalePlan
        }
        try preWriteCheck()
        let response = try writeKeymap(plan.resultData)
        guard
            let object = response as? [String: Any],
            HIDJSONNumber.integer(object["ok"]) == 1
        else {
            throw DeviceConfigurationWriteError.writeRejected
        }
        let readBack = try DeviceKeymapDocument(
            rpcResult: readKeymap(),
            activeLayerIndex: plan.activeLayerIndex
        )
        guard
            readBack.sha256 == plan.resultSHA256
                || readBack.isSemanticallyEqual(to: plan.resultData)
        else {
            throw DeviceConfigurationWriteError.readBackMismatch
        }
        return DeviceWriteReceipt(
            operation: plan.operation,
            sourceSHA256: plan.sourceSHA256,
            expectedResultSHA256: plan.resultSHA256,
            observedResultSHA256: readBack.sha256,
            activeProfileID: readBack.activeProfileID,
            activeLayerIndex: readBack.activeLayerIndex,
            readBackVerified: true,
            competingTrafficObservedAfterWrite: false
        )
    }
}
