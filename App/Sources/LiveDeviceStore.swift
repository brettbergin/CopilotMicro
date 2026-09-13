import AppKit
import Combine
import CopilotMicroCore
import CopilotMicroDevice
import Foundation

enum ManagerArea: String, CaseIterable, Identifiable {
    case overview
    case controls
    case lighting
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .overview:
            "Overview"
        case .controls:
            "Controls"
        case .lighting:
            "Lighting"
        case .diagnostics:
            "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            "rectangle.grid.2x2"
        case .controls:
            "keyboard"
        case .lighting:
            "lightbulb"
        case .diagnostics:
            "waveform.path.ecg"
        }
    }
}

enum LiveDeviceConnectionState: Equatable {
    case inactive
    case suppressedForSmoke
    case discovering
    case permissionRequired(HIDListenAccessStatus)
    case disconnected(String)
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .inactive:
            "Not started"
        case .suppressedForSmoke:
            "Suppressed for smoke test"
        case .discovering:
            "Connecting"
        case .permissionRequired:
            "Input Monitoring required"
        case .disconnected:
            "Disconnected"
        case .connected:
            "Connected"
        case .failed:
            "Connection failed"
        }
    }

    var detail: String {
        switch self {
        case .inactive:
            "The device service has not started."
        case .suppressedForSmoke:
            "Hardware access is disabled only for automated package validation."
        case .discovering:
            "Looking for one qualified Creator Micro 2 vendor interface."
        case .permissionRequired(let status):
            "Input Monitoring access is \(status.rawValue). Grant it to Copilot Micro, then reconnect."
        case .disconnected(let reason), .failed(let reason):
            reason
        case .connected:
            "The app owns a live, non-exclusive HID connection."
        }
    }

    var isConnected: Bool {
        self == .connected
    }
}

struct LiveDeviceEvent: Identifiable, Equatable {
    let id: Int
    let timestamp: Date
    let title: String
    let detail: String
}

@MainActor
final class LiveDeviceStore: ObservableObject {
    static let maximumEvents = 100

    let hardwareEnabled: Bool

    @Published var selectedArea: ManagerArea = .overview
    @Published private(set) var connectionState: LiveDeviceConnectionState
    @Published private(set) var product = "Creator Micro 2"
    @Published private(set) var productID = "Unknown"
    @Published private(set) var transport = "Unknown"
    @Published private(set) var firmwareVersion = "Unknown"
    @Published private(set) var activeLayer = "Unknown"
    @Published private(set) var keymapSHA256 = "Unknown"
    @Published private(set) var inputMonitoring = HIDDeviceDiscovery.listenAccessStatus
    @Published private(set) var pressedControls: Set<PhysicalControlID> = []
    @Published private(set) var activeJoystick: JoystickDirection?
    @Published private(set) var dialDirection: DeviceDialDirection?
    @Published private(set) var lastInput = "No hardware input observed."
    @Published private(set) var eventLog: [LiveDeviceEvent] = []
    @Published private(set) var rawReportCount = 0
    @Published private(set) var notificationCount = 0
    @Published private(set) var radialNotificationCount = 0
    @Published private(set) var lastRadialSample = "None"
    @Published private(set) var invalidNotificationCount = 0
    @Published private(set) var lightingColor: LightingColor = .white
    @Published private(set) var lightingApplied = false
    @Published private(set) var lightingStatus = "Key lighting has not been changed by the app."
    @Published private(set) var isPaused = false

    @Published var brightness = 0.35

    var onPresentationChange: (@MainActor () -> Void)?

    private var connection: HIDRPCConnection?
    private var normalizer = CreatorMicroInputNormalizer()
    private var nextEventID = 1
    private var started = false
    private var reconnectTask: Task<Void, Never>?
    private var dialGeneration: UInt64 = 0
    private var joystickGeneration: UInt64 = 0
    private var openedInputMonitoringSettings = false

    init(hardwareEnabled: Bool) {
        self.hardwareEnabled = hardwareEnabled
        connectionState = hardwareEnabled ? .inactive : .suppressedForSmoke
    }

    deinit {
        reconnectTask?.cancel()
        MainActor.assumeIsolated {
            connection?.close()
        }
    }

