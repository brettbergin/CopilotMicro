import AppKit
import CopilotMicroDevice
import CopilotMicroStorage
import Foundation

private enum SetupCommand: String {
    case apply
    case preview
    case previewRestore = "preview-restore"
    case restore
}

private enum SetupError: Error, LocalizedError {
    case associationUnavailable
    case deviceNotFound
    case invalidArguments
    case knownConfiguratorRunning(String)
    case multipleDevices
    case originalWouldBeManaged

    var errorDescription: String? {
        switch self {
        case .associationUnavailable:
            "The device has no stable private association identifier, so backup and restore are disabled."
        case .deviceNotFound:
            "No qualified Creator Micro 2 candidate is currently visible."
        case .invalidArguments:
            "The setup command or required consent arguments are invalid."
        case .knownConfiguratorRunning(let name):
            "Quit \(name) before configuring the device, then generate a fresh preview."
        case .multipleDevices:
            "Multiple qualified Creator Micro 2 candidates are visible."
        case .originalWouldBeManaged:
            "The current keymap already contains all managed bindings, but no original backup exists."
        }
    }
}

private struct SetupOptions {
    let command: SetupCommand
    let planSHA256: String?
    let consent: String

    init(arguments: [String]) throws {
        guard
            arguments.count >= 2,
            let command = SetupCommand(rawValue: arguments[1])
        else {
            throw SetupError.invalidArguments
        }
        self.command = command
        planSHA256 = arguments.dropFirst(2)
            .first(where: { $0.hasPrefix("--plan-sha=") })?
            .replacingOccurrences(of: "--plan-sha=", with: "")
        consent =
            arguments.dropFirst(2)
            .first(where: { $0.hasPrefix("--consent=") })?
            .replacingOccurrences(of: "--consent=", with: "") ?? ""
        switch command {
        case .preview, .previewRestore:
            guard consent == "I-own-this-device-read", planSHA256 == nil else {
                throw SetupError.invalidArguments
            }
        case .apply, .restore:
            guard
                let planSHA256,
                planSHA256.wholeMatch(of: /^[0-9a-f]{64}$/) != nil
            else {
                throw SetupError.invalidArguments
            }
        }
    }
}

private struct SetupChange: Encodable {
    let location: String
    let previousValue: String
    let replacementValue: String
}

private struct SetupReport: Encodable {
    let schemaVersion = 1
    let generatedAt = ISO8601DateFormatter().string(from: Date())
    let outcome: String
    let product: String
    let productID: String
    let transport: DeviceTransport
    let firmwareVersion: String
    let activeProfileID: Int
    let activeLayerIndex: Int
    let sourceSHA256: String
    let targetSHA256: String
    let transactionSHA256: String?
    let verifiedBackupSHA256: String
    let originalBackupCreated: Bool
    let changeCount: Int
    let changes: [SetupChange]
    let requiredConsent: String?
    let readBackVerified: Bool
    let competingTrafficObserved: Bool
    let mutatingOperationsPerformed: Bool
}

private struct SetupFailure: Encodable {
    let schemaVersion = 1
    let outcome = "failed"
    let errorCode: String
    let message: String
    let mutatingOperationsMayHaveOccurred: Bool
}

private struct DeviceContext {
    let descriptor: HIDDeviceDescriptor
    let connection: HIDRPCConnection
    let firmwareVersion: String
    let status: DeviceStatusSummary
    let keymap: DeviceKeymapDocument
    let associationID: String
}

