import Foundation
import Testing

@testable import CopilotMicroDevice

@Suite("Creator Micro 2 HID framing")
struct HIDFramingTests {
    @Test("Outgoing UTF-8 messages split into bounded 64-byte reports")
    func outgoingReportsAreBounded() throws {
        let message = Data(String(repeating: "a", count: 100).utf8)
        let reports = try HIDReportFraming.encodeRPCMessage(message)
        #expect(reports.count == 2)
        #expect(reports.allSatisfy { $0.count == 64 })
        #expect(reports[0][0] == 0x06)
        #expect(reports[0][1] == 2)
        #expect(reports[0][2] == 61)
        #expect(reports[1][2] == 39)
    }

    @Test("Incoming fragments accept report ID in-band or out-of-band")
    func incomingAlignmentIsTolerant() throws {
        let outOfBand = try HIDInboundFragment.decode(
            reportID: 6,
            bytes: [2, 3, 0x7B, 0x7D, 0x20]
        )
        let inBand = try HIDInboundFragment.decode(
            reportID: 0,
            bytes: [6, 2, 2, 0x7B, 0x7D]
        )
        #expect(outOfBand?.payload == Data([0x7B, 0x7D, 0x20]))
        #expect(inBand?.payload == Data([0x7B, 0x7D]))
    }

    @Test("Split Unicode and braces inside strings reassemble as one JSON object")
    func splitUnicodeReassembles() throws {
        let json = #"{"data":"héllo { \"quoted\" }","nested":{"ok":true}}"#
        let bytes = [UInt8](json.utf8)
        var decoder = HIDJSONStreamDecoder()
        var objects: [Data] = []
        for byte in bytes {
            objects += try decoder.append(Data([byte]))
        }
        #expect(objects == [Data(json.utf8)])
    }

    @Test("Multiple objects and oversized streams are handled explicitly")
    func streamBoundsAreExplicit() throws {
        var decoder = HIDJSONStreamDecoder()
        #expect(
            try decoder.append(Data(#"{"id":1}{"id":2}"#.utf8))
                == [Data(#"{"id":1}"#.utf8), Data(#"{"id":2}"#.utf8)]
        )
        #expect(throws: HIDWireError.messageTooLarge) {
            _ = try decoder.append(
                Data(repeating: 0x20, count: HIDReportFraming.maximumMessageBytes + 1)
            )
        }
    }

    @Test("Request IDs stay below 1000 and enforce the in-flight bound")
    func requestIDsAreBounded() throws {
        var allocator = HIDRequestIDAllocator(startingAt: 990)
        var identifiers: [Int] = []
        for _ in 0..<HIDRequestIDAllocator.maximumOutstandingRequests {
            identifiers.append(try allocator.reserve())
        }
        #expect(identifiers.allSatisfy { $0 > 0 && $0 < 1000 })
        #expect(Set(identifiers).count == identifiers.count)
        #expect(throws: HIDWireError.requestLimitReached) {
            _ = try allocator.reserve()
        }
        allocator.release(identifiers[0])
        #expect(try allocator.reserve() < 1000)
    }

    @Test("JSON integers reject booleans, fractions, and non-finite values")
    func jsonIntegersAreStrict() {
        #expect(HIDJSONNumber.integer(NSNumber(value: 7)) == 7)
        #expect(HIDJSONNumber.integer(NSNumber(value: true)) == nil)
        #expect(HIDJSONNumber.integer(NSNumber(value: 1.5)) == nil)
        #expect(HIDJSONNumber.integer(NSNumber(value: Double.infinity)) == nil)
    }
}
