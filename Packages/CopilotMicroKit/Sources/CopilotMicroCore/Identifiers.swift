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
