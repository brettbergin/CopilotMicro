import CopilotMicroCore
import CopilotMicroTerminal
import Foundation

public struct StoredLightingPreferences: Codable, Equatable, Sendable {
    public var brightness: Double
    public var reducedMotion: Bool

    public init(brightness: Double, reducedMotion: Bool) {
        self.brightness = brightness
        self.reducedMotion = reducedMotion
    }
}

public struct StoredUserPreferences: Codable, Equatable, Sendable {
    public var notificationsEnabled: Bool

    public init(notificationsEnabled: Bool) {
        self.notificationsEnabled = notificationsEnabled
    }
}

public struct StoredTerminalPreferences: Codable, Equatable, Sendable {
    public var preferredBundleIdentifier: String?
    public var preferredApplicationPath: String?
    public var cliExecutableHint: String?

    public init(
        preferredBundleIdentifier: String? = nil,
        preferredApplicationPath: String? = nil,
        cliExecutableHint: String? = nil
    ) {
        self.preferredBundleIdentifier = preferredBundleIdentifier
        self.preferredApplicationPath = preferredApplicationPath
        self.cliExecutableHint = cliExecutableHint
    }

    public init(
        terminalPreference: TerminalPreference?,
        cliExecutablePreference: CLIExecutablePreference?
    ) {
        preferredBundleIdentifier = terminalPreference?.bundleIdentifier
        preferredApplicationPath = terminalPreference?.applicationPath
        cliExecutableHint = cliExecutablePreference?.executablePath
    }

    private enum CodingKeys: String, CodingKey {
        case preferredBundleIdentifier
        case preferredApplicationPath
        case cliExecutableHint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferredBundleIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .preferredBundleIdentifier
        )
        preferredApplicationPath = try container.decodeIfPresent(
            String.self,
            forKey: .preferredApplicationPath
        )
        cliExecutableHint = try container.decodeIfPresent(
            String.self,
            forKey: .cliExecutableHint
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let preferredBundleIdentifier {
            try container.encode(preferredBundleIdentifier, forKey: .preferredBundleIdentifier)
        } else {
            try container.encodeNil(forKey: .preferredBundleIdentifier)
        }
        if let preferredApplicationPath {
            try container.encode(preferredApplicationPath, forKey: .preferredApplicationPath)
        } else {
            try container.encodeNil(forKey: .preferredApplicationPath)
        }
        if let cliExecutableHint {
            try container.encode(cliExecutableHint, forKey: .cliExecutableHint)
        } else {
            try container.encodeNil(forKey: .cliExecutableHint)
        }
    }
}

public struct StoredConfiguration: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let product = "Copilot Micro"
    public static let maximumRecentProjectDirectories = 20

    public var schemaVersion: Int
    public var product: String
    public var bindings: [PhysicalControlID: ActionID]
    public var lighting: StoredLightingPreferences
    public var preferences: StoredUserPreferences
    public var terminal: StoredTerminalPreferences
    public var recentProjectDirectories: [String]

    public init(
        bindings: [PhysicalControlID: ActionID] = Self.defaultBindings,
        lighting: StoredLightingPreferences = StoredLightingPreferences(
            brightness: Brightness.defaultValue.value,
            reducedMotion: false
        ),
        preferences: StoredUserPreferences = StoredUserPreferences(notificationsEnabled: false),
        terminal: StoredTerminalPreferences = StoredTerminalPreferences(),
        recentProjectDirectories: [String] = []
    ) {
        schemaVersion = Self.schemaVersion
        product = Self.product
        self.bindings = bindings
        self.lighting = lighting
        self.preferences = preferences
        self.terminal = terminal
        self.recentProjectDirectories = recentProjectDirectories
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case product
        case bindings
        case lighting
        case preferences
        case terminal
        case recentProjectDirectories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        product = try container.decode(String.self, forKey: .product)
        bindings = try decodeBindings(
            container.decode([String: ActionID].self, forKey: .bindings)
        )
        lighting = try container.decode(StoredLightingPreferences.self, forKey: .lighting)
        preferences = try container.decode(StoredUserPreferences.self, forKey: .preferences)
        terminal = try container.decode(StoredTerminalPreferences.self, forKey: .terminal)
        recentProjectDirectories = try container.decode(
            [String].self,
            forKey: .recentProjectDirectories
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(product, forKey: .product)
        try container.encode(encodeBindings(bindings), forKey: .bindings)
        try container.encode(lighting, forKey: .lighting)
        try container.encode(preferences, forKey: .preferences)
        try container.encode(terminal, forKey: .terminal)
        try container.encode(recentProjectDirectories, forKey: .recentProjectDirectories)
    }

    public static var defaultBindings: [PhysicalControlID: ActionID] {
        Dictionary(
            uniqueKeysWithValues: PhysicalLayout.creatorMicro2Pro.map { ($0.id, $0.defaultAction) }
        )
    }
}

