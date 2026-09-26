import CopilotMicroBridge
import CopilotMicroCore
import Foundation
import Testing

@Suite("Authenticated local IPC protocol")
struct IPCProtocolTests {
    @Test("Swift accepts and rejects the shared IPC fixtures")
    func sharedFixtures() throws {
        let manifestData = try Data(contentsOf: fixtureDirectory.appendingPathComponent("manifest.json"))
        let manifestObject = try #require(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        #expect(manifestObject["schemaVersion"] as? Int == 1)
        let expectedToken = try IPCBootstrapToken(
            rawValue: #require(manifestObject["bootstrapToken"] as? String)
        )
        let cases = try #require(manifestObject["cases"] as? [[String: Any]])

        for fixture in cases {
            let name = try #require(fixture["name"] as? String)
            let kind = try #require(fixture["kind"] as? String)
            let expectedDecode = try #require(fixture["decode"] as? String)
            let data: Data
            if fixture["generator"] as? String == "oversized" {
                data = Data(repeating: 0x20, count: LengthPrefixedFraming.maximumPayloadBytes + 1)
            } else {
                data = try JSONSerialization.data(
                    withJSONObject: try #require(fixture["message"] as? [String: Any]),
                    options: [.sortedKeys]
                )
            }

            if kind == "registration" {
                do {
                    let registration = try IPCRegistrationCodec.decode(data)
                    #expect(expectedDecode == "valid", "Unexpectedly decoded \(name)")
                    if name == "valid-registration-with-surface-association" {
                        #expect(
                            registration.surfaceAssociationToken?.rawValue
                                == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
                        )
                    }
                    let peerUserID: uid_t = fixture["peer"] as? String == "different" ? 502 : 501
                    let result = IPCAuthenticator(
                        expectedToken: expectedToken,
                        expectedUserID: 501
                    ).authenticate(registration, peerUserID: peerUserID)
                    #expect(result.rawValue == fixture["authentication"] as? String)
                } catch let error as IPCWireDecodeError {
                    #expect(error.rawValue == expectedDecode)
                }
                continue
            }

            do {
                let frame = try IPCFrameCodec.decode(data)
                #expect(expectedDecode == "valid", "Unexpectedly decoded \(name)")
                let rawReceiverRole = try #require(fixture["receiverRole"] as? String)
                let receiverRole = try #require(IPCPeerRole(rawValue: rawReceiverRole))
                #expect(
                    IPCDirectionValidator.validate(frame, receiverRole: receiverRole).rawValue
                        == fixture["direction"] as? String
                )
                if let expectedSequence = fixture["sequence"] as? String {
                    let generation = try ConnectionGeneration(rawValue: "generation-1")
                    var tracker = IPCSequenceTracker(generation: generation)
                    if fixture["replay"] as? String == "duplicate" {
                        #expect(tracker.accept(frame) == .accepted)
                    }
                    #expect(tracker.accept(frame).rawValue == expectedSequence)
                }
            } catch let error as IPCWireDecodeError {
                #expect(error.rawValue == expectedDecode)
            }
        }
    }

    @Test("Length-prefix framing accepts split and coalesced messages")
    func framing() throws {
        let firstPayload = Data(#"{"first":true}"#.utf8)
        let secondPayload = Data(#"{"second":true}"#.utf8)
        let first = try LengthPrefixedFraming.encode(firstPayload)
        let second = try LengthPrefixedFraming.encode(secondPayload)
        var decoder = LengthPrefixedFrameDecoder()
        let partialFrames = try decoder.append(Data(first.prefix(3)))
        #expect(partialFrames.isEmpty)
        var remainder = Data(first.dropFirst(3))
        remainder.append(second)
        let completeFrames = try decoder.append(remainder)
        #expect(completeFrames.count == 2)
        #expect(completeFrames[0] == firstPayload)
        #expect(completeFrames[1] == secondPayload)

        var oversized = Data([0, 1, 0, 1])
        oversized.append(0)
        #expect(throws: IPCWireDecodeError.messageTooLarge) {
            var invalidDecoder = LengthPrefixedFrameDecoder()
            _ = try invalidDecoder.append(oversized)
        }
        #expect(throws: IPCWireDecodeError.malformed) {
            try LengthPrefixedFraming.encode(Data())
        }
    }

    @Test("In-flight request tracking is bounded and cleared on disconnect")
    func inFlightTracking() throws {
        var tracker = IPCInFlightRequestTracker()
        let first = try RequestID(rawValue: "request-1")
        #expect(tracker.begin(first) == .accepted)
        #expect(tracker.begin(first) == .duplicateRequest)
        for index in 2...IPCInFlightRequestTracker.maximumRequests {
            #expect(tracker.begin(try RequestID(rawValue: "request-\(index)")) == .accepted)
        }
        #expect(
            tracker.begin(try RequestID(rawValue: "request-overflow")) == .tooManyInFlight
        )
        tracker.invalidate()
        #expect(tracker.count == 0)
        #expect(tracker.begin(first) == .accepted)
    }

    @Test("Registration responses keep accepted and rejected states distinct")
    func registrationResponses() throws {
        let accepted = try IPCRegistrationResult.accepted(
            connectionID: IPCConnectionID(rawValue: "connection-1")
        )
        #expect(
            try IPCRegistrationResultCodec.decode(
                IPCRegistrationResultCodec.encode(accepted)
            ) == accepted
        )

        let rejected = try IPCRegistrationResult.rejected(code: .invalidToken)
        #expect(
            try IPCRegistrationResultCodec.decode(
                IPCRegistrationResultCodec.encode(rejected)
            ) == rejected
        )
    }

    @Test("Generated bootstrap material is fixed-size lowercase hexadecimal")
    func bootstrapTokenGeneration() throws {
        let token = try IPCBootstrapToken.generate()
        let hexadecimal = Set("0123456789abcdef")
        #expect(token.rawValue.utf8.count == 64)
        #expect(token.rawValue.allSatisfy { hexadecimal.contains($0) })
        #expect(throws: IPCBootstrapToken.ValidationError.invalid) {
            try IPCBootstrapToken(rawValue: "not-secret-enough")
        }
    }

    @Test("Surface association material is fixed-size lowercase hexadecimal")
    func surfaceAssociationTokenGeneration() throws {
        let token = try SurfaceAssociationToken.generate()
        let hexadecimal = Set("0123456789abcdef")
        #expect(token.rawValue.utf8.count == 64)
        #expect(token.rawValue.allSatisfy { hexadecimal.contains($0) })
        #expect(throws: SurfaceAssociationToken.ValidationError.invalid) {
            try SurfaceAssociationToken(rawValue: "not-a-surface-token")
        }
    }
}

private var fixtureDirectory: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../../Contracts/fixtures/ipc-v1", isDirectory: true)
        .standardizedFileURL
}
