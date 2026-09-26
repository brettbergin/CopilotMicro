import CopilotMicroBridge
import Foundation
import Testing

@Suite("Owned Copilot CLI extension installation")
struct BridgeExtensionInstallerTests {
    @Test("Missing confirmation performs no filesystem mutation")
    func requiresConfirmation() async throws {
        try await withFixture { fixture in
            let installer = fixture.installer()

            await #expect(throws: BridgeExtensionInstallerError.authorizationRequired) {
                _ = try await installer.install(authorization: .notConfirmed)
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.copilotHomeURL.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.receiptURL.path))
        }
    }

    @Test("Explicit install records hashes and private ownership")
    func installsOwnedExtension() async throws {
        try await withFixture { fixture in
            let installer = fixture.installer()

            #expect(
                try await installer.inspect()
                    == .notInstalled(destinationURL: fixture.destinationURL)
            )
            #expect(
                try await installer.install(authorization: .userConfirmed)
                    == .installed(
                        version: BridgeExtensionPackage.version,
                        destinationURL: fixture.destinationURL
                    )
            )
            #expect(try permissions(at: fixture.destinationURL) == 0o700)
            for filename in BridgeExtensionPackage.filenames {
                #expect(
                    try permissions(at: fixture.destinationURL.appendingPathComponent(filename))
                        == 0o600
                )
            }
            let receipt = try JSONDecoder().decode(
                BridgeExtensionReceipt.self,
                from: Data(contentsOf: fixture.receiptURL)
            )
            #expect(receipt.extensionName == BridgeExtensionPackage.name)
            #expect(receipt.destinationPath == fixture.destinationURL.path)
            #expect(receipt.installedAtUnixSeconds == 42)
            #expect(Set(receipt.files.map(\.filename)) == Set(BridgeExtensionPackage.filenames))
            #expect(try permissions(at: fixture.receiptURL) == 0o600)
            #expect(
                try await installer.inspect()
                    == .installed(
                        version: BridgeExtensionPackage.version,
                        destinationURL: fixture.destinationURL
                    )
            )
        }
    }

    @Test("Unowned collision is preserved")
    func preservesCollision() async throws {
        try await withFixture { fixture in
            try FileManager.default.createDirectory(
                at: fixture.destinationURL,
                withIntermediateDirectories: true
            )
            let marker = fixture.destinationURL.appendingPathComponent("user-file")
            try Data("preserve".utf8).write(to: marker)
            let installer = fixture.installer()

            #expect(
                try await installer.inspect()
                    == .collision(destinationURL: fixture.destinationURL)
            )
            await #expect(throws: BridgeExtensionInstallerError.collision) {
                _ = try await installer.install(authorization: .userConfirmed)
            }
            #expect(try String(contentsOf: marker, encoding: .utf8) == "preserve")
        }
    }

    @Test("Externally modified owned files are preserved and blocked")
    func preservesModifiedInstallation() async throws {
        try await withFixture { fixture in
            let installer = fixture.installer()
            _ = try await installer.install(authorization: .userConfirmed)
            let extensionURL = fixture.destinationURL.appendingPathComponent("extension.mjs")
            try Data("modified".utf8).write(to: extensionURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: extensionURL.path
            )

            #expect(
                try await installer.inspect()
                    == .modified(destinationURL: fixture.destinationURL)
            )
            await #expect(throws: BridgeExtensionInstallerError.modifiedInstallation) {
                _ = try await installer.install(authorization: .userConfirmed)
            }
            #expect(try String(contentsOf: extensionURL, encoding: .utf8) == "modified")
        }
    }

    @Test("Owned updates swap safely and retain the prior version")
    func updatesOwnedExtension() async throws {
        try await withFixture { fixture in
            let first = fixture.installer(nowUnixSeconds: 42)
            _ = try await first.install(authorization: .userConfirmed)
            let priorContents = try String(
                contentsOf: fixture.destinationURL.appendingPathComponent("extension.mjs"),
                encoding: .utf8
            )
            try Data("export const updated = true;\n".utf8).write(
                to: fixture.packageURL.appendingPathComponent("extension.mjs")
            )

            let second = fixture.installer(nowUnixSeconds: 84)
            #expect(
                try await second.inspect()
                    == .updateAvailable(
                        installedVersion: BridgeExtensionPackage.version,
                        packagedVersion: BridgeExtensionPackage.version,
                        destinationURL: fixture.destinationURL
                    )
            )
            _ = try await second.install(authorization: .userConfirmed)
            #expect(
                try String(
                    contentsOf: fixture.destinationURL.appendingPathComponent("extension.mjs"),
                    encoding: .utf8
                ) == "export const updated = true;\n"
            )
            let backups = try FileManager.default.contentsOfDirectory(
                at: fixture.backupDirectoryURL,
                includingPropertiesForKeys: nil
            )
            #expect(backups.count == 1)
            #expect(
                try String(
                    contentsOf: backups[0].appendingPathComponent("extension.mjs"),
                    encoding: .utf8
                ) == priorContents
            )
        }
    }

    @Test("Project extension shadows are rejected before launch")
    func rejectsProjectShadow() async throws {
        try await withFixture { fixture in
            let project = fixture.rootURL.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(
                at:
                    project
                    .appendingPathComponent(".github/extensions", isDirectory: true)
                    .appendingPathComponent(BridgeExtensionPackage.name, isDirectory: true),
                withIntermediateDirectories: true
            )
            let installer = fixture.installer()

            await #expect(throws: BridgeExtensionInstallerError.projectExtensionCollision) {
                try await installer.requireNoProjectShadow(in: project)
            }
        }
    }

    @Test("Symlinked destination is never followed or replaced")
    func rejectsSymlinkedDestination() async throws {
        try await withFixture { fixture in
            let outside = fixture.rootURL.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: false
            )
            try FileManager.default.createDirectory(
                at: fixture.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: fixture.destinationURL,
                withDestinationURL: outside
            )
            let installer = fixture.installer()

            #expect(
                try await installer.inspect()
                    == .collision(destinationURL: fixture.destinationURL)
            )
            #expect(FileManager.default.fileExists(atPath: outside.path))
        }
    }

    @Test("Writable Copilot parent directories block installation")
    func rejectsWritableParentDirectory() async throws {
        try await withFixture { fixture in
            try FileManager.default.createDirectory(
                at: fixture.copilotHomeURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o777]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o777],
                ofItemAtPath: fixture.copilotHomeURL.path
            )
            let installer = fixture.installer()

            await #expect(throws: BridgeExtensionInstallerError.unsafePath) {
                _ = try await installer.install(authorization: .userConfirmed)
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
        }
    }
}