public struct PortableConfiguration: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let product = "Copilot Micro"

    public var schemaVersion: Int
    public var product: String
    public var bindings: [PhysicalControlID: ActionID]
    public var lighting: StoredLightingPreferences
    public var preferences: StoredUserPreferences

    public init(configuration: StoredConfiguration) {
        schemaVersion = Self.schemaVersion
        product = Self.product
        bindings = configuration.bindings
        lighting = configuration.lighting
        preferences = configuration.preferences
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case product
        case bindings
        case lighting
        case preferences
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        product = try container.decode(String.self, forKey: .product)
        bindings = try decodeBindings(
            container.decode([String: ActionID].self, forKey: .bindings)
        )
        lighting = try container.decode(StoredLightingPreferences.self, forKey: .lighting)
        preferences = try container.decode(StoredUserPreferences.self, forKey: .preferences)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(product, forKey: .product)
        try container.encode(encodeBindings(bindings), forKey: .bindings)
        try container.encode(lighting, forKey: .lighting)
        try container.encode(preferences, forKey: .preferences)
    }
}

public struct BindingImportChange: Equatable, Sendable {
    public let control: PhysicalControlID
    public let currentAction: ActionID
    public let importedAction: ActionID

    public init(control: PhysicalControlID, currentAction: ActionID, importedAction: ActionID) {
        self.control = control
        self.currentAction = currentAction
        self.importedAction = importedAction
    }
}

private func decodeBindings(
    _ bindings: [String: ActionID]
) throws -> [PhysicalControlID: ActionID] {
    var decoded: [PhysicalControlID: ActionID] = [:]
    for (key, action) in bindings {
        guard let control = PhysicalControlID(rawValue: key) else {
            throw ConfigurationError.incompleteBindings
        }
        decoded[control] = action
    }
    return decoded
}

private func encodeBindings(
    _ bindings: [PhysicalControlID: ActionID]
) -> [String: ActionID] {
    Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
}

public struct ConfigurationImportPlan: Equatable, Sendable {
    public let baseConfiguration: StoredConfiguration
    public let portableConfiguration: PortableConfiguration
    public let bindingChanges: [BindingImportChange]
    public let brightnessChanged: Bool
    public let reducedMotionChanged: Bool
    public let notificationsChanged: Bool

    public init(
        baseConfiguration: StoredConfiguration,
        portableConfiguration: PortableConfiguration
    ) {
        self.baseConfiguration = baseConfiguration
        self.portableConfiguration = portableConfiguration
        bindingChanges = PhysicalControlID.allCases.compactMap { control in
            guard
                let current = baseConfiguration.bindings[control],
                let imported = portableConfiguration.bindings[control],
                current != imported
            else {
                return nil
            }
            return BindingImportChange(
                control: control,
                currentAction: current,
                importedAction: imported
            )
        }
        brightnessChanged =
            baseConfiguration.lighting.brightness != portableConfiguration.lighting.brightness
        reducedMotionChanged =
            baseConfiguration.lighting.reducedMotion
            != portableConfiguration.lighting.reducedMotion
        notificationsChanged =
            baseConfiguration.preferences.notificationsEnabled
            != portableConfiguration.preferences.notificationsEnabled
    }

    public var hasChanges: Bool {
        !bindingChanges.isEmpty || brightnessChanged || reducedMotionChanged || notificationsChanged
    }

    public func applying(to current: StoredConfiguration) throws -> StoredConfiguration {
        guard current == baseConfiguration else {
            throw ConfigurationError.staleImportPreview
        }
        var applied = current
        applied.bindings = portableConfiguration.bindings
        applied.lighting = portableConfiguration.lighting
        applied.preferences = portableConfiguration.preferences
        return applied
    }
}

