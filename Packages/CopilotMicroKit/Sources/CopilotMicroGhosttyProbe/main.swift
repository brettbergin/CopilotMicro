import CopilotMicroCore
import CopilotMicroTerminal
import Foundation

private enum ProbeError: Error, LocalizedError {
    case ghosttyNotFound
    case invalidArguments
    case invalidRoundTripArguments
    case invalidAssociationArguments
    case invalidAssociationResultPath

    var errorDescription: String? {
        switch self {
        case .ghosttyNotFound:
            "Ghostty was not found in the supported application locations."
        case .invalidArguments:
            "Use --consent=I-authorize-read-only-ghostty-automation."
        case .invalidRoundTripArguments:
            "Use --round-trip --consent=I-authorize-temporary-ghostty-window-test."
        case .invalidAssociationArguments:
            "Use --association-environment --consent=I-authorize-ghostty-environment-test."
        case .invalidAssociationResultPath:
            "The Ghostty association probe result path is invalid."
        }
    }
}

private struct ProbeReport: Encodable {
    let schemaVersion = 1
    let outcome = "completed"
    let terminal = "ghostty"
    let applicationPath: String
    let version: String?
    let processIdentifiers: [Int32]
    let applicationFrontmost: Bool
    let windowCount: Int
    let tabCount: Int
    let terminalCount: Int
    let exactFocusedSurface: GhosttySurfaceReference?
    let qualification: GhosttyQualificationResult?
    let associationEnvironmentInherited: Bool?
}

@main
private struct CopilotMicroGhosttyProbe {
    static func main() async {
        do {
            if let resultPath = ProcessInfo.processInfo.environment[
                GhosttyAssociationEnvironment.qualificationResultPathKey
            ] {
                try writeAssociationChildResult(to: resultPath)
                return
            }
            let arguments = Array(CommandLine.arguments.dropFirst())
            let roundTrip = arguments.contains("--round-trip")
            let associationEnvironment = arguments.contains("--association-environment")
            if associationEnvironment {
                guard
                    arguments.contains(
                        "--consent=I-authorize-ghostty-environment-test"
                    )
                else {
                    throw ProbeError.invalidAssociationArguments
                }
            } else if roundTrip {
                guard
                    arguments.contains(
                        "--consent=I-authorize-temporary-ghostty-window-test"
                    )
                else {
                    throw ProbeError.invalidRoundTripArguments
                }
            } else {
                guard
                    arguments.contains(
                        "--consent=I-authorize-read-only-ghostty-automation"
                    )
                else {
                    throw ProbeError.invalidArguments
                }
            }
            let report = TerminalApplicationDiscovery().discover()
            guard
                let installation = report.installations.first(where: {
                    $0.terminal == .ghostty
                })
            else {
                throw ProbeError.ghosttyNotFound
            }
            let processIdentifiers = await WorkspaceGhosttyProcessLocator()
                .runningApplications()
                .map(\.processIdentifier)
            let adapter = try GhosttyAdapter(
                installation: installation,
                bindings: GhosttyTargetBindingStore()
            )
            let snapshot = try await adapter.snapshot()
            let associationEnvironmentInherited: Bool?
            if associationEnvironment {
                let resultDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "CopilotMicroGhosttyAssociation.\(UUID().uuidString)",
                        isDirectory: true
                    )
                try FileManager.default.createDirectory(
                    at: resultDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                defer { try? FileManager.default.removeItem(at: resultDirectory) }
                let executableURL =
                    Bundle.main.executableURL
                    ?? URL(fileURLWithPath: CommandLine.arguments[0])
                associationEnvironmentInherited =
                    try await adapter.qualifyAssociationEnvironment(
                        probeExecutableURL: executableURL,
                        resultURL: resultDirectory.appendingPathComponent("result.json")
                    )
            } else {
                associationEnvironmentInherited = nil
            }
            let qualification: GhosttyQualificationResult? =
                if roundTrip {
                    try await adapter.qualifySurfaceRoundTrip(
                        workingDirectoryURL: FileManager.default.temporaryDirectory,
                        displaceFrontmostApplication: true
                    )
                } else {
                    nil
                }
            let focused = snapshot.surfaces.first(where: {
                snapshot.applicationFrontmost
                    && snapshot.frontWindowIdentifier == $0.reference.windowIdentifier
                    && $0.tabSelected
                    && $0.terminalFocused
            })?.reference
            let output = ProbeReport(
                applicationPath: installation.applicationURL.path,
                version: installation.version,
                processIdentifiers: processIdentifiers,
                applicationFrontmost: snapshot.applicationFrontmost,
                windowCount: Set(snapshot.surfaces.map(\.reference.windowIdentifier)).count,
                tabCount: Set(snapshot.surfaces.map(\.reference.tabIdentifier)).count,
                terminalCount: snapshot.surfaces.count,
                exactFocusedSurface: focused,
                qualification: qualification,
                associationEnvironmentInherited: associationEnvironmentInherited
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(output))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            let message =
                (error as? LocalizedError)?.errorDescription
                ?? "Ghostty qualification failed."
            let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
            FileHandle.standardError.write(
                Data(
                    "{\"message\":\"\(escaped)\",\"outcome\":\"failed\",\"schemaVersion\":1}\n"
                        .utf8
                )
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func writeAssociationChildResult(to path: String) throws {
        let resultURL = URL(fileURLWithPath: path).standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .standardizedFileURL.path
        guard
            resultURL.path.hasPrefix(temporaryDirectory + "/"),
            !FileManager.default.fileExists(atPath: resultURL.path),
            let rawToken = ProcessInfo.processInfo.environment[
                GhosttyAssociationEnvironment.surfaceTokenKey
            ]
        else {
            throw ProbeError.invalidAssociationResultPath
        }
        let result = GhosttyAssociationProbeResult(
            surfaceAssociationToken: try SurfaceAssociationToken(rawValue: rawToken)
        )
        guard
            FileManager.default.createFile(
                atPath: resultURL.path,
                contents: try JSONEncoder().encode(result),
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw ProbeError.invalidAssociationResultPath
        }
    }
}
