import Foundation

public enum ActionID: String, Codable, CaseIterable, Hashable, Sendable {
    case openSessionList = "session.openList"
    case createSession = "session.create"
    case previousSession = "session.previous"
    case nextSession = "session.next"
    case archiveSession = "session.archive"
    case cycleMode = "session.cycleMode"
    case selectModel = "session.selectModel"
    case selectEffort = "session.selectEffort"
    case voice = "session.voice"
    case cancelForeground = "session.cancelForeground"
    case submitComposer = "composer.submit"
    case focusComposer = "composer.focus"
    case confirmPicker = "picker.confirm"
    case backPicker = "picker.back"
    case approvePermissionOnce = "permission.approveOnce"
    case rejectPermission = "permission.reject"

    public var requiresPermissionRequest: Bool {
        self == .approvePermissionOnce || self == .rejectPermission
    }
}

public struct LiveBinding: Codable, Equatable, Hashable, Sendable {
    public let instanceID: CLIInstanceID
    public let sessionID: SessionID
    public let generation: ConnectionGeneration

    public init(instanceID: CLIInstanceID, sessionID: SessionID, generation: ConnectionGeneration) {
        self.instanceID = instanceID
        self.sessionID = sessionID
        self.generation = generation
    }
}

public struct ActionPayload: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidPermissionRequestArgument
    }

    public let type: ActionID
    public let permissionRequestID: RequestID?

    public init(type: ActionID, permissionRequestID: RequestID? = nil) throws {
        guard type.requiresPermissionRequest == (permissionRequestID != nil) else {
            throw ValidationError.invalidPermissionRequestArgument
        }
        self.type = type
        self.permissionRequestID = permissionRequestID
    }

    enum CodingKeys: String, CodingKey {
        case type
        case permissionRequestID = "permissionRequestId"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            type: container.decode(ActionID.self, forKey: .type),
            permissionRequestID: container.decodeIfPresent(RequestID.self, forKey: .permissionRequestID)
        )
    }
}

public struct ActionRequest: Codable, Equatable, Sendable {
    public static let protocolVersion = 1
    public static let maximumEncodedBytes = 65_536
    public static let maximumContextRevision: UInt64 = 9_007_199_254_740_991

    public enum MessageType: String, Codable, Sendable {
        case action
    }

    public let protocolVersion: Int
    public let messageType: MessageType
    public let requestID: RequestID
    public let instanceID: CLIInstanceID
    public let sessionID: SessionID
    public let generation: ConnectionGeneration
    public let contextRevision: UInt64
    public let action: ActionPayload

    public init(
        requestID: RequestID,
        binding: LiveBinding,
        contextRevision: UInt64,
        action: ActionPayload
    ) {
        protocolVersion = Self.protocolVersion
        messageType = .action
        self.requestID = requestID
        instanceID = binding.instanceID
        sessionID = binding.sessionID
        generation = binding.generation
        self.contextRevision = contextRevision
        self.action = action
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case messageType
        case requestID = "requestId"
        case instanceID = "instanceId"
        case sessionID = "sessionId"
        case generation
        case contextRevision
        case action
    }
}

public enum ActionRequestDecodeError: String, Error, Equatable, Sendable {
    case malformed
    case messageTooLarge
    case unexpectedField
    case unsupportedProtocol
    case invalidMessageType
    case unsupportedAction
    case invalidArguments
}

public enum ActionRequestDecoder {
    private static let envelopeKeys: Set<String> = [
        "protocolVersion",
        "messageType",
        "requestId",
        "instanceId",
        "sessionId",
        "generation",
        "contextRevision",
        "action",
    ]
    private static let actionKeys: Set<String> = ["type", "permissionRequestId"]

