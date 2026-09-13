# Phase 008: distribution and support

Scope: F-19, F-20, F-21, F-24, F-25, F-26.

## Initial distribution policy

Copilot Micro is an internal application. Initial builds may be unsigned or
ad-hoc signed; Developer ID signing/notarization is a later milestone.
Do not advertise first releases as notarized or frictionless installations.

Package a normal Apple Silicon `.app` with a stable, project-owned bundle
identity and consistent local storage paths. Supply an internal release
archive and clear installation instructions. No privileged system daemon or
kernel extension is part of the baseline.

Explain Gatekeeper and Input Monitoring/Accessibility/Automation onboarding,
including possible grant churn after ad-hoc updates. Use normal macOS
approval flows, not quarantine stripping or security-database edits.

The repository is licensed under the MIT license in `LICENSE`. Review licenses
for every dependency actually adopted; public visibility of micro-manager is
not permission to copy its implementation or artwork.

## Compatibility policy

| Surface | Intended support | Qualification policy |
|---|---|---|
| CPU | Apple Silicon M1 and newer | ARM64 builds; no Intel claim |
| OS | macOS Tahoe 26.x | Initial qualification baseline 26.6.2; record actual version/build |
| Terminal | Ghostty, iTerm2, Terminal.app | Qualify exact target/focus/UI behavior separately |
| Device | Creator Micro 2 Pro | Confirm identity/revision; no automatic Base/Codex variant claim |
| Transport | USB and Bluetooth | Both intended; record any unavailable transport as a material gap |
| CLI | Known-good documented versions | Prerelease/experimental extension builds allowed; no arbitrary-version promise |
| Firmware | Exact qualified device versions | No automatic firmware update or generic version-threshold assumption |

Maintain a machine-readable support manifest and human-readable release
matrix once implementation begins. Include per-feature support/gaps, not
only an app-wide compatible boolean.

The initial research CLI was `1.0.84-4`. Disposable live qualification now
records partial support for CLI `1.0.84-5`, build `0de509ce`, with bundled SDK
`1.0.13-preview.4` and child Node `v24.20.0`. This is not automatically the
shipping pin and several required control surfaces remain unavailable. Select
the release CLI/SDK/firmware tuple through the remaining qualification in
[phase 009](phase-009-delivery-and-acceptance.md).

An unknown CLI/OS/terminal build gets a compatibility explanation, not a blind
attempt at sensitive actions. Do not downgrade/update the user's CLI silently.
New macOS major versions require separate qualification.

Ghostty `1.3.1` exact surface enumeration and focus are qualified on macOS
`26.6.2` through its documented AppleScript API. The live test preserved an
existing window, created a temporary window with two tabs and one split,
focused two exact terminal IDs from another foreground app, and verified
cleanup. This requires Automation permission but not Accessibility permission.
The app bundle declares why it controls the selected terminal. Ad-hoc rebuilds
may still cause grant churn.

This does not qualify association with an arbitrary existing Copilot CLI
process. Ghostty does not expose a child PID or TTY for a terminal surface, and
Copilot Micro will not infer identity from a title or working directory. That
dependent capability remains disabled until the app-created surface and
bridge registration share an exact association token.

The initial hardware tuple is read-only USB evidence for macOS-reported
`Creator Micro 2`, VID/PID `0x303A/0x8298`, firmware `0.6.2`, 64-byte reports
and vendor usage `0xFF00`/`1`. Bluetooth, input, lighting, managed mapping and
the marketing `Pro` distinction are not yet qualified.

## Dependencies and onboarding

Discover the preferred terminal and Copilot executable before launching work.
Explain missing CLI login/trust, extension availability or voice prerequisites.
Install the bridge only with consent and verify its actual handshake.

Private release retrieval may depend on `gh` and its existing authenticated
session. If unavailable, show how to resolve that update prerequisite. Core
hardware/session controls must not fail solely because update checking lacks
authentication.

Launch at login is opt-in using the native macOS service-management mechanism.
Respect its real registered/approved status. Starting the menu bar app does
not automatically start Copilot; offer explicit Open Copilot when disconnected.

The local native build uses Swift Package Manager and Apple's installed
Command Line Tools, which contain the macOS SDK. A SwiftUI/AppKit build, ad-hoc-signed `.app`, relocated-resource hidden smoke
and bounded production accessory-lifecycle smoke were verified with Swift
6.3.3 and SDK 26.5 on macOS 26.6.2. These checks open no manager window and
leave no running app. This does not require an Apple account or downloading
full Xcode.

Xcode-specific UI automation is a separate capability. A prior XCTest failure
must not be generalized into inability to build a native app. Record the
actual unit-test runner and UI verification evidence separately. An authorized
macOS CI runner with Xcode preinstalled is a possible later path, not evidence
that those checks have already run.

Local SwiftPM unit tests were verified with the official Swift Testing 6.2.4
dependency and SwiftSyntax 602.0.0, including a deliberately failing test
returning nonzero. Bundled Testing/XCTest are absent in this CLT installation;
Testing 6.3.2 links against unavailable `_TestingInterop`. Keep the verified
test-only dependency pinned until a replacement is qualified.