public enum ConfigurationError: Error, Equatable, Sendable {
    case messageTooLarge
    case malformed
    case unexpectedField
    case unsupportedSchema(Int)
    case wrongProduct
    case incompleteBindings
    case unsupportedAction
    case invalidBrightness
    case invalidString
    case tooManyRecentProjects
    case duplicateRecentProject
    case staleImportPreview
    case missingConfiguration
    case fileSystem

    public var userMessage: String {
        switch self {
        case .messageTooLarge:
            "The configuration exceeds the 1 MiB safety limit."
        case .malformed:
            "The configuration is not valid JSON."
        case .unexpectedField:
            "The configuration contains unsupported fields."
        case .unsupportedSchema(let version):
            "Configuration schema \(version) is not supported."
        case .wrongProduct:
            "The file is not a Copilot Micro configuration."
        case .incompleteBindings:
            "Every physical control must have one supported action."
        case .unsupportedAction:
            "The configuration contains an unsupported action assignment."
        case .invalidBrightness:
            "Brightness must be a finite value from 0 through 1."
        case .invalidString:
            "A stored terminal or directory value is invalid."
        case .tooManyRecentProjects:
            "At most 20 recent project directories may be stored."
        case .duplicateRecentProject:
            "Recent project directories must be unique."
        case .staleImportPreview:
            "Settings changed after the import preview. Review the file again."
        case .missingConfiguration:
            "No saved configuration exists."
        case .fileSystem:
            "The local configuration could not be read or written."
        }
    }
}

public enum ConfigurationCodec {
    public static let maximumEncodedBytes = 1_048_576

    private static let localKeys: Set<String> = [
        "schemaVersion",
        "product",
        "bindings",
        "lighting",
        "preferences",
        "terminal",
        "recentProjectDirectories",
    ]
    private static let portableKeys: Set<String> = [
        "schemaVersion",
        "product",
        "bindings",
        "lighting",
        "preferences",
    ]
    private static let lightingKeys: Set<String> = ["brightness", "reducedMotion"]
    private static let preferenceKeys: Set<String> = ["notificationsEnabled"]
    private static let terminalKeys: Set<String> = [
        "preferredBundleIdentifier",
        "preferredApplicationPath",
        "cliExecutableHint",
    ]

    public static func decodeStored(_ data: Data) throws -> StoredConfiguration {
        let root = try object(from: data)
        try requireExactKeys(root, localKeys)
        try requireExactKeys(try dictionary(root["lighting"]), lightingKeys)
        try requireExactKeys(try dictionary(root["preferences"]), preferenceKeys)
        try requireExactKeys(try dictionary(root["terminal"]), terminalKeys)
        try validateBindingObject(root["bindings"])
        let configuration = try decode(StoredConfiguration.self, from: data)
        try validate(configuration)
        return configuration
    }

    public static func decodePortable(
        _ data: Data,
        against current: StoredConfiguration
    ) throws -> ConfigurationImportPlan {
        let root = try object(from: data)
        try requireExactKeys(root, portableKeys)
        try requireExactKeys(try dictionary(root["lighting"]), lightingKeys)
        try requireExactKeys(try dictionary(root["preferences"]), preferenceKeys)
        try validateBindingObject(root["bindings"])
        let portable = try decode(PortableConfiguration.self, from: data)
        try validate(portable)
        return ConfigurationImportPlan(
            baseConfiguration: current,
            portableConfiguration: portable
        )
    }

    public static func encodeStored(_ configuration: StoredConfiguration) throws -> Data {
        try validate(configuration)
        return try encoder().encode(configuration)
    }

    public static func encodePortable(_ configuration: StoredConfiguration) throws -> Data {
        try validate(configuration)
        return try encoder().encode(PortableConfiguration(configuration: configuration))
    }