    public static func decode(_ data: Data) throws -> ActionRequest {
        guard data.count <= ActionRequest.maximumEncodedBytes else {
            throw ActionRequestDecodeError.messageTooLarge
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let envelope = object as? [String: Any],
            let action = envelope["action"] as? [String: Any]
        else {
            throw ActionRequestDecodeError.malformed
        }
        guard envelopeKeys.isSubset(of: Set(envelope.keys)) else {
            throw ActionRequestDecodeError.malformed
        }
        guard Set(envelope.keys).isSubset(of: envelopeKeys) else {
            throw ActionRequestDecodeError.unexpectedField
        }
        guard Set(action.keys).isSubset(of: actionKeys) else {
            throw ActionRequestDecodeError.unexpectedField
        }
        guard action["type"] is String else {
            throw ActionRequestDecodeError.malformed
        }
        guard envelope["protocolVersion"] as? Int == ActionRequest.protocolVersion else {
            throw ActionRequestDecodeError.unsupportedProtocol
        }
        guard envelope["messageType"] as? String == ActionRequest.MessageType.action.rawValue else {
            throw ActionRequestDecodeError.invalidMessageType
        }
        guard
            let contextRevision = envelope["contextRevision"] as? UInt64,
            contextRevision <= ActionRequest.maximumContextRevision
        else {
            throw ActionRequestDecodeError.malformed
        }
        guard
            let actionName = action["type"] as? String,
            let actionID = ActionID(rawValue: actionName)
        else {
            throw ActionRequestDecodeError.unsupportedAction
        }
        let hasPermissionRequest = action["permissionRequestId"] != nil
        guard hasPermissionRequest == actionID.requiresPermissionRequest else {
            throw ActionRequestDecodeError.invalidArguments
        }
        if hasPermissionRequest {
            guard
                let value = action["permissionRequestId"] as? String,
                (try? RequestID(rawValue: value)) != nil
            else {
                throw ActionRequestDecodeError.invalidArguments
            }
        }
        do {
            return try JSONDecoder().decode(ActionRequest.self, from: data)
        } catch {
            throw ActionRequestDecodeError.malformed
        }
    }
}

public struct ActionContext: Sendable {
    public let binding: LiveBinding?
    public let connection: ConnectionState
    public let isPaused: Bool
    public let contextRevision: UInt64
    public let capabilities: [ActionID: Capability]
    public let pendingRequestIDs: Set<RequestID>
    public let visiblePermissionRequestID: RequestID?

    public init(
        binding: LiveBinding?,
        connection: ConnectionState,
        isPaused: Bool,
        contextRevision: UInt64,
        capabilities: [ActionID: Capability],
        pendingRequestIDs: Set<RequestID> = [],
        visiblePermissionRequestID: RequestID? = nil
    ) {
        self.binding = binding
        self.connection = connection
        self.isPaused = isPaused
        self.contextRevision = contextRevision
        self.capabilities = capabilities
        self.pendingRequestIDs = pendingRequestIDs
        self.visiblePermissionRequestID = visiblePermissionRequestID
    }
}

public enum ActionRejectionCode: String, Codable, Error, Equatable, Sendable {
    case paused
    case disconnected
    case unsynchronized
    case staleInstance
    case staleSession
    case staleGeneration
    case staleContext
    case capabilityUnavailable
    case capabilityBlocked
    case capabilityUnknown
    case missingPermissionRequest
    case permissionRequestNotPending
    case permissionRequestNotVisible
    case duplicateRequest
    case replayLedgerFull
}

public enum ActionGuard {
    public static func validate(_ request: ActionRequest, against context: ActionContext) -> ActionRejectionCode? {
        guard !context.isPaused else {
            return .paused
        }
        guard context.connection != .disconnected else {
            return .disconnected
        }
        guard context.connection == .ready, let binding = context.binding else {
            return .unsynchronized
        }
        guard request.instanceID == binding.instanceID else {
            return .staleInstance
        }
        guard request.sessionID == binding.sessionID else {
            return .staleSession
        }
        guard request.generation == binding.generation else {
            return .staleGeneration
        }
        guard request.contextRevision == context.contextRevision else {
            return .staleContext
        }
        switch context.capabilities[request.action.type]?.status ?? .unknown {
        case .supported:
            break
        case .unavailable:
            return .capabilityUnavailable
        case .blocked:
            return .capabilityBlocked
        case .unknown:
            return .capabilityUnknown
        }
        guard request.action.type.requiresPermissionRequest else {
            return nil
        }
        guard let permissionRequestID = request.action.permissionRequestID else {
            return .missingPermissionRequest
        }
        guard context.pendingRequestIDs.contains(permissionRequestID) else {
            return .permissionRequestNotPending
        }
        guard context.visiblePermissionRequestID == permissionRequestID else {
            return .permissionRequestNotVisible
        }
        return nil
    }
}

public enum ActionReservation: Equatable, Sendable {
    case reserved
    case rejected(ActionRejectionCode)
}

public struct ActionReplayLedger: Sendable {
    public static let maximumTrackedRequests = 4_096

    private var generation: ConnectionGeneration?
    private var inFlight: Set<RequestID> = []
    private var completed: Set<RequestID> = []

    public init() {}

