import CopilotMicroCore
import CopilotMicroTerminal
import Foundation
import Testing

@testable import CopilotMicroStorage

@Suite("Private local configuration")
struct ConfigurationTests {
    @Test("Portable export is complete and excludes machine-specific state")
    func portableExportExcludesPrivateLocalFields() throws {
        var configuration = StoredConfiguration()
        configuration.terminal = StoredTerminalPreferences(
            preferredBundleIdentifier: SupportedTerminal.terminal.bundleIdentifier,
            preferredApplicationPath: "/Applications/Terminal.app",
            cliExecutableHint: "/opt/homebrew/bin/copilot"
        )
        configuration.recentProjectDirectories = ["/Users/example/private-project"]

        let data = try ConfigurationCodec.encodePortable(configuration)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(
            Set(object.keys)
                == Set(["schemaVersion", "product", "bindings", "lighting", "preferences"])
        )
        let bindings = try #require(object["bindings"] as? [String: Any])
        #expect(Set(bindings.keys) == Set(PhysicalControlID.allCases.map(\.rawValue)))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/Applications"))
        #expect(!text.contains("/Users/example"))
        #expect(!text.contains("/opt/homebrew"))
    }

    @Test("Portable import rejects malformed, future, extra and unsafe values")
    func invalidPortableImportsAreRejected() throws {
        let current = StoredConfiguration()
        let valid = try ConfigurationCodec.encodePortable(current)
        #expect(
            throws: ConfigurationError.malformed,
            performing: {
                _ = try ConfigurationCodec.decodePortable(
                    Data("not json".utf8),
                    against: current
                )
            }
        )

