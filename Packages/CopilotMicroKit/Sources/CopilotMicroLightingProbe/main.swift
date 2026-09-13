import CopilotMicroCore
import CopilotMicroDevice
import Foundation

private enum LightingProbeError: Error, LocalizedError {
    case deviceNotFound
    case invalidArguments
    case mappingNotApplied
    case multipleDevices

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            "No qualified Creator Micro 2 candidate is currently visible."
        case .invalidArguments:
            "Use exact lighting consent and a hold duration from 1 through 10 seconds."
        case .mappingNotApplied:
            "The active keymap is not fully mapped to AG00 through AG14."
        case .multipleDevices:
            "Multiple qualified Creator Micro 2 candidates are visible."
        }
    }
}

private struct LightingProbeOptions {
    let holdSeconds: Int

    init(arguments: [String]) throws {
        let consent =
            arguments.dropFirst()
            .first(where: { $0.hasPrefix("--consent=") })?
            .replacingOccurrences(of: "--consent=", with: "") ?? ""
        guard
            consent
                == "I-closed-other-device-configurators-and-authorize-key-lighting-test"
        else {
            throw LightingProbeError.invalidArguments
        }
        let holdText =
            arguments.dropFirst()
            .first(where: { $0.hasPrefix("--hold-seconds=") })?
            .replacingOccurrences(of: "--hold-seconds=", with: "") ?? "2"
        guard let holdSeconds = Int(holdText), (1...10).contains(holdSeconds) else {
            throw LightingProbeError.invalidArguments
        }
        self.holdSeconds = holdSeconds
    }
}

private struct LightingProbeEvent: Encodable {
    let schemaVersion = 1
    let outcome: String
    let step: Int
    let color: String
    let brightness: Double
    let acknowledged: Bool
    let ambientModified = false
    let flashWritePerformed = false
}

private struct LightingProbeFailure: Encodable {
    let schemaVersion = 1
    let outcome = "failed"
    let message: String
    let ambientModified = false
    let flashWritePerformed = false
}

@main
@MainActor
private struct CopilotMicroLightingProbe {
    static func main() async {
        do {
            let options = try LightingProbeOptions(arguments: CommandLine.arguments)
            let descriptors = try HIDDeviceDiscovery.discover()
                .filter { $0.qualification == .supportedCandidate }
            guard !descriptors.isEmpty else {
                throw LightingProbeError.deviceNotFound
            }
            guard descriptors.count == 1, let descriptor = descriptors.first else {
                throw LightingProbeError.multipleDevices
            }
            try DeviceConfiguratorGuard.requireNoKnownConfiguratorRunning()
            let connection = try HIDRPCConnection.connect(
                to: descriptor.registryID,
                accessMode: .sharedConfiguration
            )
            var lightingApplied = false
            defer {
                if lightingApplied {
                    _ = try? connection.setKeyLighting(DeviceKeyLighting.allThreadsOff())
                }
                connection.close()
            }
            let status = try DeviceSnapshotParser.status(
                from: connection.read(.deviceStatus)
            )
            let keymap = try DeviceKeymapDocument(
                rpcResult: connection.read(.keymap),
                activeLayerIndex: status.activeLayerIndex
            )
            guard try keymap.planForCopilotMicro().changeCount == 0 else {
                throw LightingProbeError.mappingNotApplied
            }

            let sequence: [(String, LightingColor)] = [
                ("white", .white),
                ("blue", .blue),
                ("purple", .purple),
                ("amber", .amber),
                ("green", .green),
                ("red", .red),
            ]
            for (index, item) in sequence.enumerated() {
                let receipt = try connection.setKeyLighting(
                    try DeviceKeyLighting.allVisibleKeys(
                        color: DeviceRGBColor(item.1),
                        brightness: 0.35
                    )
                )
                lightingApplied = true
                emit(
                    LightingProbeEvent(
                        outcome: "displaying",
                        step: index + 1,
                        color: item.0,
                        brightness: 0.35,
                        acknowledged: receipt.acknowledged
                    )
                )
                try await Task.sleep(for: .seconds(options.holdSeconds))
            }
            let receipt = try connection.setKeyLighting(DeviceKeyLighting.allThreadsOff())
            lightingApplied = false
            emit(
                LightingProbeEvent(
                    outcome: "complete",
                    step: sequence.count + 1,
                    color: "off",
                    brightness: 0,
                    acknowledged: receipt.acknowledged
                )
            )
        } catch {
            emit(
                LightingProbeFailure(
                    message: (error as? LocalizedError)?.errorDescription
                        ?? "Lighting qualification failed."
                )
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func emit(_ value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            FileHandle.standardOutput.write(try encoder.encode(value))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(
                Data("{\"outcome\":\"failed\",\"message\":\"encoding failed\"}\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }
}
