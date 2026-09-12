import CopilotMicroCore
import Foundation

public enum SessionObservationCompatibilityStatus: String, Codable, CaseIterable, Sendable {
    case qualifiedReadOnly
    case unqualified
}

public struct SessionObservationCompatibility: Codable, Equatable, Sendable {
    public static let qualifiedCLIVersion = "1.0.84-5"
    public static let qualifiedSDKVersion = "1.0.13-preview.4"

    public let status: SessionObservationCompatibilityStatus
    public let cliVersion: String
    public let sdkVersion: String
    public let reason: String

    public init(
        status: SessionObservationCompatibilityStatus,
        cliVersion: String,
        sdkVersion: String,
        reason: String
    ) {
        self.status = status
        self.cliVersion = cliVersion
        self.sdkVersion = sdkVersion
        self.reason = reason
    }

    public var isQualifiedReadOnly: Bool {
        status == .qualifiedReadOnly
            && cliVersion == Self.qualifiedCLIVersion
            && sdkVersion == "host-provided"
    }
}

public struct SessionHostCapabilities: Codable, Equatable, Sendable {
    public let elicitation: Bool
    public let canvases: Bool
    public let mcpApps: Bool

    public init(elicitation: Bool, canvases: Bool, mcpApps: Bool) {
        self.elicitation = elicitation
        self.canvases = canvases
        self.mcpApps = mcpApps
    }

    public static let unavailable = SessionHostCapabilities(
        elicitation: false,
        canvases: false,
        mcpApps: false
    )
}

public struct SessionModelChoice: Codable, Equatable, Sendable {
    public let id: String
    public let reasoningEffort: Bool
    public let supportedReasoningEfforts: [String]

    public init(
        id: String,
        reasoningEffort: Bool,
        supportedReasoningEfforts: [String]
    ) {
        self.id = id
        self.reasoningEffort = reasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
    }
}

public struct SessionModelState: Codable, Equatable, Sendable {
    public let known: Bool
    public let modelID: String?
    public let reasoningEffort: String?
    public let contextTier: String?
    public let availableModels: [SessionModelChoice]

    public init(
        known: Bool,
        modelID: String?,
        reasoningEffort: String?,
        contextTier: String?,
        availableModels: [SessionModelChoice]
    ) {
        self.known = known
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.contextTier = contextTier
        self.availableModels = availableModels
    }

    public static let unknown = SessionModelState(
        known: false,
        modelID: nil,
        reasoningEffort: nil,
        contextTier: nil,
        availableModels: []
    )

    enum CodingKeys: String, CodingKey {
        case known
        case modelID = "modelId"
        case reasoningEffort
        case contextTier
        case availableModels
    }
}

public struct SessionObservationWorkState: Codable, Equatable, Sendable {
    public let known: Bool
    public let foregroundActive: Bool
    public let backgroundCount: Int
    public let queuedCount: Int

    public init(
        known: Bool,
        foregroundActive: Bool,
        backgroundCount: Int,
        queuedCount: Int
    ) {
        self.known = known
        self.foregroundActive = foregroundActive
        self.backgroundCount = backgroundCount
        self.queuedCount = queuedCount
    }

    public func coreState() throws -> WorkState {
        guard known else {
            return .unknown
        }
        return try WorkState(
            foregroundActive: foregroundActive,
            backgroundCount: backgroundCount,
            queuedCount: queuedCount
        )
    }
}

public struct SessionObservationAttentionState: Codable, Equatable, Sendable {
    public let known: Bool
    public let permissionCount: Int
    public let otherCount: Int

    public init(known: Bool, permissionCount: Int, otherCount: Int) {
        self.known = known
        self.permissionCount = permissionCount
        self.otherCount = otherCount
    }

    public func coreState() throws -> AttentionState {
        guard known else {
            return .unknown
        }
        return try AttentionState(
            permissionCount: permissionCount,
            otherCount: otherCount
        )
    }
}

public struct SessionObservationFailure: Codable, Equatable, Sendable {
    public let id: ErrorID
    public let category: SessionErrorCategory

