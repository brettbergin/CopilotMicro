import CopilotMicroCore
import Foundation
import Testing

@Suite("Core build metadata and device assembly invariants")
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

    @Test("The app resource requires the direct device assembly")
    func shippedResourceRequiresDeviceIntegration() throws {
        let data = try Data(contentsOf: appDirectory.appendingPathComponent("Resources/foundation.json"))
        let configuration = try JSONDecoder().decode(ApplicationConfiguration.self, from: data)
        try configuration.validate()
        #expect(configuration.schemaVersion == 1)
        #expect(configuration.mode == .device)
        #expect(configuration.deviceIntegrationEnabled)
    }

    @Test("Unknown schemas fail before a configuration can be used", arguments: [-1, 0, 2, 999])
    func unsupportedSchemaIsRejected(schemaVersion: Int) throws {
        let configuration = try decode(ConfigurationInput(schemaVersion: schemaVersion))
        #expect(throws: ApplicationConfiguration.ValidationError.unsupportedSchema) {
            try configuration.validate()
        }
    }

    @Test("Disabling device integration is rejected")
    func deviceIntegrationIsRequired() throws {
        let configuration = try decode(ConfigurationInput(deviceIntegrationEnabled: false))
        #expect(throws: ApplicationConfiguration.ValidationError.deviceIntegrationRequired) {
            try configuration.validate()
        }
    }

    @Test("An emulator or unknown assembly cannot be decoded", arguments: ["emulator", "production", ""])
    func unsupportedModeIsRejected(mode: String) throws {
        #expect(throws: DecodingError.self) {
            try decode(ConfigurationInput(mode: mode))
        }
    }

    @Test(
        "Missing or mistyped safety fields are not given permissive defaults",
        arguments: [
            #"{"mode":"device","deviceIntegrationEnabled":true}"#,
            #"{"schemaVersion":1,"mode":"device"}"#,
            #"{"schemaVersion":1,"deviceIntegrationEnabled":true}"#,
            #"{"schemaVersion":1,"mode":"device","deviceIntegrationEnabled":"true"}"#,
            #"{"schemaVersion":"1","mode":"device","deviceIntegrationEnabled":true}"#,
        ])
    func malformedConfigurationIsRejected(json: String) throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ApplicationConfiguration.self, from: Data(json.utf8))
        }
    }

    private func decode(_ input: ConfigurationInput) throws -> ApplicationConfiguration {
        try JSONDecoder().decode(ApplicationConfiguration.self, from: JSONEncoder().encode(input))
    }
}

private struct ConfigurationInput: Encodable {
    var schemaVersion = 1
    var mode = "device"
    var deviceIntegrationEnabled = true
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
