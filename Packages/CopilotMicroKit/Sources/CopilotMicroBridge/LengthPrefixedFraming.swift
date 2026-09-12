import Foundation

public enum LengthPrefixedFraming {
    public static let maximumPayloadBytes = 65_536

    public static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else {
            throw IPCWireDecodeError.malformed
        }
        guard payload.count <= maximumPayloadBytes else {
            throw IPCWireDecodeError.messageTooLarge
        }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(payload)
        return framed
    }
}

public struct LengthPrefixedFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while buffer.count >= MemoryLayout<UInt32>.size {
            let length = buffer.prefix(4).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard length > 0 else {
                throw IPCWireDecodeError.malformed
            }
            guard length <= LengthPrefixedFraming.maximumPayloadBytes else {
                throw IPCWireDecodeError.messageTooLarge
            }
            let frameLength = Int(length) + 4
            guard buffer.count >= frameLength else {
                break
            }
            frames.append(buffer.subdata(in: 4..<frameLength))
            buffer = Data(buffer.dropFirst(frameLength))
        }
        guard buffer.count <= LengthPrefixedFraming.maximumPayloadBytes + 4 else {
            throw IPCWireDecodeError.messageTooLarge
        }
        return frames
    }
}
