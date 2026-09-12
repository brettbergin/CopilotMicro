import CopilotMicroCore
import CoreFoundation
import Foundation

public enum IPCPeerRole: String, Codable, CaseIterable, Sendable {
    case nativeApp
    case cliBridge
}

public struct IPCBootstrapToken: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalid
    }

    public let rawValue: String

    public init(rawValue: String) throws {
        guard rawValue.utf8.count == 64,
            rawValue.unicodeScalars.allSatisfy({
                (0x30...0x39).contains($0.value) || (0x61...0x66).contains($0.value)
            })
        else {
            throw ValidationError.invalid
        }
        self.rawValue = rawValue
    }

    public static func generate() throws -> IPCBootstrapToken {
        var generator = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
        return try IPCBootstrapToken(rawValue: token)
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct IPCConnectionID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        try validateIPCIdentifier(rawValue)
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum IPCWireDecodeError: String, Error, Equatable, Sendable {
    case malformed
    case messageTooLarge
    case unexpectedField
    case unsupportedProtocol
    case invalidMessageType
    case invalidRole
    case invalidPayload
}

public struct IPCRegistration: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public enum MessageType: String, Codable, Sendable {
        case registration
    }

    public let protocolVersion: Int
    public let messageType: MessageType
    public let role: IPCPeerRole
    public let bootstrapToken: IPCBootstrapToken
    public let instanceID: CLIInstanceID
    public let sessionID: SessionID
    public let generation: ConnectionGeneration
    public let bridgeVersion: String
    public let cliVersion: String
    public let sdkVersion: String

    public init(
        role: IPCPeerRole = .cliBridge,
        bootstrapToken: IPCBootstrapToken,
        binding: LiveBinding,
        bridgeVersion: String,
        cliVersion: String,
        sdkVersion: String
    ) throws {
        try validateIPCIdentifier(bridgeVersion)
        try validateIPCIdentifier(cliVersion)
        try validateIPCIdentifier(sdkVersion)
        protocolVersion = Self.protocolVersion
        messageType = .registration
        self.role = role
        self.bootstrapToken = bootstrapToken
        instanceID = binding.instanceID
        sessionID = binding.sessionID
        generation = binding.generation
        self.bridgeVersion = bridgeVersion
        self.cliVersion = cliVersion
        self.sdkVersion = sdkVersion
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case messageType
        case role
        case bootstrapToken
        case instanceID = "instanceId"
        case sessionID = "sessionId"
        case generation
        case bridgeVersion
        case cliVersion
        case sdkVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .protocolVersion) == Self.protocolVersion else {
            throw IPCWireDecodeError.unsupportedProtocol
        }
        guard try container.decode(MessageType.self, forKey: .messageType) == .registration else {
            throw IPCWireDecodeError.invalidMessageType
        }
        try self.init(
            role: container.decode(IPCPeerRole.self, forKey: .role),
            bootstrapToken: container.decode(IPCBootstrapToken.self, forKey: .bootstrapToken),
            binding: LiveBinding(
                instanceID: container.decode(CLIInstanceID.self, forKey: .instanceID),
                sessionID: container.decode(SessionID.self, forKey: .sessionID),
                generation: container.decode(ConnectionGeneration.self, forKey: .generation)
            ),
            bridgeVersion: container.decode(String.self, forKey: .bridgeVersion),
            cliVersion: container.decode(String.self, forKey: .cliVersion),
            sdkVersion: container.decode(String.self, forKey: .sdkVersion)
        )
    }
}

public enum IPCRegistrationCodec {
    private static let keys: Set<String> = [
        "protocolVersion",
        "messageType",
        "role",
        "bootstrapToken",
        "instanceId",
        "sessionId",
        "generation",
        "bridgeVersion",
        "cliVersion",
        "sdkVersion",
    ]

    public static func encode(_ registration: IPCRegistration) throws -> Data {
        try ipcEncoder().encode(registration)
    }

