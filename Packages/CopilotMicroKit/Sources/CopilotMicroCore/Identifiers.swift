import Foundation

public enum IdentifierValidationError: Error, Equatable, Sendable {
    case empty
    case tooLong
    case invalidCharacter
}

private func validateIdentifier(_ value: String) throws {
    guard !value.isEmpty else {
        throw IdentifierValidationError.empty
    }
    guard value.utf8.count <= 128 else {
        throw IdentifierValidationError.tooLong
    }
    guard
        value.unicodeScalars.allSatisfy({ scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
        })
    else {
        throw IdentifierValidationError.invalidCharacter
    }
}

public struct CLIInstanceID: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        try validateIdentifier(rawValue)
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

public struct SessionID: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        try validateIdentifier(rawValue)
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

public struct ConnectionGeneration: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        try validateIdentifier(rawValue)
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

public struct SurfaceAssociationToken: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalid
    }

    public let rawValue: String

    public init(rawValue: String) throws {
        guard
            rawValue.utf8.count == 64,
            rawValue.unicodeScalars.allSatisfy({
                (0x30...0x39).contains($0.value) || (0x61...0x66).contains($0.value)
            })
        else {
            throw ValidationError.invalid
        }
        self.rawValue = rawValue
    }

    public static func generate() throws -> SurfaceAssociationToken {
        var generator = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
        return try SurfaceAssociationToken(rawValue: token)
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RequestID: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        try validateIdentifier(rawValue)
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

public struct CompletionID: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        try validateIdentifier(rawValue)
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

public struct ErrorID: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        try validateIdentifier(rawValue)
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