private struct BridgeExtensionInstallerFixture {
    let rootURL: URL
    let packageURL: URL
    let copilotHomeURL: URL
    let applicationSupportURL: URL

    var destinationURL: URL {
        copilotHomeURL
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(BridgeExtensionPackage.name, isDirectory: true)
    }

    var receiptURL: URL {
        applicationSupportURL.appendingPathComponent(
            BridgeExtensionInstaller.receiptFilename
        )
    }

    var backupDirectoryURL: URL {
        copilotHomeURL.appendingPathComponent(
            BridgeExtensionInstaller.backupDirectoryName,
            isDirectory: true
        )
    }

    func installer(
        nowUnixSeconds: UInt64 = 42
    ) -> BridgeExtensionInstaller {
        BridgeExtensionInstaller(
            packageDirectoryURL: packageURL,
            copilotHomeURL: copilotHomeURL,
            applicationSupportRootURL: applicationSupportURL,
            nowUnixSeconds: { nowUnixSeconds }
        )
    }
}

private func withFixture(
    _ body: (BridgeExtensionInstallerFixture) async throws -> Void
) async throws {
    let root = URL(
        fileURLWithPath: "/tmp/cm-extension-\(UUID().uuidString.prefix(8))",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("package", isDirectory: true)
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    for filename in BridgeExtensionPackage.filenames {
        try Data("export const file = \"\(filename)\";\n".utf8).write(
            to: package.appendingPathComponent(filename)
        )
    }
    let applicationSupport = root.appendingPathComponent(
        "Application Support",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: applicationSupport,
        withIntermediateDirectories: false
    )
    try await body(
        BridgeExtensionInstallerFixture(
            rootURL: root,
            packageURL: package,
            copilotHomeURL: root.appendingPathComponent(".copilot", isDirectory: true),
            applicationSupportURL: applicationSupport.appendingPathComponent(
                "Copilot Micro",
                isDirectory: true
            )
        )
    )
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
}