        let mutations: [((inout [String: Any]) -> Void, ConfigurationError)] = [
            ({ (root: inout [String: Any]) in root["schemaVersion"] = 2 }, .unsupportedSchema(2)),
            ({ (root: inout [String: Any]) in root["command"] = "rm -rf /" }, .unexpectedField),
            (
                { (root: inout [String: Any]) in
                    var lighting = root["lighting"] as? [String: Any] ?? [:]
                    lighting["brightness"] = 1.5
                    root["lighting"] = lighting
                }, .invalidBrightness
            ),
            (
                { (root: inout [String: Any]) in
                    var bindings = root["bindings"] as? [String: Any] ?? [:]
                    bindings.removeValue(forKey: PhysicalControlID.sessions.rawValue)
                    root["bindings"] = bindings
                }, .incompleteBindings
            ),
            (
                { (root: inout [String: Any]) in
                    var bindings = root["bindings"] as? [String: Any] ?? [:]
                    bindings[PhysicalControlID.sessions.rawValue] = "shell.execute"
                    root["bindings"] = bindings
                }, .unsupportedAction
            ),
        ]
        for mutation in mutations {
            var root = try #require(
                JSONSerialization.jsonObject(with: valid) as? [String: Any]
            )
            mutation.0(&root)
            let data = try JSONSerialization.data(withJSONObject: root)
            #expect(throws: mutation.1) {
                _ = try ConfigurationCodec.decodePortable(data, against: current)
            }
        }
    }

    @Test("Import preview lists changes and preserves local-only fields")
    func importPlanPreservesMachineSpecificFields() throws {
        var current = StoredConfiguration()
        current.terminal = StoredTerminalPreferences(
            preferredBundleIdentifier: SupportedTerminal.terminal.bundleIdentifier,
            preferredApplicationPath: "/Applications/Terminal.app",
            cliExecutableHint: "/usr/local/bin/copilot"
        )
        current.recentProjectDirectories = ["/Users/example/repository"]
        var portableSource = StoredConfiguration()
        portableSource.bindings[.sessions] = .focusComposer
        portableSource.lighting.brightness = 0.25
        portableSource.lighting.reducedMotion = true
        portableSource.preferences.notificationsEnabled = true

        let plan = try ConfigurationCodec.decodePortable(
            ConfigurationCodec.encodePortable(portableSource),
            against: current
        )
        #expect(plan.bindingChanges.count == 1)
        #expect(plan.bindingChanges.first?.control == .sessions)
        #expect(plan.brightnessChanged)
        #expect(plan.reducedMotionChanged)
        #expect(plan.notificationsChanged)

        let imported = try plan.applying(to: current)
        #expect(imported.bindings[.sessions] == .focusComposer)
        #expect(imported.lighting.brightness == 0.25)
        #expect(imported.terminal == current.terminal)
        #expect(imported.recentProjectDirectories == current.recentProjectDirectories)

        var changedAfterPreview = current
        changedAfterPreview.preferences.notificationsEnabled = true
        #expect(throws: ConfigurationError.staleImportPreview) {
            _ = try plan.applying(to: changedAfterPreview)
        }
    }

    @Test("Terminal preferences require a complete supported exact selection")
    func terminalPreferenceValidation() async throws {
        let terminal = try TerminalPreference(
            bundleIdentifier: SupportedTerminal.ghostty.bundleIdentifier,
            applicationPath: "/Applications/Ghostty.app"
        )
        let cli = try CLIExecutablePreference(
            executablePath: "/opt/homebrew/bin/copilot"
        )
        var configuration = StoredConfiguration()
        configuration.terminal = StoredTerminalPreferences(
            terminalPreference: terminal,
            cliExecutablePreference: cli
        )
        let decoded = try ConfigurationCodec.decodeStored(
            ConfigurationCodec.encodeStored(configuration)
        )
        #expect(decoded.terminal.preferredBundleIdentifier == terminal.bundleIdentifier)
        #expect(decoded.terminal.preferredApplicationPath == terminal.applicationPath)
        #expect(decoded.terminal.cliExecutableHint == cli.executablePath)

        try await withTemporaryDirectory { root in
            let store = LocalConfigurationStore(rootURL: root)
            try await store.save(configuration)
            #expect(try await store.load().terminal == configuration.terminal)
        }

        configuration.terminal = StoredTerminalPreferences(
            preferredBundleIdentifier: terminal.bundleIdentifier
        )
        #expect(throws: ConfigurationError.invalidString) {
            _ = try ConfigurationCodec.encodeStored(configuration)
        }
    }

    @Test("Store creates protected files and atomically round-trips settings")
    func storeRoundTripAndPermissions() async throws {
        try await withTemporaryDirectory { root in
            let store = LocalConfigurationStore(rootURL: root)
            var configuration = try await store.load()
            configuration.bindings[.sessions] = .focusComposer
            configuration.lighting.brightness = 0.4
            try await store.save(configuration)
            #expect(try await store.load() == configuration)

            let rootMode = try permissions(at: root)
            let fileMode = try permissions(
                at: root.appendingPathComponent(LocalConfigurationStore.configurationFilename)
            )
            #expect(rootMode == 0o700)
            #expect(fileMode == 0o600)
        }
    }

    @Test("Interrupted atomic save leaves the previous configuration intact")
    func interruptedSavePreservesPreviousFile() async throws {
        try await withTemporaryDirectory { root in
            let initialStore = LocalConfigurationStore(rootURL: root)
            let initial = try await initialStore.load()
            var changed = initial
            changed.lighting.brightness = 0.2

            let interrupted = LocalConfigurationStore(
                rootURL: root,
                fileManager: .default,
                beforeAtomicReplace: { throw ConfigurationError.fileSystem }
            )
            await #expect(throws: ConfigurationError.fileSystem) {
                try await interrupted.save(changed)
            }
            #expect(try await initialStore.load() == initial)
        }
    }

    @Test("Legacy migration preserves its source and malformed data remains untouched")
    func migrationAndMalformedRecovery() async throws {
        try await withTemporaryDirectory { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let configURL = root.appendingPathComponent(
                LocalConfigurationStore.configurationFilename
            )
            let legacy: [String: Any] = [
                "schemaVersion": 0,
                "bindings": Dictionary(
                    uniqueKeysWithValues: StoredConfiguration.defaultBindings.map {
                        ($0.key.rawValue, $0.value.rawValue)
                    }
                ),
                "brightness": 0.3,
                "reducedMotion": true,
                "notificationsEnabled": true,
            ]
            try JSONSerialization.data(
                withJSONObject: legacy,
                options: [.sortedKeys]
            ).write(to: configURL)

            let store = LocalConfigurationStore(rootURL: root)
            let migrated = try await store.load()
            #expect(migrated.schemaVersion == 1)
            #expect(migrated.lighting.brightness == 0.3)
            #expect(migrated.lighting.reducedMotion)
            let backups = try FileManager.default.contentsOfDirectory(
                at: await store.backupDirectoryURL,
                includingPropertiesForKeys: nil
            )
            #expect(backups.count == 1)

            let malformed = Data(#"{"schemaVersion":1,"secret":"keep-me"}"#.utf8)
            try malformed.write(to: configURL, options: [.atomic])
            await #expect(throws: ConfigurationError.self) {
                _ = try await store.load()
            }
            #expect(try Data(contentsOf: configURL) == malformed)
        }
    }

    @Test("Confirmed import keeps a recoverable previous configuration")
    func confirmedImportCreatesRecoveryCopy() async throws {
        try await withTemporaryDirectory { root in
            let store = LocalConfigurationStore(rootURL: root)
            let current = try await store.load()
            var source = current
            source.bindings[.sessions] = .focusComposer
            let plan = try await store.previewImport(
                ConfigurationCodec.encodePortable(source),
                against: current
            )
            let imported = try await store.applyImport(plan)
            #expect(imported.bindings[.sessions] == .focusComposer)
            let backups = try FileManager.default.contentsOfDirectory(
                at: await store.backupDirectoryURL,
                includingPropertiesForKeys: nil
            )
            #expect(backups.count == 1)
            #expect(try await store.load() == imported)
        }
    }

    @Test("Revisioned saves cannot overwrite newer settings")
    func staleSaveIsIgnored() async throws {
        try await withTemporaryDirectory { root in
            let store = LocalConfigurationStore(rootURL: root)
            let initial = try await store.load()
            var newest = initial
            newest.lighting.brightness = 0.8
            var stale = initial
            stale.lighting.brightness = 0.1

            #expect(try await store.save(newest, revision: 2))
            #expect(try await !store.save(stale, revision: 1))
            #expect(try await store.load().lighting.brightness == 0.8)
        }
    }

    @Test("Recovery preserves malformed input before installing safe defaults")
    func explicitRecoveryPreservesMalformedInput() async throws {
        try await withTemporaryDirectory { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let configURL = root.appendingPathComponent(
                LocalConfigurationStore.configurationFilename
            )
            let malformed = Data(#"{"schemaVersion":1,"token":"do-not-delete"}"#.utf8)
            try malformed.write(to: configURL)
            let store = LocalConfigurationStore(rootURL: root)

            await #expect(throws: ConfigurationError.self) {
                _ = try await store.load()
            }
            let recovered = try await store.replaceWithDefaultsPreservingOriginal(
                revision: 1
            )
            #expect(recovered == StoredConfiguration())
            let backups = try FileManager.default.contentsOfDirectory(
                at: await store.backupDirectoryURL,
                includingPropertiesForKeys: nil
            )
            let backup = try #require(backups.first)
            #expect(try Data(contentsOf: backup) == malformed)
            #expect(try await store.load() == StoredConfiguration())
        }
    }

    @Test("Portable export preserves the selected parent directory permissions")
    func portableExportDoesNotRetagParentDirectory() async throws {
        try await withTemporaryDirectory { root in
            let storeRoot = root.appendingPathComponent("store", isDirectory: true)
            let exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
            try FileManager.default.createDirectory(
                at: exportDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: exportDirectory.path
            )
            let destination = exportDirectory.appendingPathComponent("portable.json")
            let store = LocalConfigurationStore(rootURL: storeRoot)
            try await store.writePortable(StoredConfiguration(), to: destination)

            #expect(try permissions(at: exportDirectory) == 0o755)
            #expect(try permissions(at: destination) == 0o600)
        }
    }

    @Test("Portable exports cannot overwrite app-managed storage")
    func portableExportRejectsManagedDestinations() async throws {
        try await withTemporaryDirectory { root in
            let store = LocalConfigurationStore(rootURL: root)
            let current = try await store.load()
            let configurationURL = await store.configurationURL
            let backupURL = await store.backupDirectoryURL.appendingPathComponent(
                "portable.json"
            )

            await #expect(throws: ConfigurationError.fileSystem) {
                try await store.writePortable(current, to: configurationURL)
            }
            await #expect(throws: ConfigurationError.fileSystem) {
                try await store.writePortable(current, to: backupURL)
            }
            #expect(try await store.load() == current)
        }
    }

    @Test("Configuration and import symlinks fail closed")
    func symlinksAreRejected() async throws {
        try await withTemporaryDirectory { root in
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let symlinkedRoot = root.appendingPathComponent("store", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: symlinkedRoot,
                withDestinationURL: outside
            )
            let store = LocalConfigurationStore(rootURL: symlinkedRoot)
            await #expect(throws: ConfigurationError.fileSystem) {
                _ = try await store.load()
            }

            let valid = root.appendingPathComponent("portable.json")
            try ConfigurationCodec.encodePortable(StoredConfiguration()).write(to: valid)
            let link = root.appendingPathComponent("portable-link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
            let safeStore = LocalConfigurationStore(
                rootURL: root.appendingPathComponent("safe", isDirectory: true)
            )
            let current = try await safeStore.load()
            await #expect(throws: ConfigurationError.fileSystem) {
                _ = try await safeStore.previewImport(from: link, against: current)
            }
        }
    }

    @Test("Configuration recovery history is bounded")
    func recoveryHistoryIsBounded() async throws {
        try await withTemporaryDirectory { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let configURL = root.appendingPathComponent(
                LocalConfigurationStore.configurationFilename
            )
            let store = LocalConfigurationStore(rootURL: root)
            for revision in 1...8 {
                try Data(#"{"schemaVersion":1,"malformed":true}"#.utf8).write(
                    to: configURL,
                    options: [.atomic]
                )
                _ = try await store.replaceWithDefaultsPreservingOriginal(
                    revision: UInt64(revision)
                )
            }
            let backups = try FileManager.default.contentsOfDirectory(
                at: await store.backupDirectoryURL,
                includingPropertiesForKeys: nil
            )
            #expect(backups.count == LocalConfigurationStore.maximumRecoveryConfigurations)
        }
    }
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
}

private func withTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "copilot-micro-storage-\(UUID().uuidString)",
        isDirectory: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try await body(root)
}
