import CopilotMicroCore
import Foundation

public enum GhosttyAssociationEnvironment {
    public static let surfaceTokenKey = "COPILOT_MICRO_SURFACE_TOKEN"
    public static let qualificationResultPathKey =
        "COPILOT_MICRO_ASSOCIATION_RESULT_PATH"
}

public enum GhosttyAssociationError: Error, Equatable, Sendable {
    case duplicateToken
    case invalidExpiration
    case unknownToken
}

public enum GhosttyAssociationClaimOutcome: Equatable, Sendable {
    case pending
    case bound(GhosttyTargetBinding)
    case reconnected(GhosttyTargetBinding)
    case tokenClaimedByAnotherInstance
    case unknownToken
}

public struct GhosttyOpenedSurface: Equatable, Sendable {
    public let associationToken: SurfaceAssociationToken
    public let binding: GhosttyTargetBinding
    public let claimedInstanceID: CLIInstanceID?

    public init(
        associationToken: SurfaceAssociationToken,
        binding: GhosttyTargetBinding,
        claimedInstanceID: CLIInstanceID? = nil
    ) {
        self.associationToken = associationToken
        self.binding = binding
        self.claimedInstanceID = claimedInstanceID
    }
}

public struct GhosttyAssociationProbeResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let surfaceAssociationToken: SurfaceAssociationToken

    public init(
        schemaVersion: Int = 1,
        surfaceAssociationToken: SurfaceAssociationToken
    ) {
        self.schemaVersion = schemaVersion
        self.surfaceAssociationToken = surfaceAssociationToken
    }
}

public actor GhosttyTargetBindingStore {
    private struct Association {
        var binding: GhosttyTargetBinding?
        var instanceID: CLIInstanceID?
        let expiresAtMilliseconds: UInt64
    }

    private var associations: [SurfaceAssociationToken: Association] = [:]
    private var bindings: [CLIInstanceID: GhosttyTargetBinding] = [:]

    public init() {}

    public func reserve(
        _ token: SurfaceAssociationToken,
        expiresAtMilliseconds: UInt64,
        nowMilliseconds: UInt64
    ) throws {
        purgeExpired(nowMilliseconds: nowMilliseconds)
        guard expiresAtMilliseconds > nowMilliseconds else {
            throw GhosttyAssociationError.invalidExpiration
        }
        guard associations[token] == nil else {
            throw GhosttyAssociationError.duplicateToken
        }
        associations[token] = Association(
            binding: nil,
            instanceID: nil,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
    }

    @discardableResult
    public func attach(
        _ binding: GhosttyTargetBinding,
        to token: SurfaceAssociationToken,
        nowMilliseconds: UInt64
    ) throws -> CLIInstanceID? {
        purgeExpired(nowMilliseconds: nowMilliseconds)
        guard var association = associations[token] else {
            throw GhosttyAssociationError.unknownToken
        }
        association.binding = binding
        associations[token] = association
        if let instanceID = association.instanceID {
            bindings[instanceID] = binding
            return instanceID
        }
        return nil
    }

    public func claim(
        _ token: SurfaceAssociationToken,
        for instanceID: CLIInstanceID,
        nowMilliseconds: UInt64
    ) -> GhosttyAssociationClaimOutcome {
        purgeExpired(nowMilliseconds: nowMilliseconds)
        guard var association = associations[token] else {
            return .unknownToken
        }
        if let claimedInstanceID = association.instanceID {
            guard claimedInstanceID == instanceID else {
                return .tokenClaimedByAnotherInstance
            }
            guard let binding = association.binding else {
                return .pending
            }
            bindings[instanceID] = binding
            return .reconnected(binding)
        }
        association.instanceID = instanceID
        associations[token] = association
        guard let binding = association.binding else {
            return .pending
        }
        bindings[instanceID] = binding
        return .bound(binding)
    }

    func bind(_ instanceID: CLIInstanceID, to binding: GhosttyTargetBinding) {
        bindings[instanceID] = binding
    }

    public func binding(for instanceID: CLIInstanceID) -> GhosttyTargetBinding? {
        bindings[instanceID]
    }

    public func cancel(_ token: SurfaceAssociationToken) {
        if let instanceID = associations[token]?.instanceID {
            bindings.removeValue(forKey: instanceID)
        }
        associations.removeValue(forKey: token)
    }

    public func remove(_ instanceID: CLIInstanceID) {
        bindings.removeValue(forKey: instanceID)
        associations = associations.filter { $0.value.instanceID != instanceID }
    }

    public func removeAll() {
        bindings.removeAll()
        associations.removeAll()
    }

    private func purgeExpired(nowMilliseconds: UInt64) {
        let expiredTokens = associations.compactMap { token, association in
            association.binding == nil || association.instanceID == nil
                ? (association.expiresAtMilliseconds <= nowMilliseconds ? token : nil)
                : nil
        }
        for token in expiredTokens {
            if let instanceID = associations[token]?.instanceID {
                bindings.removeValue(forKey: instanceID)
            }
            associations.removeValue(forKey: token)
        }
    }
}
