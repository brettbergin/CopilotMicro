import CopilotMicroTerminal
import Foundation

private enum ProbeError: Error, LocalizedError {
    case ghosttyNotFound
    case invalidArguments
    case invalidRoundTripArguments

    var errorDescription: String? {
        switch self {
        case .ghosttyNotFound:
            "Ghostty was not found in the supported application locations."
        case .invalidArguments:
            "Use --consent=I-authorize-read-only-ghostty-automation."
        case .invalidRoundTripArguments:
            "Use --round-trip --consent=I-authorize-temporary-ghostty-window-test."
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
}

@main
private struct CopilotMicroGhosttyProbe {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let roundTrip = arguments.contains("--round-trip")
            if roundTrip {
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
            let adapter = try GhosttyAdapter(installation: installation)
            let snapshot = try await adapter.snapshot()
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
                qualification: qualification
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
}
