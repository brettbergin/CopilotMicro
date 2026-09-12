import CopilotMicroCore
import Foundation
import Testing

@Suite("Shared bridge and control contracts")
struct ContractFixtureTests {
    @Test("Swift accepts and rejects the shared bridge fixtures")
    func sharedBridgeFixtures() throws {
        let directory = contractDirectory.appendingPathComponent("fixtures/bridge-v1", isDirectory: true)
        let manifest = try JSONDecoder().decode(
            FixtureManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        #expect(manifest.schemaVersion == 1)

        let binding = try makeBinding()
        let permissionID = try RequestID(rawValue: "permission-1")
        let capabilities = Dictionary(
            uniqueKeysWithValues: ActionID.allCases.map { ($0, Capability.supported) }
        )
        let context = ActionContext(
            binding: binding,
            connection: .ready,
            isPaused: false,
            contextRevision: 42,
            capabilities: capabilities,
            pendingRequestIDs: [permissionID],
            visiblePermissionRequestID: permissionID
        )

        for fixture in manifest.cases {
            let data: Data
            if fixture.generator == "oversized" {
                var oversized = try Data(contentsOf: directory.appendingPathComponent("valid-cancel.json"))
                oversized.append(Data(repeating: 0x20, count: ActionRequest.maximumEncodedBytes))
                data = oversized
            } else {
                data = try Data(contentsOf: directory.appendingPathComponent(try #require(fixture.file)))
            }

            do {
                let request = try ActionRequestDecoder.decode(data)
                #expect(fixture.decode == "valid", "Unexpectedly decoded \(fixture.name)")
                let result: String
                if fixture.replay == "duplicate" {
                    var ledger = ActionReplayLedger()
                    #expect(ledger.reserve(request, against: context) == .reserved)
                    switch ledger.reserve(request, against: context) {
                    case .reserved:
                        result = "allowed"
                    case .rejected(let rejection):
                        result = rejection.rawValue
                    }
                } else {
                    result = ActionGuard.validate(request, against: context)?.rawValue ?? "allowed"
                }
                #expect(result == fixture.guardResult, "Unexpected guard result for \(fixture.name)")
            } catch let error as ActionRequestDecodeError {
                #expect(error.rawValue == fixture.decode, "Unexpected decode result for \(fixture.name)")
            }
        }
    }

    @Test("Swift accepts and rejects the shared action-result fixtures")
    func sharedActionResultFixtures() throws {
        let directory = contractDirectory.appendingPathComponent("fixtures/bridge-v1", isDirectory: true)
        let manifest = try JSONDecoder().decode(
            FixtureManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("result-manifest.json"))
        )
        #expect(manifest.schemaVersion == 1)

        for fixture in manifest.cases {
            let data: Data
            if let generator = fixture.generator, generator.hasPrefix("unicode") {
                let count = try #require(Int(generator.dropFirst("unicode".count)))
                data = try JSONSerialization.data(withJSONObject: [
                    "protocolVersion": 1,
                    "messageType": "actionResult",
                    "requestId": "action-result-unicode",
                    "outcome": "completed",
                    "message": String(repeating: "\u{00E9}", count: count),
                ])
            } else {
                data = try Data(contentsOf: directory.appendingPathComponent(try #require(fixture.file)))
            }

            do {
                _ = try ActionResultDecoder.decode(data)
                #expect(fixture.decode == "valid", "Unexpectedly decoded \(fixture.name)")
            } catch let error as ActionRequestDecodeError {
                #expect(error.rawValue == fixture.decode, "Unexpected decode result for \(fixture.name)")
            } catch let error as ActionResult.ValidationError {
                #expect(String(describing: error) == fixture.decode, "Unexpected decode result for \(fixture.name)")
            }
        }
    }

    @Test("Swift action identifiers exactly match the shared action catalog")
    func actionCatalogMatchesSwift() throws {
        let catalog = try JSONDecoder().decode(
            ActionCatalog.self,
            from: Data(contentsOf: contractDirectory.appendingPathComponent("actions.json"))
        )
        #expect(catalog.schemaVersion == 1)
        #expect(Set(catalog.actions.map(\.id)) == Set(ActionID.allCases))
        for action in catalog.actions {
            #expect(
                action.permissionRequestArgument == (action.id.requiresPermissionRequest ? "required" : "forbidden"))
        }
    }

    @Test("The JSON schema action and result enums match the Swift model")
    func schemaEnumsMatchSwift() throws {
        let data = try Data(contentsOf: contractDirectory.appendingPathComponent("bridge-v1.schema.json"))
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try #require(object as? [String: Any])
        let definitions = try #require(root["$defs"] as? [String: Any])
        let actionType = try #require(definitions["actionType"] as? [String: Any])
        let actionValues = try #require(actionType["enum"] as? [String])
        #expect(Set(actionValues) == Set(ActionID.allCases.map(\.rawValue)))

        let actionResult = try #require(definitions["actionResult"] as? [String: Any])
        let properties = try #require(actionResult["properties"] as? [String: Any])
        let code = try #require(properties["code"] as? [String: Any])
        let resultCodes = try #require(code["enum"] as? [String])
        #expect(Set(resultCodes) == Set(ActionResultCode.allCases.map(\.rawValue)))
        let message = try #require(properties["message"] as? [String: Any])
        #expect(message["maxLength"] as? Int == ActionResult.maximumMessageCharacters)

        let actionRequest = try #require(definitions["actionRequest"] as? [String: Any])
        let requestProperties = try #require(actionRequest["properties"] as? [String: Any])
        let revision = try #require(requestProperties["contextRevision"] as? [String: Any])
        #expect(revision["maximum"] as? UInt64 == ActionRequest.maximumContextRevision)
    }

    @Test("Swift physical layout exactly matches the shared default controls")
    func controlCatalogMatchesSwift() throws {
        let catalog = try JSONDecoder().decode(
            ControlCatalog.self,
            from: Data(contentsOf: contractDirectory.appendingPathComponent("default-controls.json"))
        )
        #expect(catalog.schemaVersion == 1)
        #expect(catalog.hardware == "creator-micro-2-pro")
        #expect(catalog.controls.count == PhysicalLayout.creatorMicro2Pro.count)

        for control in catalog.controls {
            let descriptor = try #require(PhysicalLayout.creatorMicro2Pro.first { $0.id == control.id })
            #expect(descriptor.visualPosition == control.visualPosition)
            #expect(descriptor.contacts == Set(control.matrixContacts))
            #expect(descriptor.defaultAction == control.defaultAction)
            #expect(descriptor.oneShot == control.oneShot)
        }
    }

    @Test("Action outcomes preserve accepted, completed, rejected and failed semantics")
    func actionOutcomesRemainDistinct() throws {
        let requestID = try RequestID(rawValue: "action-result-1")
        let outcomes: [(ActionOutcome, ActionResultCode?)] = [
            (.accepted, .focusConsumed),
            (.completed, nil),
            (.rejected, .staleContext),
            (.failed, .timedOut),
        ]

        for (outcome, code) in outcomes {
            let result = try ActionResult(
                requestID: requestID,
                outcome: outcome,
                code: code,
                message: "Deterministic result."
            )
            let decoded = try JSONDecoder().decode(ActionResult.self, from: JSONEncoder().encode(result))
            #expect(decoded.protocolVersion == 1)
            #expect(decoded.messageType == .actionResult)
            #expect(decoded.outcome == outcome)
            #expect(decoded.code == code)
        }
    }

    @Test("Programmatic action payloads cannot bypass argument requirements")
    func actionPayloadValidation() throws {
        #expect(throws: ActionPayload.ValidationError.invalidPermissionRequestArgument) {
            try ActionPayload(type: .approvePermissionOnce)
        }
        #expect(throws: ActionPayload.ValidationError.invalidPermissionRequestArgument) {
            try ActionPayload(
                type: .cancelForeground,
                permissionRequestID: RequestID(rawValue: "permission-1")
            )
        }
        #expect(try ActionPayload(type: .cancelForeground).type == .cancelForeground)
    }

    @Test("Action result messages are bounded and nonempty")
    func actionResultValidation() throws {
        let requestID = try RequestID(rawValue: "action-result-1")
        #expect(throws: ActionResult.ValidationError.emptyMessage) {
            try ActionResult(requestID: requestID, outcome: .failed, message: "")
        }
        #expect(throws: ActionResult.ValidationError.messageTooLong) {
            try ActionResult(
                requestID: requestID,
                outcome: .failed,
                message: String(repeating: "x", count: ActionResult.maximumMessageCharacters + 1)
            )
        }
    }

    @Test("Live identity values reject empty, long and non-ASCII strings")
    func identifierValidation() {
        #expect(throws: IdentifierValidationError.empty) {
            try CLIInstanceID(rawValue: "")
        }
        #expect(throws: IdentifierValidationError.tooLong) {
            try SessionID(rawValue: String(repeating: "s", count: 129))
        }
        #expect(throws: IdentifierValidationError.invalidCharacter) {
            try ConnectionGeneration(rawValue: "generation-\n1")
        }
        #expect(throws: IdentifierValidationError.invalidCharacter) {
            try RequestID(rawValue: "permission-\u{00E9}")
        }
    }
}