    public static func validate(_ configuration: StoredConfiguration) throws {
        guard configuration.schemaVersion == StoredConfiguration.schemaVersion else {
            throw ConfigurationError.unsupportedSchema(configuration.schemaVersion)
        }
        guard configuration.product == StoredConfiguration.product else {
            throw ConfigurationError.wrongProduct
        }
        try validateBindings(configuration.bindings)
        try validateLighting(configuration.lighting)
        try validateTerminal(configuration.terminal)
        let recent = configuration.recentProjectDirectories
        guard recent.count <= StoredConfiguration.maximumRecentProjectDirectories else {
            throw ConfigurationError.tooManyRecentProjects
        }
        guard Set(recent).count == recent.count else {
            throw ConfigurationError.duplicateRecentProject
        }
        guard recent.allSatisfy(validPathHint) else {
            throw ConfigurationError.invalidString
        }
    }

    public static func validate(_ configuration: PortableConfiguration) throws {
        guard configuration.schemaVersion == PortableConfiguration.schemaVersion else {
            throw ConfigurationError.unsupportedSchema(configuration.schemaVersion)
        }
        guard configuration.product == PortableConfiguration.product else {
            throw ConfigurationError.wrongProduct
        }
        try validateBindings(configuration.bindings)
        try validateLighting(configuration.lighting)
    }

    private static func validateBindings(_ bindings: [PhysicalControlID: ActionID]) throws {
        guard Set(bindings.keys) == Set(PhysicalControlID.allCases) else {
            throw ConfigurationError.incompleteBindings
        }
    }

    private static func validateBindingObject(_ value: Any?) throws {
        let bindings = try dictionary(value)
        guard Set(bindings.keys) == Set(PhysicalControlID.allCases.map(\.rawValue)) else {
            throw ConfigurationError.incompleteBindings
        }
        for action in bindings.values {
            guard
                let action = action as? String,
                ActionID(rawValue: action) != nil
            else {
                throw ConfigurationError.unsupportedAction
            }
        }
    }

    private static func validateLighting(_ lighting: StoredLightingPreferences) throws {
        guard
            lighting.brightness.isFinite,
            (0...1).contains(lighting.brightness)
        else {
            throw ConfigurationError.invalidBrightness
        }
    }

    private static func validateTerminal(_ terminal: StoredTerminalPreferences) throws {
        guard
            (terminal.preferredBundleIdentifier == nil)
                == (terminal.preferredApplicationPath == nil)
        else {
            throw ConfigurationError.invalidString
        }
        guard validOptionalBundleIdentifier(terminal.preferredBundleIdentifier),
            validOptionalPath(terminal.preferredApplicationPath),
            validOptionalPath(terminal.cliExecutableHint)
        else {
            throw ConfigurationError.invalidString
        }
        if let bundleIdentifier = terminal.preferredBundleIdentifier {
            guard SupportedTerminal(bundleIdentifier: bundleIdentifier) != nil else {
                throw ConfigurationError.invalidString
            }
        }
        if let applicationPath = terminal.preferredApplicationPath {
            guard
                applicationPath.hasPrefix("/"),
                URL(fileURLWithPath: applicationPath).pathExtension.lowercased() == "app"
            else {
                throw ConfigurationError.invalidString
            }
        }
        if let executablePath = terminal.cliExecutableHint {
            guard
                executablePath.hasPrefix("/"),
                URL(fileURLWithPath: executablePath).lastPathComponent == "copilot"
            else {
                throw ConfigurationError.invalidString
            }
        }
    }

    private static func validOptionalBundleIdentifier(_ value: String?) -> Bool {
        guard let value else {
            return true
        }
        return !value.isEmpty && value.utf8.count <= 255
            && value.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                    || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                    || scalar.value == 0x2E || scalar.value == 0x2D
            }
    }

    private static func validOptionalPath(_ value: String?) -> Bool {
        value.map(validPathHint) ?? true
    }

    private static func validPathHint(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4_096
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func object(from data: Data) throws -> [String: Any] {
        guard data.count <= maximumEncodedBytes else {
            throw ConfigurationError.messageTooLarge
        }
        do {
            guard
                let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw ConfigurationError.malformed
            }
            return value
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.malformed
        }
    }

    private static func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw ConfigurationError.malformed
        }
        return value
    }

    private static func requireExactKeys(
        _ object: [String: Any],
        _ keys: Set<String>
    ) throws {
        guard Set(object.keys) == keys else {
            throw ConfigurationError.unexpectedField
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ConfigurationError.malformed
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
