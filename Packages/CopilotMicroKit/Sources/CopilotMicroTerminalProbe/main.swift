import CopilotMicroTerminal
import Foundation

private struct ProbeReport: Encodable {
    let schemaVersion = 1
    let outcome = "completed"
    let terminals: [TerminalApplicationDescriptor]
    let terminalIssues: [TerminalDiscoveryIssue]
    let cliExecutables: [CLIExecutableDescriptor]
    let cliIssues: [CLIExecutableDiscoveryIssue]
}

@main
private struct CopilotMicroTerminalProbe {
    static func main() {
        let terminalReport = TerminalApplicationDiscovery().discover()
        let cliReport = CLIExecutableDiscovery().discover()
        let report = ProbeReport(
            terminals: terminalReport.installations,
            terminalIssues: terminalReport.issues,
            cliExecutables: cliReport.executables,
            cliIssues: cliReport.issues
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            FileHandle.standardOutput.write(try encoder.encode(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(
                Data("{\"outcome\":\"failed\",\"schemaVersion\":1}\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }
}