private var contractDirectory: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../../Contracts", isDirectory: true)
        .standardizedFileURL
}

func makeBinding() throws -> LiveBinding {
    try LiveBinding(
        instanceID: CLIInstanceID(rawValue: "cli-instance-1"),
        sessionID: SessionID(rawValue: "session-1"),
        generation: ConnectionGeneration(rawValue: "generation-1")
    )
}

private struct FixtureManifest: Decodable {
    let schemaVersion: Int
    let cases: [FixtureCase]
}

private struct FixtureCase: Decodable {
    let name: String
    let file: String?
    let generator: String?
    let decode: String
    let guardResult: String?
    let replay: String?

    enum CodingKeys: String, CodingKey {
        case name
        case file
        case generator
        case decode
        case guardResult = "guard"
        case replay
    }
}

private struct ActionCatalog: Decodable {
    let schemaVersion: Int
    let actions: [ActionDefinition]
}

private struct ActionDefinition: Decodable {
    let id: ActionID
    let permissionRequestArgument: String
}

private struct ControlCatalog: Decodable {
    let schemaVersion: Int
    let hardware: String
    let controls: [ControlDefinition]
}

private struct ControlDefinition: Decodable {
    let id: PhysicalControlID
    let visualPosition: String
    let matrixContacts: [MatrixContactID]
    let defaultAction: ActionID
    let oneShot: Bool
}