@main
@MainActor
private struct CopilotMicroDeviceSetup {
    static func main() async {
        var mutatingOperationsMayHaveOccurred = false
        do {
            let options = try SetupOptions(arguments: CommandLine.arguments)
            mutatingOperationsMayHaveOccurred =
                options.command == .apply || options.command == .restore
            let accessMode: HIDAccessMode =
                options.command == .apply || options.command == .restore
                ? .sharedConfiguration
                : .sharedReadOnly
            if options.command == .apply || options.command == .restore {
                try rejectKnownConfigurators()
            }
            let context = try openDevice(accessMode: accessMode)
            defer { context.connection.close() }
            let store = DeviceBackupStore(rootURL: try DeviceBackupStore.defaultRootURL())
            switch options.command {
            case .preview:
                try await previewManagedMapping(context: context, store: store)
            case .apply:
                try await applyManagedMapping(
                    context: context,
                    store: store,
                    planSHA256: options.planSHA256,
                    consent: options.consent
                )
            case .previewRestore:
                try await previewRestore(context: context, store: store)
            case .restore:
                try await restore(
                    context: context,
                    store: store,
                    planSHA256: options.planSHA256,
                    consent: options.consent
                )
            }
        } catch {
            let message =
                (error as? LocalizedError)?.errorDescription
                ?? "Device setup failed."
            emit(
                SetupFailure(
                    errorCode: errorCode(error),
                    message: message,
                    mutatingOperationsMayHaveOccurred: mutatingOperationsMayHaveOccurred
                )
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func previewManagedMapping(
        context: DeviceContext,
        store: DeviceBackupStore
    ) async throws {
        let keymapPlan = try context.keymap.planForCopilotMicro()
        let original = try await originalBackup(
            context: context,
            store: store,
            allowCreation: keymapPlan.changeCount > 0
        )
        let backupSHA256 = DeviceKeymapDocument.digest(original.backup.keymap)
        let transactionSHA256: String?
        if keymapPlan.changeCount > 0 {
            transactionSHA256 = try DeviceConfigurationWritePlan(
                managedMapping: keymapPlan
            ).transactionSHA256(
                associationID: context.associationID,
                verifiedBackupSHA256: backupSHA256
            )
        } else {
            transactionSHA256 = nil
        }
        emit(
            report(
                outcome: keymapPlan.changeCount == 0 ? "already-managed" : "preview-ready",
                context: context,
                targetSHA256: keymapPlan.resultSHA256,
                transactionSHA256: transactionSHA256,
                backup: original.backup,
                backupCreated: original.created,
                keyChanges: keymapPlan.keyChanges,
                peripheralChanges: keymapPlan.peripheralChanges,
                requiredConsent: keymapPlan.changeCount == 0
                    ? nil
                    : DeviceWriteOperation.managedMapping.consent,
                readBackVerified: false,
                mutated: false
            )
        )
    }

    private static func applyManagedMapping(
        context: DeviceContext,
        store: DeviceBackupStore,
        planSHA256: String?,
        consent: String
    ) async throws {
        let backup = try await loadOriginal(context: context, store: store)
        let keymapPlan = try context.keymap.planForCopilotMicro()
        let plan = try DeviceConfigurationWritePlan(managedMapping: keymapPlan)
        let expectedTransactionSHA256 = try requirePlanSHA256(planSHA256)
        let authorization = try DeviceWriteAuthorization.authorize(
            plan: plan,
            associationID: context.associationID,
            verifiedBackupSHA256: DeviceKeymapDocument.digest(backup.keymap),
            expectedTransactionSHA256: expectedTransactionSHA256,
            consent: consent
        )
        try await saveFreshPreChange(context: context, store: store, plan: plan)
        let receipt = try context.connection.apply(
            plan,
            authorization: authorization,
            beforeWrite: rejectKnownConfigurators
        )
        emit(
            report(
                outcome: receipt.competingTrafficObservedAfterWrite
                    ? "applied-with-contention-warning"
                    : "applied",
                context: context,
                targetSHA256: plan.resultSHA256,
                transactionSHA256: authorization.transactionSHA256,
                backup: backup,
                backupCreated: false,
                keyChanges: keymapPlan.keyChanges,
                peripheralChanges: keymapPlan.peripheralChanges,
                requiredConsent: nil,
                activeProfileID: receipt.activeProfileID,
                activeLayerIndex: receipt.activeLayerIndex,
                readBackVerified: receipt.readBackVerified,
                competingTrafficObserved: receipt.competingTrafficObservedAfterWrite,
                mutated: true
            )
        )
    }

    private static func previewRestore(
        context: DeviceContext,
        store: DeviceBackupStore
    ) async throws {
        let backup = try await loadOriginal(context: context, store: store)
        let plan = try DeviceConfigurationWritePlan.restore(
            current: context.keymap,
            originalData: backup.keymap
        )
        let backupSHA256 = DeviceKeymapDocument.digest(backup.keymap)
        let transactionSHA256 = plan.transactionSHA256(
            associationID: context.associationID,
            verifiedBackupSHA256: backupSHA256
        )
        emit(
            report(
                outcome: "restore-preview-ready",
                context: context,
                targetSHA256: plan.resultSHA256,
                transactionSHA256: transactionSHA256,
                backup: backup,
                backupCreated: false,
                keyChanges: [],
                peripheralChanges: [
                    DevicePeripheralChange(
                        location: "complete-keymap",
                        previousValue: context.keymap.sha256,
                        replacementValue: plan.resultSHA256
                    )
                ],
                requiredConsent: DeviceWriteOperation.restoreOriginal.consent,
                readBackVerified: false,
                mutated: false
            )
        )
    }

    private static func restore(
        context: DeviceContext,
        store: DeviceBackupStore,
        planSHA256: String?,
        consent: String
    ) async throws {
        let backup = try await loadOriginal(context: context, store: store)
        let plan = try DeviceConfigurationWritePlan.restore(
            current: context.keymap,
            originalData: backup.keymap
        )
        let expectedTransactionSHA256 = try requirePlanSHA256(planSHA256)
        let backupSHA256 = DeviceKeymapDocument.digest(backup.keymap)
        let authorization = try DeviceWriteAuthorization.authorize(
            plan: plan,
            associationID: context.associationID,
            verifiedBackupSHA256: backupSHA256,
            expectedTransactionSHA256: expectedTransactionSHA256,
            consent: consent
        )
        try await saveFreshPreChange(context: context, store: store, plan: plan)
        let receipt = try context.connection.apply(
            plan,
            authorization: authorization,
            beforeWrite: rejectKnownConfigurators
        )
        emit(
            report(
                outcome: receipt.competingTrafficObservedAfterWrite
                    ? "restored-with-contention-warning"
                    : "restored",
                context: context,
                targetSHA256: plan.resultSHA256,
                transactionSHA256: authorization.transactionSHA256,
                backup: backup,
                backupCreated: false,
                keyChanges: [],
                peripheralChanges: [
                    DevicePeripheralChange(
                        location: "complete-keymap",
                        previousValue: context.keymap.sha256,
                        replacementValue: plan.resultSHA256
                    )
                ],
                requiredConsent: nil,
                activeProfileID: receipt.activeProfileID,
                activeLayerIndex: receipt.activeLayerIndex,
                readBackVerified: receipt.readBackVerified,
                competingTrafficObserved: receipt.competingTrafficObservedAfterWrite,
                mutated: true
            )
        )
    }

    private static func openDevice(accessMode: HIDAccessMode) throws -> DeviceContext {
        let candidates = try HIDDeviceDiscovery.discover()
            .filter { $0.qualification == .supportedCandidate }
        guard !candidates.isEmpty else {
            throw SetupError.deviceNotFound
        }
        guard candidates.count == 1, let descriptor = candidates.first else {
            throw SetupError.multipleDevices
        }
        guard let associationID = descriptor.associationID else {
            throw SetupError.associationUnavailable
        }
        let connection = try HIDRPCConnection.connect(
            to: descriptor.registryID,
            accessMode: accessMode
        )
        do {
            let firmwareVersion = try DeviceSnapshotParser.firmwareVersion(
                from: connection.read(.systemVersion)
            )
            let status = try DeviceSnapshotParser.status(
                from: connection.read(.deviceStatus)
            )
            let keymap = try DeviceKeymapDocument(
                rpcResult: connection.read(.keymap),
                activeLayerIndex: status.activeLayerIndex
            )
            return DeviceContext(
                descriptor: descriptor,
                connection: connection,
                firmwareVersion: firmwareVersion,
                status: status,
                keymap: keymap,
                associationID: associationID
            )
        } catch {
            connection.close()
            throw error
        }
    }

    private static func originalBackup(
        context: DeviceContext,
        store: DeviceBackupStore,
        allowCreation: Bool
    ) async throws -> (backup: DeviceBackup, created: Bool) {
        do {
            return (try await loadOriginal(context: context, store: store), false)
        } catch DeviceBackupError.missingOriginalBackup {
            guard allowCreation else {
                throw SetupError.originalWouldBeManaged
            }
            let metadata = try backupMetadata(context: context)
            do {
                return (
                    try await store.saveOriginal(context.keymap.data, metadata: metadata),
                    true
                )
            } catch DeviceBackupError.originalBackupAlreadyExists {
                return (try await loadOriginal(context: context, store: store), false)
            }
        }
    }

    private static func loadOriginal(
        context: DeviceContext,
        store: DeviceBackupStore
    ) async throws -> DeviceBackup {
        try await store.loadOriginal(
            matching: DeviceBackupMatch(
                deviceAssociationID: context.associationID,
                productID: context.descriptor.productID,
                keymapSchemaVersion: context.keymap.schemaVersion
            )
        )
    }

    private static func saveFreshPreChange(
        context: DeviceContext,
        store: DeviceBackupStore,
        plan: DeviceConfigurationWritePlan
    ) async throws {
        let current = try DeviceKeymapDocument(
            rpcResult: context.connection.read(.keymap),
            activeLayerIndex: plan.activeLayerIndex
        )
        guard current.sha256 == plan.sourceSHA256 else {
            throw DeviceConfigurationWriteError.stalePlan
        }
        _ = try await store.savePreChangeSnapshot(
            current.data,
            metadata: DeviceBackupMetadata(
                deviceAssociationID: context.associationID,
                productID: context.descriptor.productID,
                firmwareVersion: context.firmwareVersion,
                keymapSchemaVersion: current.schemaVersion
            )
        )
    }

    private static func rejectKnownConfigurators() throws {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != currentProcessID && !$0.isTerminated
        }
        if let application = running.first(where: {
            let name = $0.localizedName?.lowercased() ?? ""
            let bundleIdentifier = $0.bundleIdentifier?.lowercased() ?? ""
            return name == "input"
                || name == "work louder input"
                || bundleIdentifier.contains("worklouder")
        }) {
            throw SetupError.knownConfiguratorRunning(
                application.localizedName ?? "Work Louder Input"
            )
        }
    }

    private static func backupMetadata(context: DeviceContext) throws -> DeviceBackupMetadata {
        try DeviceBackupMetadata(
            deviceAssociationID: context.associationID,
            productID: context.descriptor.productID,
            firmwareVersion: context.firmwareVersion,
            keymapSchemaVersion: context.keymap.schemaVersion
        )
    }

    private static func report(
        outcome: String,
        context: DeviceContext,
        targetSHA256: String,
        transactionSHA256: String?,
        backup: DeviceBackup,
        backupCreated: Bool,
        keyChanges: [DeviceKeymapChange],
        peripheralChanges: [DevicePeripheralChange],
        requiredConsent: String?,
        activeProfileID: Int? = nil,
        activeLayerIndex: Int? = nil,
        readBackVerified: Bool,
        competingTrafficObserved: Bool = false,
        mutated: Bool
    ) -> SetupReport {
        let keyChangeReports = keyChanges.map {
            SetupChange(
                location: "key[\($0.coordinate.row)][\($0.coordinate.column)] contact \($0.contact)",
                previousValue: $0.previousValue,
                replacementValue: $0.replacementValue
            )
        }
        let peripheralChangeReports = peripheralChanges.map {
            SetupChange(
                location: $0.location,
                previousValue: $0.previousValue,
                replacementValue: $0.replacementValue
            )
        }
        return SetupReport(
            outcome: outcome,
            product: context.descriptor.product,
            productID: String(format: "0x%04X", context.descriptor.productID),
            transport: context.descriptor.transport,
            firmwareVersion: context.firmwareVersion,
            activeProfileID: activeProfileID ?? context.keymap.activeProfileID,
            activeLayerIndex: activeLayerIndex ?? context.keymap.activeLayerIndex,
            sourceSHA256: context.keymap.sha256,
            targetSHA256: targetSHA256,
            transactionSHA256: transactionSHA256,
            verifiedBackupSHA256: DeviceKeymapDocument.digest(backup.keymap),
            originalBackupCreated: backupCreated,
            changeCount: keyChangeReports.count + peripheralChangeReports.count,
            changes: keyChangeReports + peripheralChangeReports,
            requiredConsent: requiredConsent,
            readBackVerified: readBackVerified,
            competingTrafficObserved: competingTrafficObserved,
            mutatingOperationsPerformed: mutated
        )
    }

    private static func requirePlanSHA256(_ value: String?) throws -> String {
        guard let value else {
            throw SetupError.invalidArguments
        }
        return value
    }

    private static func errorCode(_ error: Error) -> String {
        switch error {
        case HIDConnectionError.configuration:
            "write_guard_failed"
        case is SetupError:
            "setup_invalid"
        case is DeviceBackupError:
            "backup_invalid"
        case is DeviceConfigurationWriteError:
            "write_guard_failed"
        case is HIDConnectionError:
            "hardware_failed"
        case is DeviceKeymapDocumentError:
            "keymap_invalid"
        default:
            "device_setup_failed"
        }
    }

    private static func emit(_ value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            FileHandle.standardOutput.write(try encoder.encode(value))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(
                Data("{\"outcome\":\"failed\",\"errorCode\":\"encoding_failed\"}\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }
}
