import CopilotMicroDevice
import CoreFoundation
import Foundation

private enum ObserverError: Error, LocalizedError {
    case deviceNotFound
    case inputMonitoringRequired(HIDListenAccessStatus)
    case invalidArguments
    case mappingNotApplied
    case multipleDevices

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            "No qualified Creator Micro 2 candidate is currently visible."
        case .inputMonitoringRequired(let status):
            "Input Monitoring access is \(status.rawValue). Grant it to the observer app before capturing hardware events."
        case .invalidArguments:
            "Use exact input-observer consent and a duration from 1 through 300 seconds."
        case .mappingNotApplied:
            "The active keymap is not fully mapped to AG00 through AG14."
        case .multipleDevices:
            "Multiple qualified Creator Micro 2 candidates are visible."
        }
    }
}

private struct ObserverOptions {
    let durationSeconds: Int

    init(arguments: [String]) throws {
        let consent =
            arguments.dropFirst()
            .first(where: { $0.hasPrefix("--consent=") })?
            .replacingOccurrences(of: "--consent=", with: "") ?? ""
        guard consent == "I-own-this-device-observe-input" else {
            throw ObserverError.invalidArguments
        }
        let durationText =
            arguments.dropFirst()
            .first(where: { $0.hasPrefix("--seconds=") })?
            .replacingOccurrences(of: "--seconds=", with: "") ?? "30"
        guard let durationSeconds = Int(durationText), (1...300).contains(durationSeconds) else {
            throw ObserverError.invalidArguments
        }
        self.durationSeconds = durationSeconds
    }
}

private struct ObserverStatus: Encodable {
    let schemaVersion = 1
    let outcome: String
    let product: String
    let productID: String
    let transport: DeviceTransport
    let inputMonitoring: HIDListenAccessStatus
    let firmwareVersion: String
    let activeLayerIndex: Int
    let keymapSHA256: String
    let durationSeconds: Int
    let observedEventCount: Int
    let rawReportCount: Int
    let rawReportSamples: [ObserverRawReportSample]
    let radialNotificationCount: Int
    let radialSamples: [ObserverRadialSample]
    let invalidNotificationCount: Int
    let unexpectedResponseCount: Int
}

private struct ObserverRawReportSample: Encodable, Hashable {
    let reportID: UInt32
    let bytesHex: String
}

private struct ObserverRadialSample: Encodable {
    let angle: Double
    let distance: Double
}

private struct ObserverEvent: Encodable {
    let schemaVersion = 1
    let sequence: Int
    let elapsedMilliseconds: UInt64
    let rawKeyIndex: Int?
    let kind: String
    let control: String
    let phase: DeviceInputPhase
}

private struct ObserverFailure: Encodable {
    let schemaVersion = 1
    let outcome = "failed"
    let message: String
}

