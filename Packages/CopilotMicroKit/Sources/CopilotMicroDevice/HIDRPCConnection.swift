import CoreFoundation
import Foundation
import IOKit
import IOKit.hid

public enum HIDReadMethod: Sendable {
    case deviceStatus
    case keymap
    case systemVersion

    var method: String {
        switch self {
        case .deviceStatus: "device.status"
        case .keymap: "fs.read"
        case .systemVersion: "sys.version"
        }
    }

    var params: Any {
        switch self {
        case .deviceStatus, .systemVersion:
            NSNull()
        case .keymap:
            ["file": "keymap.json"]
        }
    }
}

public enum HIDConnectionError: Error, LocalizedError {
    case candidateNotFound
    case candidateUnsupported(String)
    case deviceRemoved
    case malformedResponse
    case openFailed(UInt32)
    case requestFailed(String)
    case timeout(String)
    case writeFailed(UInt32)

    public var errorDescription: String? {
        switch self {
        case .candidateNotFound:
            return "The selected Creator Micro 2 candidate is no longer present."
        case .candidateUnsupported(let reason):
            return reason
        case .deviceRemoved:
            return "The device disconnected while a read-only request was active."
        case .malformedResponse:
            return "The device returned malformed JSON-RPC data."
        case .openFailed(let code):
            if code == UInt32(bitPattern: kIOReturnNotPrivileged) || code == 0xE000_02C1 {
                return
                    "Opening the vendor HID collection was denied. Grant Input Monitoring to the terminal or app running the probe."
            }
            return String(format: "IOHIDDeviceOpen failed with 0x%08X.", code)
        case .requestFailed(let message):
            return message
        case .timeout(let method):
            return "Timed out waiting for the read-only \(method) response."
        case .writeFailed(let code):
            return String(format: "Sending the read-only HID request failed with 0x%08X.", code)
        }
    }
}

public final class HIDRPCConnection {
    public let descriptor: HIDDeviceDescriptor
    public private(set) var unexpectedResponseCount = 0
    public private(set) var notificationCount = 0

    private enum Response {
        case error(String)
        case result(Any?)
        case waiting
    }

    private struct PendingRequest {
        let method: String
        var response: Response
    }

    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private var allocator = HIDRequestIDAllocator()
    private var responses: [Int: PendingRequest] = [:]
    private var streamDecoder = HIDJSONStreamDecoder()
    private var closed = false
    private var removed = false

    public static func connect(to registryID: UInt64) throws -> HIDRPCConnection {
        let manager = try HIDNativeDiscovery.makeManager()
        let records = HIDNativeDiscovery.records(from: manager)
        guard let record = records.first(where: { $0.descriptor.registryID == registryID }) else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw HIDConnectionError.candidateNotFound
        }
        guard record.descriptor.qualification == .supportedCandidate else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw HIDConnectionError.candidateUnsupported(record.descriptor.qualificationReason)
        }
        let result = IOHIDDeviceOpen(record.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw HIDConnectionError.openFailed(UInt32(bitPattern: result))
        }
        return HIDRPCConnection(
            manager: manager,
            device: record.device,
            descriptor: record.descriptor
        )
    }

    private init(
        manager: IOHIDManager,
        device: IOHIDDevice,
        descriptor: HIDDeviceDescriptor
    ) {
        self.manager = manager
        self.device = device
        self.descriptor = descriptor
        self.inputBuffer = .allocate(capacity: CreatorMicro2Hardware.reportBytes)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputBuffer,
            CreatorMicro2Hardware.reportBytes,
            { context, _, _, _, reportID, report, length in
                guard let context, length > 0 else { return }
                let connection = Unmanaged<HIDRPCConnection>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                connection.receive(
                    reportID: reportID,
                    bytes: Array(UnsafeBufferPointer(start: report, count: length))
                )
            },
            context
        )
        IOHIDDeviceRegisterRemovalCallback(
            device,
            { context, _, _ in
                guard let context else { return }
                let connection = Unmanaged<HIDRPCConnection>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                connection.deviceWasRemoved()
            },
            context
        )
        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
    }

    deinit {
        close()
        inputBuffer.deallocate()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        allocator.invalidateAll()
        responses.removeAll()
        streamDecoder.reset()
        IOHIDDeviceUnscheduleFromRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func read(_ method: HIDReadMethod, timeoutSeconds: Double = 8) throws -> Any? {
        guard !closed, !removed else { throw HIDConnectionError.deviceRemoved }
        let requestID = try allocator.reserve()
        responses[requestID] = PendingRequest(method: method.method, response: .waiting)
        defer {
            responses.removeValue(forKey: requestID)
            allocator.release(requestID)
        }
        let object: [String: Any] = [
            "id": requestID,
            "method": method.method,
            "params": method.params,
        ]
        let message = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        for report in try HIDReportFraming.encodeRPCMessage(message) {
            let result = report.withUnsafeBufferPointer { buffer in
                IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeOutput,
                    CFIndex(HIDReportFraming.reportID),
                    buffer.baseAddress!,
                    buffer.count
                )
            }
            guard result == kIOReturnSuccess else {
                close()
                throw HIDConnectionError.writeFailed(UInt32(bitPattern: result))
            }
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if removed { throw HIDConnectionError.deviceRemoved }
            switch responses[requestID]?.response {
            case .result(let value):
                return value
            case .error(let message):
                throw HIDConnectionError.requestFailed(message)
            case .waiting:
                _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
            case nil:
                throw HIDConnectionError.malformedResponse
            }
        }
        close()
        throw HIDConnectionError.timeout(method.method)
    }

    private func receive(reportID: UInt32, bytes: [UInt8]) {
        do {
            guard let fragment = try HIDInboundFragment.decode(reportID: reportID, bytes: bytes) else {
                return
            }
            guard fragment.channel == .rpc else { return }
            for data in try streamDecoder.append(fragment.payload) {
                try receiveJSONObject(data)
            }
        } catch {
            streamDecoder.reset()
            failOutstanding(HIDConnectionError.malformedResponse.localizedDescription)
        }
    }

    private func receiveJSONObject(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HIDConnectionError.malformedResponse
        }
        guard let rawRequestID = object["id"] else {
            notificationCount += 1
            return
        }
        guard
            let requestID = HIDJSONNumber.integer(rawRequestID),
            (1...HIDRequestIDAllocator.maximumRequestID).contains(requestID)
        else {
            unexpectedResponseCount += 1
            return
        }
        guard var pending = responses[requestID] else {
            unexpectedResponseCount += 1
            return
        }
        guard case .waiting = pending.response else {
            unexpectedResponseCount += 1
            return
        }
        if let responseMethod = object["method"] as? String, responseMethod != pending.method {
            unexpectedResponseCount += 1
            return
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "The device rejected the read-only request."
            pending.response = .error(String(message.prefix(256)))
        } else {
            let result = object["result"]
            pending.response = .result(result is NSNull ? nil : result)
        }
        responses[requestID] = pending
    }

    private func deviceWasRemoved() {
        removed = true
        failOutstanding(HIDConnectionError.deviceRemoved.localizedDescription)
    }

    private func failOutstanding(_ message: String) {
        for requestID in responses.keys {
            guard var pending = responses[requestID] else { continue }
            pending.response = .error(message)
            responses[requestID] = pending
        }
    }
}