This combination can emit a compile-time `DecodingError` about a corrupted
JSON/EOF macro-plugin shutdown message, matching
[Swift issue 90663](https://github.com/swiftlang/swift/issues/90663).
It appeared before build completion; actual test counts and failure exits
were verified independently. Do not hide the diagnostic, accept nonzero
build/test exits, or skip rebuilding changed tests to suppress it.

SwiftPM stores source-control dependencies as package-local bare repositories.
The checked-in SwiftPM wrapper uses app-owned caches, home, temporary and
security directories for builds and tests, disables interactive credentials,
strips GitHub/Copilot token variables and applies a command-scoped
`includeIf.gitdir` limited to this checkout. This allows those generated
repositories without changing the user's global
`safe.bareRepository=explicit` policy. Do not weaken that policy globally as a
build workaround.

The read-only `make doctor` checks local native prerequisites; optional
`make doctor-xcode` strictly checks full Xcode/SDK. Use command-scoped
`DEVELOPER_DIR` rather than changing global `xcode-select`. Neither command
installs tools, logs into Copilot or qualifies live integrations. Developer
tool installation is not part of end-user setup. See the
[README setup guide](../README.md#developer-setup) and Apple's
[Command Line Tools overview](https://developer.apple.com/library/archive/technotes/tn2339/_index.html).

Ad-hoc signing does not provide Developer ID identity or notarization.
Those later distribution capabilities require separately provisioned Apple
signing resources; lack of them is not a reason to block local GUI work.

## Managed bridge lifecycle

Use a uniquely named user-scoped extension in the location documented by the
qualified CLI. Show the resolved path before installing. Record an app-owned
installation receipt with version and file hashes outside portable exports.

Never overwrite a pre-existing unrelated or user-modified extension. Surface
project/user/plugin name collisions and require resolution. Install and update
atomically, retaining a recoverable app-owned prior version.

Negotiate application/bridge protocol compatibility independently of app
version. If a changed bridge cannot activate safely in the current CLI,
report Reload required and explain the host's supported reload path. Do not
terminate/restart CLI, silently reload unrelated work or claim that merely
writing the file established a connection.

Uninstall offers original-keymap restoration and removes only verified
app-owned bridge files. Preserve externally modified files and original
backups unless the user explicitly elects their removal. Uninstall must not
remove the CLI or unrelated extensions.

## Built-in update flow

The selected product experience is a built-in updater with explicit user
approval before installation.

1. Read the configured internal/private GitHub Releases source.
2. Use existing `gh` authentication where needed without copying tokens.
3. Show current/candidate version, release notes and compatibility changes.
4. Download to app-owned staging storage.
5. Verify trusted signatures/integrity, artifact identity, expected architecture
   and compatibility before offering installation.
6. Ask for explicit installation approval and explain restart/grant implications.
7. Stage a recoverable replacement, stop only the companion as required, and
   install without restarting/terminating Copilot CLI.
8. Relaunch, verify health, reconnect with fresh generations and report the
   result or recovery path.

A check may run at a documented, bounded cadence; successful checking is not
permission to install. Do not install in the middle of a device configuration
transaction. Do not replay queued physical input after replacement.

Maintain a recoverable previous app/configuration state. Rollback must be
explicit and integrity-checked; do not silently install arbitrary older
versions. Preserve original keymap backups and compatible preferences.

The update source, release artifact naming and trusted verification key must
be configured before the updater can be qualified. They are packaging
inputs, not reasons to create a remote repository during the documentation
phase.

Ad-hoc code signing and update-authenticity signing are distinct. Lack of a
Developer ID does not justify installing an unverified payload. If safe
replacement cannot be delivered yet, disable built-in installation and report
F-24's gap explicitly.

## Release contents

Every internal release should include:

- App version and reproducible source commit.
- Install/upgrade instructions and known ad-hoc trust limitations.
- Qualified support matrix and intended-but-unavailable feature/transport gaps.
- Verified update metadata/artifacts where that feature is enabled.
- Keymap takeover/restore and bridge uninstall instructions.
- Local diagnostic export instructions and the no-telemetry policy.

GitHub-authored release content and commits must use the project's required
agent attribution when agentically produced. Do not append attribution
footers to source/configuration files themselves.

## Support and recovery

Support should begin with the manager's local compatibility/health summary,
not a request for the full conversation or token-bearing logs.

Recovery paths must distinguish:

- Device missing/asleep versus invalid firmware/protocol versus write failure.
- Input Monitoring denial versus unavailable terminal UI permission.
- CLI absent versus unqualified version versus bridge load/shadowing failure.
- Selected session replacement versus an ordinary action timeout.
- Update authentication, integrity, compatibility and replacement failures.

Keep diagnostics export opt-in and redacted. No automatic issue filing,
telemetry, crash upload or transcript sharing.

Later milestones may add Developer ID signing/notarization and broader
qualification. They do not imply desktop-app integration, public licensing,
Intel support or other hardware variants without a separate product decision.
