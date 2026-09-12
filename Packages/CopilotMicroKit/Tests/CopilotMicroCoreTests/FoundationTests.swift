import CopilotMicroCore
import Foundation
import Testing

@Suite("Core build metadata and emulator-only invariants")
struct FoundationTests {
    private var appDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../App", isDirectory: true)
            .standardizedFileURL
    }

    @Test("The actual app metadata agrees with the Core build identity")
    func appMetadataMatchesCore() throws {
        let data = try Data(contentsOf: appDirectory.appendingPathComponent("Info.plist"))
        let metadata = try PropertyListDecoder().decode(AppMetadata.self, from: data)
        #expect(metadata.productName == BuildIdentity.productName)
        #expect(metadata.bundleIdentifier == BuildIdentity.bundleIdentifier)
        #expect(metadata.version == BuildIdentity.version)
        #expect(metadata.bundleType == "APPL")
        #expect(metadata.minimumMacOS == "26.0")
        #expect(metadata.menuBarApplication)
    }

    @Test("The app resource permits only the emulator assembly")
    func shippedResourceIsEmulatorOnly() throws {
        let data = try Data(contentsOf: appDirectory.appendingPathComponent("Resources/foundation.json"))
        let configuration = try JSONDecoder().decode(EmulatorConfiguration.self, from: data)
        try configuration.validate()
        #expect(configuration.schemaVersion == 1)
        #expect(configuration.mode == .emulator)
        #expect(!configuration.liveIntegrationsEnabled)
    }

    @Test("Unknown schemas fail before a configuration can be used", arguments: [-1, 0, 2, 999])
    func unsupportedSchemaIsRejected(schemaVersion: Int) throws {
        let configuration = try decode(ConfigurationInput(schemaVersion: schemaVersion))
        #expect(throws: EmulatorConfiguration.ValidationError.unsupportedSchema) {
            try configuration.validate()
        }
    }

    @Test("Enabling live integrations is rejected even when the mode says emulator")
    func liveIntegrationsAreForbidden() throws {
        let configuration = try decode(ConfigurationInput(liveIntegrationsEnabled: true))
        #expect(throws: EmulatorConfiguration.ValidationError.liveIntegrationsForbidden) {
            try configuration.validate()
        }
    }

    @Test("A live or unknown assembly cannot be decoded", arguments: ["live", "production", ""])
    func unsupportedModeIsRejected(mode: String) throws {
        #expect(throws: DecodingError.self) {
            try decode(ConfigurationInput(mode: mode))
        }
    }

    @Test("Missing or mistyped safety fields are not given permissive defaults", arguments: [
        #"{"mode":"emulator","liveIntegrationsEnabled":false}"#,
        #"{"schemaVersion":1,"mode":"emulator"}"#,
        #"{"schemaVersion":1,"liveIntegrationsEnabled":false}"#,
        #"{"schemaVersion":1,"mode":"emulator","liveIntegrationsEnabled":"false"}"#,
        #"{"schemaVersion":"1","mode":"emulator","liveIntegrationsEnabled":false}"#,
    ])
    func malformedConfigurationIsRejected(json: String) throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EmulatorConfiguration.self, from: Data(json.utf8))
        }
    }

    private func decode(_ input: ConfigurationInput) throws -> EmulatorConfiguration {
        try JSONDecoder().decode(EmulatorConfiguration.self, from: JSONEncoder().encode(input))
    }
}

private struct ConfigurationInput: Encodable {
    var schemaVersion = 1
    var mode = "emulator"
    var liveIntegrationsEnabled = false
}

private struct AppMetadata: Decodable {
    let productName: String
    let bundleIdentifier: String
    let version: String
    let bundleType: String
    let minimumMacOS: String
    let menuBarApplication: Bool

    enum CodingKeys: String, CodingKey {
        case productName = "CFBundleDisplayName"
        case bundleIdentifier = "CFBundleIdentifier"
        case version = "CFBundleShortVersionString"
        case bundleType = "CFBundlePackageType"
        case minimumMacOS = "LSMinimumSystemVersion"
        case menuBarApplication = "LSUIElement"
    }
}