    var canControlLighting: Bool {
        connectionState.isConnected && !isPaused
    }

    var statusSymbol: String {
        switch connectionState {
        case .connected:
            "checkmark.circle.fill"
        case .discovering:
            "arrow.triangle.2.circlepath"
        case .permissionRequired:
            "hand.raised.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .inactive, .suppressedForSmoke, .disconnected:
            "cable.connector.slash"
        }
    }

    func start() {
        guard hardwareEnabled, !started else { return }
        started = true
        connect()
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        if lightingApplied, let connection {
            do {
                try writeLighting(
                    connection: connection,
                    color: .off,
                    brightness: 0,
                    timeoutSeconds: 2
                )
                lightingApplied = false
                lightingStatus = "Key lighting and ambient underglow cleared before disconnect."
            } catch {
                appendEvent("Lighting cleanup failed", localizedMessage(error))
            }
        }
        closeConnection()
        if hardwareEnabled {
            connectionState = .inactive
        }
        presentationDidChange()
    }

    func reconnect() {
        guard hardwareEnabled else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        isPaused = false
        connect()
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            stopConnectionForPause()
            appendEvent("Device paused", "Input observation and app-owned key lighting are stopped.")
        } else {
            appendEvent("Device resumed", "Reconnecting to the Creator Micro 2.")
            connect()
        }
        presentationDidChange()
    }

    func openInputMonitoringSettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            )
        else {
            appendEvent("System Settings unavailable", "Could not construct the Input Monitoring settings URL.")
            return
        }
        if !NSWorkspace.shared.open(url) {
            appendEvent("System Settings unavailable", "macOS did not open Input Monitoring settings.")
        }
    }

    func setLightingColor(_ color: LightingColor) {
        lightingColor = color
    }

    func applyLighting() {
        guard canControlLighting, let connection else {
            lightingStatus = "Connect the device before changing key lighting."
            presentationDidChange()
            return
        }
        let normalizedBrightness = min(max(brightness.isFinite ? brightness : 0, 0), 1)
        brightness = normalizedBrightness
        do {
            try DeviceConfiguratorGuard.requireNoKnownConfiguratorRunning()
            let appliedBrightness = lightingColor == .off ? 0 : normalizedBrightness
            try writeLighting(
                connection: connection,
                color: lightingColor,
                brightness: appliedBrightness
            )
            lightingApplied = appliedBrightness > 0
            lightingStatus =
                "Device acknowledged matching key and ambient \(lightingColor.displayName.lowercased()) at \(Int(appliedBrightness * 100)) percent."
            appendEvent("Device lighting updated", lightingStatus)
        } catch {
            lightingStatus = localizedMessage(error)
            appendEvent("Key lighting failed", lightingStatus)
        }
        presentationDidChange()
    }

    func clearEvents() {
        eventLog.removeAll()
        nextEventID = 1
        presentationDidChange()
    }

    static func validateHardwareSuppressionForSmoke() -> Bool {
        let store = LiveDeviceStore(hardwareEnabled: false)
        store.start()
        return store.connectionState == .suppressedForSmoke
            && !store.canControlLighting
            && store.eventLog.isEmpty
            && ManagerArea.allCases.count == 4
    }

    private func connect() {
        guard hardwareEnabled, !isPaused else { return }
        closeConnection()
        inputMonitoring = HIDDeviceDiscovery.listenAccessStatus
        if inputMonitoring == .unknown {
            _ = HIDDeviceDiscovery.requestListenAccess()
            inputMonitoring = HIDDeviceDiscovery.listenAccessStatus
        }
        guard inputMonitoring == .granted else {
            connectionState = .permissionRequired(inputMonitoring)
            appendEvent("Input Monitoring required", connectionState.detail)
            if !openedInputMonitoringSettings {
                openedInputMonitoringSettings = true
                openInputMonitoringSettings()
            }
            presentationDidChange()
            return
        }

        connectionState = .discovering
        presentationDidChange()
        do {
            try DeviceConfiguratorGuard.requireNoKnownConfiguratorRunning()
            let descriptors = try HIDDeviceDiscovery.discover()
                .filter { $0.qualification == .supportedCandidate }
            guard !descriptors.isEmpty else {
                connectionState = .disconnected(
                    "No qualified Creator Micro 2 is visible. Connect it over USB and leave Work Louder Input closed."
                )
                appendEvent("Device not found", connectionState.detail)
                scheduleReconnect()
                presentationDidChange()
                return
            }
            guard descriptors.count == 1, let descriptor = descriptors.first else {
                connectionState = .failed(
                    "Multiple qualified Creator Micro 2 devices are visible. Leave only the intended device connected."
                )
                appendEvent("Device selection blocked", connectionState.detail)
                presentationDidChange()
                return
            }

            let candidate = try HIDRPCConnection.connect(
                to: descriptor.registryID,
                accessMode: .sharedConfiguration
            )
            do {
                let firmware = try DeviceSnapshotParser.firmwareVersion(
                    from: candidate.read(.systemVersion)
                )
                let status = try DeviceSnapshotParser.status(
                    from: candidate.read(.deviceStatus)
                )
                let keymap = try DeviceKeymapDocument(
                    rpcResult: candidate.read(.keymap),
                    activeLayerIndex: status.activeLayerIndex
                )
                guard try keymap.planForCopilotMicro().changeCount == 0 else {
                    candidate.close()
                    connectionState = .failed(
                        "The active keymap is not configured for Copilot Micro. Apply the reviewed managed mapping before using live input."
                    )
                    appendEvent("Managed mapping required", connectionState.detail)
                    presentationDidChange()
                    return
                }

                rawReportCount = 0
                notificationCount = 0
                radialNotificationCount = 0
                lastRadialSample = "None"
                candidate.onRawReport = { [weak self] _, _ in
                    self?.rawReportCount += 1
                }
                candidate.onNotification = { [weak self] method, params in
                    self?.receiveNotification(method: method, params: params)
                }
                candidate.onRemoval = { [weak self] in
                    self?.deviceWasRemoved()
                }
                connection = candidate
                product = descriptor.product
                productID = String(format: "0x%04X", descriptor.productID)
                transport = descriptor.transport.rawValue.uppercased()
                firmwareVersion = firmware
                activeLayer = "\(status.activeLayerIndex)"
                keymapSHA256 = keymap.sha256
                connectionState = .connected
                normalizer.reset()
                appendEvent(
                    "Device connected",
                    "\(descriptor.product) \(productID), firmware \(firmware), \(transport)."
                )
            } catch {
                candidate.close()
                throw error
            }
        } catch {
            connectionState = .failed(localizedMessage(error))
            appendEvent("Device connection failed", connectionState.detail)
        }
        presentationDidChange()
    }

    private func receiveNotification(method: String, params: Any?) {
        notificationCount += 1
        if method == DeviceRadialNotification.method {
            radialNotificationCount += 1
        }
        do {
            if let notification = try DeviceHIDNotification.parse(method: method, params: params) {
                let milliseconds = DispatchTime.now().uptimeNanoseconds / 1_000_000
                if let event = normalizer.process(notification, atMilliseconds: milliseconds) {
                    apply(event)
                }
                return
            }
            if let notification = try DeviceRadialNotification.parse(method: method, params: params) {
                lastRadialSample = String(
                    format: "angle %.3f, distance %.3f",
                    notification.angle,
                    notification.distance
                )
                if let event = normalizer.process(notification) {
                    apply(event)
                }
            }
        } catch {
            invalidNotificationCount += 1
            appendEvent("Invalid device notification", localizedMessage(error))
            presentationDidChange()
        }
    }

    private func apply(_ event: NormalizedDeviceInput) {
        switch event.control {
        case .key(let control):
            if event.phase == .pressed {
                pressedControls.insert(control)
            } else if event.phase == .released {
                pressedControls.remove(control)
            }
        case .joystick(let direction):
            activeJoystick = direction
            joystickGeneration &+= 1
            if event.phase == .released {
                let generation = joystickGeneration
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(800))
                    guard let self, self.joystickGeneration == generation else { return }
                    self.activeJoystick = nil
                    self.presentationDidChange()
                }
            }
        case .dial(let direction):
            dialDirection = direction
            dialGeneration &+= 1
            let generation = dialGeneration
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard let self, self.dialGeneration == generation else { return }
                self.dialDirection = nil
                self.presentationDidChange()
            }
        }
        lastInput = event.description
        appendEvent("Hardware input", event.description)
        presentationDidChange()
    }

    private func deviceWasRemoved() {
        closeConnection()
        pressedControls.removeAll()
        activeJoystick = nil
        dialDirection = nil
        normalizer.reset()
        connectionState = .disconnected("The Creator Micro 2 was disconnected.")
        appendEvent("Device disconnected", connectionState.detail)
        scheduleReconnect()
        presentationDidChange()
    }

    private func scheduleReconnect() {
        guard hardwareEnabled, !isPaused, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    private func stopConnectionForPause() {
        reconnectTask?.cancel()
        reconnectTask = nil
        if lightingApplied, let connection {
            do {
                try writeLighting(
                    connection: connection,
                    color: .off,
                    brightness: 0,
                    timeoutSeconds: 2
                )
                lightingApplied = false
                lightingStatus = "Key lighting and ambient underglow cleared while paused."
            } catch {
                lightingStatus = localizedMessage(error)
                appendEvent("Lighting cleanup failed", lightingStatus)
            }
        }
        closeConnection()
        connectionState = .inactive
        pressedControls.removeAll()
        activeJoystick = nil
        dialDirection = nil
        normalizer.reset()
    }

    private func closeConnection() {
        connection?.onRawReport = nil
        connection?.onNotification = nil
        connection?.onRemoval = nil
        connection?.close()
        connection = nil
    }

    private func appendEvent(_ title: String, _ detail: String) {
        eventLog.insert(
            LiveDeviceEvent(id: nextEventID, timestamp: Date(), title: title, detail: detail),
            at: 0
        )
        nextEventID += 1
        if eventLog.count > Self.maximumEvents {
            eventLog.removeLast(eventLog.count - Self.maximumEvents)
        }
    }

    private func presentationDidChange() {
        onPresentationChange?()
    }

    private func writeLighting(
        connection: HIDRPCConnection,
        color: LightingColor,
        brightness: Double,
        timeoutSeconds: Double = 8
    ) throws {
        let effect: DeviceLightingEffect = brightness > 0 ? .solid : .off
        let rgb = DeviceRGBColor(color)
        let zone = try DeviceLightingZone(
            color: rgb,
            brightness: brightness,
            effect: effect
        )
        _ = try connection.setLightingZones(
            keys: zone,
            ambient: zone,
            timeoutSeconds: timeoutSeconds
        )
        _ = try connection.setKeyLighting(
            try DeviceKeyLighting.allVisibleKeys(
                color: rgb,
                brightness: brightness,
                effect: effect
            ),
            timeoutSeconds: timeoutSeconds
        )
    }

    private func localizedMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "The Creator Micro 2 operation failed."
    }
}

extension NormalizedDeviceInput {
    fileprivate var description: String {
        let phaseText = phase.rawValue
        return switch control {
        case .key(let control):
            "\(control.displayName) \(phaseText)"
        case .dial(let direction):
            "Dial \(direction.displayName) \(phaseText)"
        case .joystick(let direction):
            "Joystick \(direction.rawValue) \(phaseText)"
        }
    }
}

extension PhysicalControlID {
    var displayName: String {
        switch self {
        case .sessions:
            "Sessions"
        case .newSession:
            "New session"
        case .previous:
            "Previous"
        case .next:
            "Next"
        case .archive:
            "Archive"
        case .mode:
            "Mode"
        case .model:
            "Model"
        case .effort:
            "Effort"
        case .voice:
            "Voice"
        case .cancel:
            "Cancel"
        case .submit:
            "Submit"
        case .focus:
            "Focus"
        }
    }
}

extension DeviceDialDirection {
    var displayName: String {
        switch self {
        case .clockwise:
            "clockwise"
        case .counterClockwise:
            "counter-clockwise"
        }
    }
}

extension LightingColor {
    var displayName: String {
        rawValue.capitalized
    }
}