    public mutating func reserve(_ request: ActionRequest, against context: ActionContext) -> ActionReservation {
        if let rejection = ActionGuard.validate(request, against: context) {
            return .rejected(rejection)
        }
        if let generation, generation != request.generation {
            return .rejected(.staleGeneration)
        }
        if generation == nil {
            generation = request.generation
        }
        guard !inFlight.contains(request.requestID), !completed.contains(request.requestID) else {
            return .rejected(.duplicateRequest)
        }
        guard inFlight.count + completed.count < Self.maximumTrackedRequests else {
            return .rejected(.replayLedgerFull)
        }
        inFlight.insert(request.requestID)
        return .reserved
    }

    @discardableResult
    public mutating func complete(_ requestID: RequestID) -> Bool {
        guard inFlight.remove(requestID) != nil else {
            return false
        }
        completed.insert(requestID)
        return true
    }

    @discardableResult
    public mutating func invalidate(for newGeneration: ConnectionGeneration?) -> Bool {
        guard newGeneration != generation else {
            return false
        }
        generation = newGeneration
        inFlight.removeAll()
        completed.removeAll()
        return true
    }
}

public enum ActionOutcome: String, Codable, CaseIterable, Sendable {
    case accepted
    case completed
    case rejected
    case failed
}

public enum ActionResultCode: String, Codable, CaseIterable, Sendable {
    case focusConsumed
    case paused
    case disconnected
    case unsynchronized
    case staleInstance
    case staleSession
    case staleGeneration
    case staleContext
    case capabilityUnavailable
    case capabilityBlocked
    case capabilityUnknown
    case invalidRequest
    case permissionRequestNotPending
    case permissionRequestNotVisible
    case timedOut
    case hostRejected
    case transportFailure
    case alreadyResolved
    case duplicateRequest
    case replayLedgerFull
}

public struct ActionResult: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case emptyMessage
        case messageTooLong
        case unsupportedProtocol
        case invalidMessageType
    }

    public enum MessageType: String, Codable, Sendable {
        case actionResult
    }

    public static let protocolVersion = 1
    public static let maximumEncodedBytes = 65_536
    public static let maximumMessageCharacters = 512
    public let protocolVersion: Int
    public let messageType: MessageType
    public let requestID: RequestID
    public let outcome: ActionOutcome
    public let code: ActionResultCode?
    public let message: String

    public init(
        requestID: RequestID,
        outcome: ActionOutcome,
        code: ActionResultCode? = nil,
        message: String
    ) throws {
        guard !message.isEmpty else {
            throw ValidationError.emptyMessage
        }
        guard message.unicodeScalars.count <= Self.maximumMessageCharacters else {
            throw ValidationError.messageTooLong
        }

        protocolVersion = Self.protocolVersion
        messageType = .actionResult
        self.requestID = requestID
        self.outcome = outcome
        self.code = code
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case messageType
        case requestID = "requestId"
        case outcome
        case code
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .protocolVersion) == Self.protocolVersion else {
            throw ValidationError.unsupportedProtocol
        }
        guard try container.decode(MessageType.self, forKey: .messageType) == .actionResult else {
            throw ValidationError.invalidMessageType
        }
        try self.init(
            requestID: container.decode(RequestID.self, forKey: .requestID),
            outcome: container.decode(ActionOutcome.self, forKey: .outcome),
            code: container.decodeIfPresent(ActionResultCode.self, forKey: .code),
            message: container.decode(String.self, forKey: .message)
        )
    }
}

public enum ActionResultDecoder {
    private static let requiredKeys: Set<String> = [
        "protocolVersion",
        "messageType",
        "requestId",
        "outcome",
        "message",
    ]
    private static let allowedKeys = requiredKeys.union(["code"])

    public static func decode(_ data: Data) throws -> ActionResult {
        guard data.count <= ActionResult.maximumEncodedBytes else {
            throw ActionRequestDecodeError.messageTooLarge
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let envelope = object as? [String: Any]
        else {
            throw ActionRequestDecodeError.malformed
        }
        let keys = Set(envelope.keys)
        guard requiredKeys.isSubset(of: keys) else {
            throw ActionRequestDecodeError.malformed
        }
        guard keys.isSubset(of: allowedKeys) else {
            throw ActionRequestDecodeError.unexpectedField
        }
        if keys.contains("code"), envelope["code"] is NSNull {
            throw ActionRequestDecodeError.malformed
        }
        do {
            return try JSONDecoder().decode(ActionResult.self, from: data)
        } catch let error as ActionResult.ValidationError {
            throw error
        } catch {
            throw ActionRequestDecodeError.malformed
        }
    }
}