    public init(id: ErrorID, category: SessionErrorCategory) {
        self.id = id
        self.category = category
    }

    public var coreFailure: SessionFailure {
        SessionFailure(id: id, category: category)
    }
}

public struct SessionObservationSnapshot: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public enum MessageType: String, Codable, Sendable {
        case sessionSnapshot
    }

    public let protocolVersion: Int
    public let messageType: MessageType
    public let instanceID: CLIInstanceID
    public let sessionID: SessionID
    public let generation: ConnectionGeneration
    public let contextRevision: UInt64
    public let connection: ConnectionState
    public let paused: Bool
    public let mode: SessionMode?
    public let work: SessionObservationWorkState
    public let pendingAttention: [PendingAttention]
    public let attention: SessionObservationAttentionState
    public let capabilities: [ActionID: Capability]
    public let hostCapabilities: SessionHostCapabilities
    public let model: SessionModelState
    public let compatibility: SessionObservationCompatibility
    public let visiblePermissionRequestID: RequestID?
    public let failure: SessionObservationFailure?
    public let completionID: CompletionID?

    public var binding: LiveBinding {
        LiveBinding(
            instanceID: instanceID,
            sessionID: sessionID,
            generation: generation
        )
    }

    public func coreSnapshot() throws -> SessionSnapshot {
        SessionSnapshot(
            mode: mode.map(SessionModeState.known) ?? .unknown,
            work: try work.coreState(),
            pendingAttention: Set(pendingAttention),
            attention: try attention.coreState(),
            failure: failure?.coreFailure,
            unacknowledgedCompletionID: completionID
        )
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case messageType
        case instanceID = "instanceId"
        case sessionID = "sessionId"
        case generation
        case contextRevision
        case connection
        case paused
        case mode
        case work
        case pendingAttention
        case attention
        case capabilities
        case hostCapabilities
        case model
        case compatibility
        case visiblePermissionRequestID = "visiblePermissionRequestId"
        case failure
        case completionID = "completionId"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        messageType = try container.decode(MessageType.self, forKey: .messageType)
        instanceID = try container.decode(CLIInstanceID.self, forKey: .instanceID)
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        generation = try container.decode(ConnectionGeneration.self, forKey: .generation)
        contextRevision = try container.decode(UInt64.self, forKey: .contextRevision)
        connection = try container.decode(ConnectionState.self, forKey: .connection)
        paused = try container.decode(Bool.self, forKey: .paused)
        mode = try container.decodeIfPresent(SessionMode.self, forKey: .mode)
        work = try container.decode(SessionObservationWorkState.self, forKey: .work)
        pendingAttention = try container.decode([PendingAttention].self, forKey: .pendingAttention)
        attention = try container.decode(SessionObservationAttentionState.self, forKey: .attention)
        let rawCapabilities = try container.decode(
            [String: Capability].self,
            forKey: .capabilities
        )
        capabilities = try Dictionary(
            uniqueKeysWithValues: rawCapabilities.map { key, value in
                guard let action = ActionID(rawValue: key) else {
                    throw IPCWireDecodeError.invalidPayload
                }
                return (action, value)
            }
        )
        hostCapabilities = try container.decode(
            SessionHostCapabilities.self,
            forKey: .hostCapabilities
        )
        model = try container.decode(SessionModelState.self, forKey: .model)
        compatibility = try container.decode(
            SessionObservationCompatibility.self,
            forKey: .compatibility
        )
        visiblePermissionRequestID = try container.decodeIfPresent(
            RequestID.self,
            forKey: .visiblePermissionRequestID
        )
        failure = try container.decodeIfPresent(
            SessionObservationFailure.self,
            forKey: .failure
        )
        completionID = try container.decodeIfPresent(
            CompletionID.self,
            forKey: .completionID
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(messageType, forKey: .messageType)
        try container.encode(instanceID, forKey: .instanceID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(generation, forKey: .generation)
        try container.encode(contextRevision, forKey: .contextRevision)
        try container.encode(connection, forKey: .connection)
        try container.encode(paused, forKey: .paused)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encode(work, forKey: .work)
        try container.encode(pendingAttention, forKey: .pendingAttention)
        try container.encode(attention, forKey: .attention)
        try container.encode(
            Dictionary(
                uniqueKeysWithValues: capabilities.map { ($0.key.rawValue, $0.value) }
            ),
            forKey: .capabilities
        )
        try container.encode(hostCapabilities, forKey: .hostCapabilities)
        try container.encode(model, forKey: .model)
        try container.encode(compatibility, forKey: .compatibility)
        try container.encodeIfPresent(
            visiblePermissionRequestID,
            forKey: .visiblePermissionRequestID
        )
        try container.encodeIfPresent(failure, forKey: .failure)
        try container.encodeIfPresent(completionID, forKey: .completionID)
    }
}

public enum SessionObservationEventReason: String, Codable, CaseIterable, Sendable {
    case activity
    case attention
    case backgroundTasks
    case capabilities
    case hostError
    case lifecycle
    case mode
    case model
    case queue
}

public struct SessionObservationEvent: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public enum MessageType: String, Codable, Sendable {
        case sessionEvent
    }

    public let protocolVersion: Int
    public let messageType: MessageType
    public let instanceID: CLIInstanceID
    public let sessionID: SessionID
    public let generation: ConnectionGeneration
    public let contextRevision: UInt64
    public let reason: SessionObservationEventReason

    public var binding: LiveBinding {
        LiveBinding(
            instanceID: instanceID,
            sessionID: sessionID,
            generation: generation
        )
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case messageType
        case instanceID = "instanceId"
        case sessionID = "sessionId"
        case generation
        case contextRevision
        case reason
    }
}

