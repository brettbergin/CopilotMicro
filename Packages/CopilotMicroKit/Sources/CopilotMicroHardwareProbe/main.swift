import CopilotMicroDevice
import Foundation

private struct ProbeFailure: Encodable {
    let schemaVersion = 1
    let outcome = "failed"
    let errorCode: String
    let message: String
    let recovery: String?
}

@main
@MainActor
private struct CopilotMicroHardwareProbe {
    static func main() {
        do {
            let descriptors = try HIDDeviceDiscovery.discover()
            let candidates = descriptors.filter { $0.qualification == .supportedCandidate }
            guard !candidates.isEmpty else {
                emitFailure(
                    code: "device_not_found",
                    message: "No qualified Creator Micro 2 candidate is currently visible.",
                    recovery: "Connect or wake the device, then retry."
                )
            }
            guard candidates.count == 1, let candidate = candidates.first else {
                emitFailure(
                    code: "multiple_candidates",
                    message: "Multiple qualified Creator Micro 2 candidates are visible.",
                    recovery: "Disconnect all but the device being qualified."
                )
            }
            let connection = try HIDRPCConnection.connect(to: candidate.registryID)
            defer { connection.close() }
            let firmware = try DeviceSnapshotParser.firmwareVersion(
                from: connection.read(.systemVersion)
            )
            let status = try DeviceSnapshotParser.status(
                from: connection.read(.deviceStatus)
            )
            let keymap = try DeviceSnapshotParser.keymap(
                from: connection.read(.keymap),
                activeLayerIndex: status.activeLayerIndex
            )
            let evidence = HardwareCapabilityEvidence(
                product: candidate.product,
                productID: String(format: "0x%04X", candidate.productID),
                transport: candidate.transport,
                inputReportBytes: candidate.maximumInputReportBytes,
                outputReportBytes: candidate.maximumOutputReportBytes,
                serialPresent: candidate.serialPresent,
                firmwareVersion: firmware,
                status: status,
                keymap: keymap,
                unexpectedResponseCount: connection.unexpectedResponseCount,
                notificationCount: connection.notificationCount
            )
            try evidence.validate()
            emit(evidence)
        } catch {
            let message =
                (error as? LocalizedError)?.errorDescription
                ?? "Read-only hardware qualification failed."
            let needsInputMonitoring =
                message.localizedCaseInsensitiveContains("Input Monitoring")
            emitFailure(
                code: needsInputMonitoring ? "input_monitoring_required" : "hardware_probe_failed",
                message: message,
                recovery: needsInputMonitoring
                    ? "Grant Input Monitoring to the terminal running this command, wake the device, and retry."
                    : nil
            )
        }
    }

    private static func emitFailure(code: String, message: String, recovery: String?) -> Never {
        emit(
            ProbeFailure(
                errorCode: code,
                message: message,
                recovery: recovery
            )
        )
        exit(EXIT_FAILURE)
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
