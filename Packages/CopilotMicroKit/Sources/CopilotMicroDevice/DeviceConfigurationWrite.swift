import Foundation

public enum DeviceWriteOperation: String, Codable, Sendable {
    case managedMapping
    case restoreOriginal

    var consent: String {
        switch self {
        case .managedMapping:
            "I-reviewed-the-device-mapping-and-authorize-one-write"
        case .restoreOriginal:
            "I-reviewed-the-original-backup-and-authorize-one-restore"
        }
    }
}

public enum DeviceConfigurationWriteError: Error, Equatable, LocalizedError, Sendable {
    case authorizationMismatch
    case backupMismatch
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
    public let activeLayerIndex: Int
    public let sourceSHA256: String
    public let resultSHA256: String
    public let resultData: Data
    public let changeCount: Int

    public init(managedMapping plan: DeviceKeymapPlan) throws {
        guard plan.changeCount > 0 else {
            throw DeviceConfigurationWriteError.noChanges
        }
        operation = .managedMapping
        activeLayerIndex = plan.activeLayerIndex
        sourceSHA256 = plan.sourceSHA256
        resultSHA256 = plan.resultSHA256
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
            activeLayerIndex: current.activeLayerIndex,
            sourceSHA256: current.sha256,
            resultSHA256: original.sha256,
            resultData: originalData,
            changeCount: 1
        )
    }

    private init(
        operation: DeviceWriteOperation,
        activeLayerIndex: Int,
        sourceSHA256: String,
        resultSHA256: String,
        resultData: Data,
        changeCount: Int
    ) {
        self.operation = operation
        self.activeLayerIndex = activeLayerIndex
        self.sourceSHA256 = sourceSHA256
        self.resultSHA256 = resultSHA256
        self.resultData = resultData
        self.changeCount = changeCount
    }
}

public struct DeviceWriteAuthorization: Equatable, Sendable {
    public let operation: DeviceWriteOperation
    public let associationID: String
    public let sourceSHA256: String
    public let resultSHA256: String
    public let verifiedBackupSHA256: String

    public static func authorize(
        plan: DeviceConfigurationWritePlan,
        associationID: String,
        verifiedBackupSHA256: String,
        expectedPlanSHA256: String,
        consent: String
    ) throws -> DeviceWriteAuthorization {
        guard
            isDigest(associationID),
            isDigest(verifiedBackupSHA256),
            expectedPlanSHA256 == plan.resultSHA256,
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
            verifiedBackupSHA256: verifiedBackupSHA256
        )
    }

    private init(
        operation: DeviceWriteOperation,
        associationID: String,
        sourceSHA256: String,
        resultSHA256: String,
        verifiedBackupSHA256: String
    ) {
        self.operation = operation
        self.associationID = associationID
        self.sourceSHA256 = sourceSHA256
        self.resultSHA256 = resultSHA256
        self.verifiedBackupSHA256 = verifiedBackupSHA256
    }

    private static func isDigest(_ value: String) -> Bool {
        value.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
    }
}

public struct DeviceWriteReceipt: Codable, Equatable, Sendable {
    public let operation: DeviceWriteOperation
    public let sourceSHA256: String
    public let resultSHA256: String
    public let readBackVerified: Bool
}