public struct SessionObservationHeartbeat: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public enum MessageType: String, Codable, Sendable {
        case heartbeat
    }

    public let protocolVersion: Int
    public let messageType: MessageType
    public let instanceID: CLIInstanceID
    public let sessionID: SessionID
    public let generation: ConnectionGeneration
    public let contextRevision: UInt64

    public var binding: LiveBinding {
        LiveBinding(
            instanceID: instanceID,
            sessionID: sessionID,
            generation: generation
        )
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case messageType
        case instanceID = "instanceId"
        case sessionID = "sessionId"
        case generation
        case contextRevision
    }
}

public enum SessionObservationPayloadCodec {
    public static func decodeSnapshot(_ data: Data) throws -> SessionObservationSnapshot {
        try decode(
            SessionObservationSnapshot.self,
            from: data,
            protocolVersion: SessionObservationSnapshot.protocolVersion,
            messageType: SessionObservationSnapshot.MessageType.sessionSnapshot.rawValue
        )
    }

    public static func decodeEvent(_ data: Data) throws -> SessionObservationEvent {
        try decode(
            SessionObservationEvent.self,
            from: data,
            protocolVersion: SessionObservationEvent.protocolVersion,
            messageType: SessionObservationEvent.MessageType.sessionEvent.rawValue
        )
    }

    public static func decodeHeartbeat(_ data: Data) throws -> SessionObservationHeartbeat {
        try decode(
            SessionObservationHeartbeat.self,
            from: data,
            protocolVersion: SessionObservationHeartbeat.protocolVersion,
            messageType: SessionObservationHeartbeat.MessageType.heartbeat.rawValue
        )
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        protocolVersion: Int,
        messageType: String
    ) throws -> Value {
        let object = try strictObservationObject(data)
        guard object["protocolVersion"] as? Int == protocolVersion else {
            throw IPCWireDecodeError.unsupportedProtocol
        }
        guard object["messageType"] as? String == messageType else {
            throw IPCWireDecodeError.invalidMessageType
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw IPCWireDecodeError.invalidPayload
        }
    }
}

private func strictObservationObject(_ data: Data) throws -> [String: Any] {
    guard data.count <= LengthPrefixedFraming.maximumPayloadBytes,
        let value = try? JSONSerialization.jsonObject(with: data),
        let object = value as? [String: Any]
    else {
        throw data.count > LengthPrefixedFraming.maximumPayloadBytes
            ? IPCWireDecodeError.messageTooLarge : IPCWireDecodeError.malformed
    }
    return object
}