    public static func decode(_ data: Data) throws -> IPCRegistration {
        let object = try strictObject(data, expectedKeys: keys)
        guard object["protocolVersion"] as? Int == IPCRegistration.protocolVersion else {
            throw IPCWireDecodeError.unsupportedProtocol
        }
        guard object["messageType"] as? String == IPCRegistration.MessageType.registration.rawValue
        else {
            throw IPCWireDecodeError.invalidMessageType
        }
        do {
            return try JSONDecoder().decode(IPCRegistration.self, from: data)
        } catch let error as IPCWireDecodeError {
            throw error
        } catch is IPCBootstrapToken.ValidationError {
            throw IPCWireDecodeError.malformed
        } catch is IdentifierValidationError {
            throw IPCWireDecodeError.malformed
        } catch {
            throw IPCWireDecodeError.malformed
        }
    }
}

public enum IPCRegistrationRejectionCode: String, Codable, CaseIterable, Sendable {
    case invalidToken
    case wrongPeer
    case wrongRole
    case protocolViolation
}

public enum IPCRegistrationOutcome: String, Codable, Sendable {
    case accepted
    case rejected
}

public struct IPCRegistrationResult: Codable, Equatable, Sendable {
    public static let protocolVersion = 1
    public static let maximumMessageCharacters = 512

    public enum MessageType: String, Codable, Sendable {
        case registrationResult
    }

    public let protocolVersion: Int
    public let messageType: MessageType
    public let outcome: IPCRegistrationOutcome
    public let connectionID: IPCConnectionID?
    public let code: IPCRegistrationRejectionCode?
    public let message: String

    public static func accepted(
        connectionID: IPCConnectionID,
        message: String = "Authenticated."
    ) throws -> IPCRegistrationResult {
        try IPCRegistrationResult(
            outcome: .accepted,
            connectionID: connectionID,
            code: nil,
            message: message
        )
    }

    public static func rejected(
        code: IPCRegistrationRejectionCode,
        message: String = "Registration rejected."
    ) throws -> IPCRegistrationResult {
        try IPCRegistrationResult(
            outcome: .rejected,
            connectionID: nil,
            code: code,
            message: message
        )
    }

    private init(
        outcome: IPCRegistrationOutcome,
        connectionID: IPCConnectionID?,
        code: IPCRegistrationRejectionCode?,
        message: String
    ) throws {
        guard !message.isEmpty, message.unicodeScalars.count <= Self.maximumMessageCharacters else {
            throw IPCWireDecodeError.malformed
        }
        guard
            (outcome == .accepted && connectionID != nil && code == nil)
                || (outcome == .rejected && connectionID == nil && code != nil)
        else {
            throw IPCWireDecodeError.malformed
        }
        protocolVersion = Self.protocolVersion
        messageType = .registrationResult
        self.outcome = outcome
        self.connectionID = connectionID
        self.code = code
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case messageType
        case outcome
        case connectionID = "connectionId"
        case code
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .protocolVersion) == Self.protocolVersion else {
            throw IPCWireDecodeError.unsupportedProtocol
        }
        guard
            try container.decode(MessageType.self, forKey: .messageType) == .registrationResult
        else {
            throw IPCWireDecodeError.invalidMessageType
        }
        try self.init(
            outcome: container.decode(IPCRegistrationOutcome.self, forKey: .outcome),
            connectionID: container.decodeIfPresent(IPCConnectionID.self, forKey: .connectionID),
            code: container.decodeIfPresent(IPCRegistrationRejectionCode.self, forKey: .code),
            message: container.decode(String.self, forKey: .message)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(messageType, forKey: .messageType)
        try container.encode(outcome, forKey: .outcome)
        if let connectionID {
            try container.encode(connectionID, forKey: .connectionID)
        } else {
            try container.encodeNil(forKey: .connectionID)
        }
        if let code {
            try container.encode(code, forKey: .code)
        } else {
            try container.encodeNil(forKey: .code)
        }
        try container.encode(message, forKey: .message)
    }
}

public enum IPCRegistrationResultCodec {
    private static let keys: Set<String> = [
        "protocolVersion",
        "messageType",
        "outcome",
        "connectionId",
        "code",
        "message",
    ]

    public static func encode(_ result: IPCRegistrationResult) throws -> Data {
        try ipcEncoder().encode(result)
    }