@main
@MainActor
private struct CopilotMicroInputObserver {
    static func main() {
        do {
            let options = try ObserverOptions(arguments: CommandLine.arguments)
            let inputMonitoring = HIDDeviceDiscovery.listenAccessStatus
            guard inputMonitoring == .granted else {
                throw ObserverError.inputMonitoringRequired(inputMonitoring)
            }
            let descriptors = try HIDDeviceDiscovery.discover()
                .filter { $0.qualification == .supportedCandidate }
            guard !descriptors.isEmpty else {
                throw ObserverError.deviceNotFound
            }
            guard descriptors.count == 1, let descriptor = descriptors.first else {
                throw ObserverError.multipleDevices
            }
            let connection = try HIDRPCConnection.connect(to: descriptor.registryID)
            defer { connection.close() }
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
            guard try keymap.planForCopilotMicro().changeCount == 0 else {
                throw ObserverError.mappingNotApplied
            }

            var normalizer = CreatorMicroInputNormalizer()
            var sequence = 0
            var rawReportCount = 0
            var rawReportSamples: [ObserverRawReportSample] = []
            var observedRawReportSamples: Set<ObserverRawReportSample> = []
            var radialNotificationCount = 0
            var radialSamples: [ObserverRadialSample] = []
            var invalidNotificationCount = 0
            let start = DispatchTime.now().uptimeNanoseconds
            connection.onRawReport = { reportID, bytes in
                rawReportCount += 1
                guard rawReportSamples.count < 32 else { return }
                let lastNonzeroIndex = bytes.lastIndex(where: { $0 != 0 })
                let significantBytes = lastNonzeroIndex.map { bytes[...$0] } ?? bytes.prefix(0)
                let sample = ObserverRawReportSample(
                    reportID: reportID,
                    bytesHex: significantBytes.map { String(format: "%02x", $0) }.joined()
                )
                if observedRawReportSamples.insert(sample).inserted {
                    rawReportSamples.append(sample)
                }
            }
            connection.onNotification = { method, params in
                do {
                    if let notification = try DeviceHIDNotification.parse(
                        method: method,
                        params: params
                    ) {
                        let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                        guard
                            let event = normalizer.process(
                                notification,
                                atMilliseconds: elapsed
                            )
                        else {
                            return
                        }
                        sequence += 1
                        emit(
                            ObserverEvent(
                                sequence: sequence,
                                elapsedMilliseconds: elapsed,
                                rawKeyIndex: event.rawKeyIndex,
                                kind: kind(event.control),
                                control: control(event.control),
                                phase: event.phase
                            )
                        )
                        return
                    }
                    if let radial = try DeviceRadialNotification.parse(
                        method: method,
                        params: params
                    ) {
                        radialNotificationCount += 1
                        if radialSamples.count < 64 {
                            radialSamples.append(
                                ObserverRadialSample(
                                    angle: radial.angle,
                                    distance: radial.distance
                                )
                            )
                        }
                        let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                        guard let event = normalizer.process(radial) else {
                            return
                        }
                        sequence += 1
                        emit(
                            ObserverEvent(
                                sequence: sequence,
                                elapsedMilliseconds: elapsed,
                                rawKeyIndex: event.rawKeyIndex,
                                kind: kind(event.control),
                                control: control(event.control),
                                phase: event.phase
                            )
                        )
                    }
                } catch {
                    invalidNotificationCount += 1
                }
            }

            emit(
                ObserverStatus(
                    outcome: "ready",
                    product: descriptor.product,
                    productID: String(format: "0x%04X", descriptor.productID),
                    transport: descriptor.transport,
                    inputMonitoring: inputMonitoring,
                    firmwareVersion: firmwareVersion,
                    activeLayerIndex: status.activeLayerIndex,
                    keymapSHA256: keymap.sha256,
                    durationSeconds: options.durationSeconds,
                    observedEventCount: 0,
                    rawReportCount: 0,
                    rawReportSamples: [],
                    radialNotificationCount: 0,
                    radialSamples: [],
                    invalidNotificationCount: 0,
                    unexpectedResponseCount: connection.unexpectedResponseCount
                )
            )
            let deadline = Date().addingTimeInterval(Double(options.durationSeconds))
            while Date() < deadline {
                _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
            }
            emit(
                ObserverStatus(
                    outcome: "complete",
                    product: descriptor.product,
                    productID: String(format: "0x%04X", descriptor.productID),
                    transport: descriptor.transport,
                    inputMonitoring: inputMonitoring,
                    firmwareVersion: firmwareVersion,
                    activeLayerIndex: status.activeLayerIndex,
                    keymapSHA256: keymap.sha256,
                    durationSeconds: options.durationSeconds,
                    observedEventCount: sequence,
                    rawReportCount: rawReportCount,
                    rawReportSamples: rawReportSamples,
                    radialNotificationCount: radialNotificationCount,
                    radialSamples: radialSamples,
                    invalidNotificationCount: invalidNotificationCount,
                    unexpectedResponseCount: connection.unexpectedResponseCount
                )
            )
        } catch {
            emit(
                ObserverFailure(
                    message: (error as? LocalizedError)?.errorDescription
                        ?? "Input observation failed."
                )
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func kind(_ control: DeviceInputControl) -> String {
        switch control {
        case .key: "key"
        case .dial: "dial"
        case .joystick: "joystick"
        }
    }

    private static func control(_ control: DeviceInputControl) -> String {
        switch control {
        case .key(let key): key.rawValue
        case .dial(let direction): direction.rawValue
        case .joystick(let direction): direction.rawValue
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
