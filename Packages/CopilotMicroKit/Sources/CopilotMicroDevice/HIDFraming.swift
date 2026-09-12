import Foundation

enum HIDJSONNumber {
    static func integer(_ value: Any?) -> Int? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite
        else {
            return nil
        }
        return Int(exactly: number.doubleValue)
    }

    static func finiteDouble(_ value: Any?) -> Double? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite
        else {
            return nil
        }
        return number.doubleValue
    }
}

public enum HIDWireError: Error, Equatable, Sendable {
    case emptyMessage
    case messageTooLarge
    case malformedFragment
    case malformedJSONStream
    case requestLimitReached
}

public enum HIDChannel: UInt8, Sendable {
    case debug = 1
    case rpc = 2
}

public struct HIDInboundFragment: Equatable, Sendable {
    public let channel: HIDChannel
    public let payload: Data

    public init(channel: HIDChannel, payload: Data) {
        self.channel = channel
        self.payload = payload
    }

    public static func decode(reportID: UInt32, bytes: [UInt8]) throws -> HIDInboundFragment? {
        for offset in [0, 1] {
            guard bytes.count >= offset + 2 else { continue }
            if offset == 0, reportID != HIDReportFraming.reportID { continue }
            if offset == 1, bytes[0] != HIDReportFraming.reportID { continue }
            guard let channel = HIDChannel(rawValue: bytes[offset]) else { continue }
            let count = Int(bytes[offset + 1])
            guard count > 0, count <= HIDReportFraming.maximumChunkBytes else {
                throw HIDWireError.malformedFragment
            }
            guard bytes.count >= offset + 2 + count else {
                throw HIDWireError.malformedFragment
            }
            return HIDInboundFragment(
                channel: channel,
                payload: Data(bytes[(offset + 2)..<(offset + 2 + count)])
            )
        }
        return nil
    }
}

public enum HIDReportFraming {
    public static let reportID: UInt8 = 0x06
    public static let reportBytes = 64
    public static let maximumChunkBytes = 61
    public static let maximumMessageBytes = 1_048_576

    public static func encodeRPCMessage(_ message: Data) throws -> [[UInt8]] {
        guard !message.isEmpty else { throw HIDWireError.emptyMessage }
        guard message.count <= maximumMessageBytes else { throw HIDWireError.messageTooLarge }
        var reports: [[UInt8]] = []
        var offset = 0
        while offset < message.count {
            let count = min(maximumChunkBytes, message.count - offset)
            var report = [UInt8](repeating: 0, count: reportBytes)
            report[0] = reportID
            report[1] = HIDChannel.rpc.rawValue
            report[2] = UInt8(count)
            report.replaceSubrange(3..<(3 + count), with: message[offset..<(offset + count)])
            reports.append(report)
            offset += count
        }
        return reports
    }
}

public struct HIDJSONStreamDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ fragment: Data) throws -> [Data] {
        buffer.append(fragment)
        guard buffer.count <= HIDReportFraming.maximumMessageBytes else {
            throw HIDWireError.messageTooLarge
        }
        var objects: [Data] = []
        while let object = try nextObject() {
            objects.append(object)
        }
        return objects
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }

    private mutating func nextObject() throws -> Data? {
        let bytes = [UInt8](buffer)
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false
        for (index, byte) in bytes.enumerated() {
            if start == nil {
                if byte == 0x7B {
                    start = index
                    depth = 1
                } else if ![0x09, 0x0A, 0x0D, 0x20].contains(byte) {
                    throw HIDWireError.malformedJSONStream
                }
                continue
            }
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            if byte == 0x22 {
                inString = true
            } else if byte == 0x7B {
                depth += 1
            } else if byte == 0x7D {
                depth -= 1
                guard depth >= 0 else { throw HIDWireError.malformedJSONStream }
                if depth == 0, let start {
                    let object = buffer.subdata(in: start..<(index + 1))
                    buffer.removeSubrange(0..<(index + 1))
                    return object
                }
            }
        }
        return nil
    }
}

public struct HIDRequestIDAllocator: Sendable {
    public static let maximumRequestID = 999
    public static let maximumOutstandingRequests = 32

    private var nextID = 1
    private var outstanding: Set<Int> = []

    public init(
        startingAt: Int = Int.random(in: 1...Self.maximumRequestID)
    ) {
        self.nextID = (1...Self.maximumRequestID).contains(startingAt) ? startingAt : 1
    }

    public mutating func reserve() throws -> Int {
        guard outstanding.count < Self.maximumOutstandingRequests else {
            throw HIDWireError.requestLimitReached
        }
        for _ in 1...Self.maximumRequestID {
            let candidate = nextID
            nextID = candidate == Self.maximumRequestID ? 1 : candidate + 1
            if outstanding.insert(candidate).inserted {
                return candidate
            }
        }
        throw HIDWireError.requestLimitReached
    }

    public mutating func release(_ requestID: Int) {
        outstanding.remove(requestID)
    }

    public mutating func invalidateAll() {
        outstanding.removeAll()
    }
}