    public static func decode(_ data: Data) throws -> IPCRegistrationResult {
        _ = try strictObject(data, expectedKeys: keys)
        do {
            return try JSONDecoder().decode(IPCRegistrationResult.self, from: data)
        } catch let error as IPCWireDecodeError {
            throw error
        } catch {
            throw IPCWireDecodeError.malformed
        }
    }
}

public enum IPCPayloadMessageType: String, CaseIterable, Sendable {
    case action
    case actionResult
    case heartbeat
    case sessionEvent
    case sessionSnapshot

    var sender: IPCPeerRole {
        switch self {
        case .action:
            .nativeApp
        case .actionResult, .heartbeat, .sessionEvent, .sessionSnapshot:
            .cliBridge
        }
    }
}

public struct IPCFrame: Equatable, Sendable {
    public static let protocolVersion = 1
    public static let maximumSequence: UInt64 = 9_007_199_254_740_991

    public let role: IPCPeerRole
    public let generation: ConnectionGeneration
    public let sequence: UInt64
    public let payload: Data
    public let payloadMessageType: IPCPayloadMessageType

    public init(
        role: IPCPeerRole,
        generation: ConnectionGeneration,
        sequence: UInt64,
        payload: Data
    ) throws {
        guard sequence > 0, sequence <= Self.maximumSequence else {
            throw IPCWireDecodeError.malformed
        }
        let payloadObject = try strictJSONObject(payload)
        guard payloadObject["protocolVersion"] as? Int == Self.protocolVersion,
            let rawMessageType = payloadObject["messageType"] as? String,
            let payloadMessageType = IPCPayloadMessageType(rawValue: rawMessageType)
        else {
            throw IPCWireDecodeError.invalidPayload
        }
        try validateBridgePayload(
            payload,
            object: payloadObject,
            messageType: payloadMessageType,
            generation: generation
        )
        self.role = role
        self.generation = generation
        self.sequence = sequence
        self.payload = try JSONSerialization.data(
            withJSONObject: payloadObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        self.payloadMessageType = payloadMessageType
    }

    public func encoded() throws -> Data {
        let payloadObject = try strictJSONObject(payload)
        return try JSONSerialization.data(
            withJSONObject: [
                "protocolVersion": Self.protocolVersion,
                "messageType": "frame",
                "role": role.rawValue,
                "generation": generation.rawValue,
                "sequence": sequence,
                "payload": payloadObject,
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

public enum IPCFrameCodec {
    private static let keys: Set<String> = [
        "protocolVersion",
        "messageType",
        "role",
        "generation",
        "sequence",
        "payload",
    ]

    public static func decode(_ data: Data) throws -> IPCFrame {
        let object = try strictObject(data, expectedKeys: keys)
        guard object["protocolVersion"] as? Int == IPCFrame.protocolVersion else {
            throw IPCWireDecodeError.unsupportedProtocol
        }
        guard object["messageType"] as? String == "frame" else {
            throw IPCWireDecodeError.invalidMessageType
        }
        guard let rawRole = object["role"] as? String, let role = IPCPeerRole(rawValue: rawRole)
        else {
            throw IPCWireDecodeError.invalidRole
        }
        guard let rawGeneration = object["generation"] as? String,
            let generation = try? ConnectionGeneration(rawValue: rawGeneration),
            let sequenceNumber = object["sequence"] as? NSNumber,
            CFGetTypeID(sequenceNumber) != CFBooleanGetTypeID(),
            sequenceNumber.doubleValue.rounded(.towardZero) == sequenceNumber.doubleValue,
            sequenceNumber.uint64Value > 0,
            sequenceNumber.uint64Value <= IPCFrame.maximumSequence,
            let payloadObject = object["payload"] as? [String: Any]
        else {
            throw IPCWireDecodeError.malformed
        }
        let payload = try JSONSerialization.data(
            withJSONObject: payloadObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return try IPCFrame(
            role: role,
            generation: generation,
            sequence: sequenceNumber.uint64Value,
            payload: payload
        )
    }
}

public enum IPCDirectionResult: String, Equatable, Sendable {
    case allowed
    case wrongRole
}

public enum IPCDirectionValidator {
    public static func validate(
        _ frame: IPCFrame,
        receiverRole: IPCPeerRole
    ) -> IPCDirectionResult {
        let expectedSender = frame.payloadMessageType.sender
        let expectedReceiver: IPCPeerRole = expectedSender == .nativeApp ? .cliBridge : .nativeApp
        guard frame.role == expectedSender, receiverRole == expectedReceiver else {
            return .wrongRole
        }
        return .allowed
    }
}

public enum IPCSequenceResult: String, Equatable, Sendable {
    case accepted
    case staleGeneration
    case staleSequence
    case sequenceGap
}

public struct IPCSequenceTracker: Sendable {
    private var generation: ConnectionGeneration
    private var nextSequence: UInt64 = 1

    public init(generation: ConnectionGeneration) {
        self.generation = generation
    }

    public mutating func accept(_ frame: IPCFrame) -> IPCSequenceResult {
        guard frame.generation == generation else {
            return .staleGeneration
        }
        guard frame.sequence >= nextSequence else {
            return .staleSequence
        }
        guard frame.sequence == nextSequence else {
            return .sequenceGap
        }
        nextSequence += 1
        return .accepted
    }

    public mutating func invalidate(for generation: ConnectionGeneration) {
        self.generation = generation
        nextSequence = 1
    }
}

public enum IPCInFlightResult: String, Equatable, Sendable {
    case accepted
    case invalidRequest
    case duplicateRequest
    case tooManyInFlight
}

public struct IPCInFlightRequestTracker: Sendable {
    public static let maximumRequests = 64

    private var requestIDs: Set<RequestID> = []

    public init() {}

    public var count: Int {
        requestIDs.count
    }

    public mutating func begin(_ requestID: RequestID) -> IPCInFlightResult {
        guard !requestIDs.contains(requestID) else {
            return .duplicateRequest
        }
        guard requestIDs.count < Self.maximumRequests else {
            return .tooManyInFlight
        }
        requestIDs.insert(requestID)
        return .accepted
    }

    @discardableResult
    public mutating func complete(_ requestID: RequestID) -> Bool {
        requestIDs.remove(requestID) != nil
    }

    public mutating func invalidate() {
        requestIDs.removeAll()
    }
}

public enum IPCAuthenticationResult: String, Equatable, Sendable {
    case accepted
    case invalidToken
    case wrongPeer
    case wrongRole
}

public struct IPCAuthenticator: Sendable {
    public let expectedToken: IPCBootstrapToken
    public let expectedUserID: uid_t

    public init(expectedToken: IPCBootstrapToken, expectedUserID: uid_t) {
        self.expectedToken = expectedToken
        self.expectedUserID = expectedUserID
    }

    public func authenticate(
        _ registration: IPCRegistration,
        peerUserID: uid_t
    ) -> IPCAuthenticationResult {
        guard peerUserID == expectedUserID else {
            return .wrongPeer
        }
        guard registration.role == .cliBridge else {
            return .wrongRole
        }
        return constantTimeEqual(
            registration.bootstrapToken.rawValue,
            expectedToken.rawValue
        ) ? .accepted : .invalidToken
    }
}

private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
    let leftBytes = Array(left.utf8)
    let rightBytes = Array(right.utf8)
    var difference = UInt8(leftBytes.count ^ rightBytes.count)
    let count = max(leftBytes.count, rightBytes.count)
    for index in 0..<count {
        let leftByte = index < leftBytes.count ? leftBytes[index] : 0
        let rightByte = index < rightBytes.count ? rightBytes[index] : 0
        difference |= leftByte ^ rightByte
    }
    return difference == 0
}

private func validateIPCIdentifier(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 128,
        value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E })
    else {
        throw IPCWireDecodeError.malformed
    }
}

private func validateBridgePayload(
    _ data: Data,
    object: [String: Any],
    messageType: IPCPayloadMessageType,
    generation: ConnectionGeneration
) throws {
    do {
        switch messageType {
        case .action:
            let request = try ActionRequestDecoder.decode(data)
            guard request.generation == generation else {
                throw IPCWireDecodeError.invalidPayload
            }
        case .actionResult:
            _ = try ActionResultDecoder.decode(data)
        case .heartbeat:
            try validateHeartbeat(object, generation: generation)
        case .sessionEvent:
            try validateSessionEvent(object, generation: generation)
        case .sessionSnapshot:
            try validateSessionSnapshot(object, generation: generation)
        }
    } catch {
        throw IPCWireDecodeError.invalidPayload
    }
}

private func validateSessionSnapshot(
    _ object: [String: Any],
    generation: ConnectionGeneration
) throws {
    let requiredKeys: Set<String> = [
        "protocolVersion",
        "messageType",
        "instanceId",
        "sessionId",
        "generation",
        "contextRevision",
        "connection",
        "paused",
        "mode",
        "work",
        "pendingAttention",
        "attention",
        "capabilities",
        "hostCapabilities",
        "model",
        "compatibility",
    ]
    let allowedKeys = requiredKeys.union([
        "visiblePermissionRequestId",
        "failure",
        "completionId",
    ])
    let keys = Set(object.keys)
    guard requiredKeys.isSubset(of: keys), keys.isSubset(of: allowedKeys),
        object["protocolVersion"] as? Int == IPCFrame.protocolVersion,
        object["messageType"] as? String == IPCPayloadMessageType.sessionSnapshot.rawValue,
        let instanceID = object["instanceId"] as? String,
        let sessionID = object["sessionId"] as? String,
        let rawGeneration = object["generation"] as? String,
        let snapshotGeneration = try? ConnectionGeneration(rawValue: rawGeneration),
        snapshotGeneration == generation,
        (try? CLIInstanceID(rawValue: instanceID)) != nil,
        (try? SessionID(rawValue: sessionID)) != nil,
        safeUnsignedInteger(object["contextRevision"]) != nil,
        let connection = object["connection"] as? String,
        ["connecting", "synchronizing", "ready", "reconnecting", "shuttingDown"]
            .contains(connection),
        object["paused"] is Bool,
        validMode(object["mode"]),
        let work = object["work"] as? [String: Any],
        validWork(work),
        let pendingAttention = object["pendingAttention"] as? [[String: Any]],
        validPendingAttention(pendingAttention),
        let attention = object["attention"] as? [String: Any],
        validAttention(attention),
        let capabilities = object["capabilities"] as? [String: Any],
        validCapabilities(capabilities),
        let hostCapabilities = object["hostCapabilities"] as? [String: Any],
        validHostCapabilities(hostCapabilities),
        let model = object["model"] as? [String: Any],
        validModel(model),
        let compatibility = object["compatibility"] as? [String: Any],
        validCompatibility(compatibility),
        validNullableIdentifier(object["visiblePermissionRequestId"]),
        validFailure(object["failure"]),
        validNullableIdentifier(object["completionId"])
    else {
        throw IPCWireDecodeError.invalidPayload
    }
}

private func validMode(_ value: Any?) -> Bool {
    if value is NSNull {
        return true
    }
    guard let mode = value as? String else {
        return false
    }
    return ["default", "plan", "autopilot"].contains(mode)
}

private func validWork(_ value: [String: Any]) -> Bool {
    guard Set(value.keys) == Set(["known", "foregroundActive", "backgroundCount", "queuedCount"]),
        let known = value["known"] as? Bool,
        let foregroundActive = value["foregroundActive"] as? Bool,
        let backgroundCount = safeUnsignedInteger(value["backgroundCount"]),
        backgroundCount <= 128,
        let queuedCount = safeUnsignedInteger(value["queuedCount"]),
        queuedCount <= 128,
        known || (!foregroundActive && backgroundCount == 0 && queuedCount == 0)
    else {
        return false
    }
    return true
}

private func validPendingAttention(_ values: [[String: Any]]) -> Bool {
    guard values.count <= SessionSnapshot.maximumPendingAttention else {
        return false
    }
    var requestIDs: Set<String> = []
    for value in values {
        guard Set(value.keys) == Set(["requestId", "kind"]),
            let requestID = value["requestId"] as? String,
            (try? RequestID(rawValue: requestID)) != nil,
            requestIDs.insert(requestID).inserted,
            let kind = value["kind"] as? String,
            AttentionKind(rawValue: kind) != nil
        else {
            return false
        }
    }
    return true
}

private func validAttention(_ value: [String: Any]) -> Bool {
    guard Set(value.keys) == Set(["known", "permissionCount", "otherCount"]),
        let known = value["known"] as? Bool,
        let permissionCount = safeUnsignedInteger(value["permissionCount"]),
        permissionCount <= 128,
        let otherCount = safeUnsignedInteger(value["otherCount"]),
        otherCount <= 128,
        known || (permissionCount == 0 && otherCount == 0)
    else {
        return false
    }
    return true
}

private func validCapabilities(_ values: [String: Any]) -> Bool {
    guard values.count <= 64 else {
        return false
    }
    let allowedKeys: Set<String> = ["status", "reason", "gapReference", "recoveryAction"]
    for (action, rawCapability) in values {
        guard ActionID(rawValue: action) != nil,
            let capability = rawCapability as? [String: Any],
            Set(capability.keys).isSubset(of: allowedKeys),
            capability["status"] != nil,
            let status = capability["status"] as? String,
            CapabilityStatus(rawValue: status) != nil,
            validOptionalBoundedString(capability["reason"], maximumCharacters: 512),
            validOptionalBoundedString(capability["gapReference"], maximumCharacters: 128),
            validOptionalBoundedString(capability["recoveryAction"], maximumCharacters: 128)
        else {
            return false
        }
    }
    return true
}

private func validHostCapabilities(_ value: [String: Any]) -> Bool {
    Set(value.keys) == Set(["elicitation", "canvases", "mcpApps"])
        && value["elicitation"] is Bool
        && value["canvases"] is Bool
        && value["mcpApps"] is Bool
}

private func validModel(_ value: [String: Any]) -> Bool {
    guard
        Set(value.keys)
            == Set([
                "known",
                "modelId",
                "reasoningEffort",
                "contextTier",
                "availableModels",
            ]),
        let known = value["known"] as? Bool,
        validNullableBoundedString(value["modelId"], maximumCharacters: 128),
        validNullableBoundedString(value["reasoningEffort"], maximumCharacters: 32),
        validNullableBoundedString(value["contextTier"], maximumCharacters: 32),
        let availableModels = value["availableModels"] as? [[String: Any]],
        availableModels.count <= 64,
        known
            || (value["modelId"] is NSNull
                && value["reasoningEffort"] is NSNull
                && value["contextTier"] is NSNull
                && availableModels.isEmpty)
    else {
        return false
    }
    for model in availableModels {
        guard
            Set(model.keys)
                == Set([
                    "id",
                    "reasoningEffort",
                    "supportedReasoningEfforts",
                ]),
            validRequiredBoundedString(model["id"], maximumCharacters: 128),
            model["reasoningEffort"] is Bool,
            let efforts = model["supportedReasoningEfforts"] as? [String],
            efforts.count <= 16,
            efforts.allSatisfy({
                !$0.isEmpty && $0.unicodeScalars.count <= 32
            })
        else {
            return false
        }
    }
    return true
}

private func validCompatibility(_ value: [String: Any]) -> Bool {
    guard
        Set(value.keys) == Set(["status", "cliVersion", "sdkVersion", "reason"]),
        let status = value["status"] as? String,
        SessionObservationCompatibilityStatus(rawValue: status) != nil,
        validRequiredBoundedString(value["cliVersion"], maximumCharacters: 128),
        validRequiredBoundedString(value["sdkVersion"], maximumCharacters: 128),
        validRequiredBoundedString(value["reason"], maximumCharacters: 512)
    else {
        return false
    }
    return true
}

private func validateSessionEvent(
    _ object: [String: Any],
    generation: ConnectionGeneration
) throws {
    let keys: Set<String> = [
        "protocolVersion",
        "messageType",
        "instanceId",
        "sessionId",
        "generation",
        "contextRevision",
        "reason",
    ]
    guard Set(object.keys) == keys,
        object["protocolVersion"] as? Int == IPCFrame.protocolVersion,
        object["messageType"] as? String == IPCPayloadMessageType.sessionEvent.rawValue,
        let instanceID = object["instanceId"] as? String,
        (try? CLIInstanceID(rawValue: instanceID)) != nil,
        let sessionID = object["sessionId"] as? String,
        (try? SessionID(rawValue: sessionID)) != nil,
        let rawGeneration = object["generation"] as? String,
        let eventGeneration = try? ConnectionGeneration(rawValue: rawGeneration),
        eventGeneration == generation,
        let revision = safeUnsignedInteger(object["contextRevision"]),
        revision > 0,
        let reason = object["reason"] as? String,
        SessionObservationEventReason(rawValue: reason) != nil
    else {
        throw IPCWireDecodeError.invalidPayload
    }
}

private func validateHeartbeat(
    _ object: [String: Any],
    generation: ConnectionGeneration
) throws {
    let keys: Set<String> = [
        "protocolVersion",
        "messageType",
        "instanceId",
        "sessionId",
        "generation",
        "contextRevision",
    ]
    guard Set(object.keys) == keys,
        object["protocolVersion"] as? Int == IPCFrame.protocolVersion,
        object["messageType"] as? String == IPCPayloadMessageType.heartbeat.rawValue,
        let instanceID = object["instanceId"] as? String,
        (try? CLIInstanceID(rawValue: instanceID)) != nil,
        let sessionID = object["sessionId"] as? String,
        (try? SessionID(rawValue: sessionID)) != nil,
        let rawGeneration = object["generation"] as? String,
        let heartbeatGeneration = try? ConnectionGeneration(rawValue: rawGeneration),
        heartbeatGeneration == generation,
        safeUnsignedInteger(object["contextRevision"]) != nil
    else {
        throw IPCWireDecodeError.invalidPayload
    }
}

private func validFailure(_ value: Any?) -> Bool {
    if value == nil || value is NSNull {
        return true
    }
    guard let failure = value as? [String: Any],
        Set(failure.keys) == Set(["id", "category"]),
        let identifier = failure["id"] as? String,
        (try? ErrorID(rawValue: identifier)) != nil,
        let category = failure["category"] as? String,
        SessionErrorCategory(rawValue: category) != nil
    else {
        return false
    }
    return true
}

private func validNullableIdentifier(_ value: Any?) -> Bool {
    if value == nil || value is NSNull {
        return true
    }
    guard let identifier = value as? String else {
        return false
    }
    return (try? RequestID(rawValue: identifier)) != nil
}

private func validOptionalBoundedString(
    _ value: Any?,
    maximumCharacters: Int
) -> Bool {
    guard let value else {
        return true
    }
    guard let string = value as? String else {
        return false
    }
    return string.unicodeScalars.count <= maximumCharacters
}

private func validRequiredBoundedString(
    _ value: Any?,
    maximumCharacters: Int
) -> Bool {
    guard let string = value as? String else {
        return false
    }
    return !string.isEmpty && string.unicodeScalars.count <= maximumCharacters
}

private func validNullableBoundedString(
    _ value: Any?,
    maximumCharacters: Int
) -> Bool {
    if value is NSNull {
        return true
    }
    return validRequiredBoundedString(value, maximumCharacters: maximumCharacters)
}

private func safeUnsignedInteger(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue >= 0,
        number.doubleValue.rounded(.towardZero) == number.doubleValue,
        number.doubleValue <= Double(IPCFrame.maximumSequence)
    else {
        return nil
    }
    return number.uint64Value
}

private func ipcEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

private func strictObject(_ data: Data, expectedKeys: Set<String>) throws -> [String: Any] {
    guard data.count <= LengthPrefixedFraming.maximumPayloadBytes else {
        throw IPCWireDecodeError.messageTooLarge
    }
    let object = try strictJSONObject(data)
    let keys = Set(object.keys)
    guard expectedKeys.isSubset(of: keys) else {
        throw IPCWireDecodeError.malformed
    }
    guard keys.isSubset(of: expectedKeys) else {
        throw IPCWireDecodeError.unexpectedField
    }
    return object
}

private func strictJSONObject(_ data: Data) throws -> [String: Any] {
    guard data.count <= LengthPrefixedFraming.maximumPayloadBytes,
        let value = try? JSONSerialization.jsonObject(with: data),
        let object = value as? [String: Any]
    else {
        throw data.count > LengthPrefixedFraming.maximumPayloadBytes
            ? IPCWireDecodeError.messageTooLarge : IPCWireDecodeError.malformed
    }
    return object
}
