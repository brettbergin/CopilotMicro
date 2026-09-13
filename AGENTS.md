# Copilot Micro development

This is a native macOS project, not a Python service. The product contract is
the ten `docs/phase-00*.md` documents; start with phase 000 for ownership.

## Current implementation boundary

The packaged app now directly owns the qualified Creator Micro 2 USB HID
connection. Its GUI shows real connection, key, dial and radial joystick input,
and applies matching runtime color/brightness to the key LEDs and ambient
underglow without writing device flash. Input Monitoring is required and Work
Louder Input must remain closed. The managed keymap backup/restore tools remain
separate and guarded. The normal packaged app starts the owner-restricted
authenticated CLI socket and reports bridge state; smoke mode suppresses bridge
filesystem and socket access. The signed app bundles the passive observer but
installs it only after an explicit confirmation that shows the resolved
user-extension path. Hash receipts, collision checks and retained app-owned
backups prevent unrelated or modified files from being overwritten. Every
stateful Copilot CLI action remains rejected until I-15. The terminal module
validates supported installations, exact saved
preferences, CLI paths and typed process/window/tab/pane evidence. Its Ghostty
1.3.1 adapter is qualified for exact stable-surface observation and focus.
App-created Ghostty surfaces now receive a one-time association token that the
bridge registration can return to a race-safe native registry; exact child
environment inheritance is live-qualified. The app can explicitly open a new
Ghostty Copilot window after a project is selected, but this packaged path has
not yet received a real registration.
Do not reintroduce simulated device state or widen CLI authority.

Use Swift 6 with SwiftUI/AppKit, Swift Package Manager and a local Swift
package for native code. The local build uses Apple's installed Command Line
Tools and explicit `.app` packaging; full Xcode is not a universal prerequisite.
Keep Xcode-only UI automation separately gated. Use a small `.mjs` bridge with
the CLI-provided SDK.
Do not place unfinished bridge code in `.github/extensions/`, where opening
the repository could load it into a real session.

## Canonical commands

- `make doctor-xcode`: optional, strict full Xcode/SDK prerequisite check.
- `make doctor`: read-only local native developer prerequisite report.
- `make test-doctor`: isolated Node tests for the prerequisite checker.
- `make test-packager`: isolated Node tests for safe app packaging.
- `make test-contracts`: shared schema, action, control and negative-fixture
  checks used by both the native model and JavaScript bridge.
- `make test-bridge`: isolated Node framing, authentication, role and client
  tests, including the uninstalled production observer/rejection runtime. It
  does not load an extension into Copilot CLI.
- `make test-cli-probe`: isolated disposable workspace, privacy, evidence and
  capability-classification tests. It does not launch Copilot CLI.
- `make test-core`: pinned Swift Testing unit suite, with XCTest disabled.
- `make build`: compile the native arm64 executable.
- `make package`: build/sign an app in a fresh generated output directory.
- `make smoke-test`: package, run hidden UI/resource and bounded accessory
  lifecycle smoke, then safely remove its generated package directory.
- `make lint` / `make format`: source checks / Swift formatting.
- `make check`: lint, Node/Core tests and packaged headless smoke.
- `make qualify-cli CONSENT=I-own-this-disposable-session`: explicitly launch
  the passive probe in an owned disposable project. Add `ACTIVE=1` only for
  the fixed reversible mode/effort probes.
- `make qualify-terminals`: read supported terminal bundle metadata and
  approved Copilot CLI paths without launching a terminal, CLI, or shell
  startup file.
- `make qualify-ghostty CONSENT=I-authorize-read-only-ghostty-automation`:
  query stable Ghostty window, tab and terminal IDs after explicit Automation
  consent. It does not send input or launch a command.
- `make qualify-ghostty-roundtrip
  CONSENT=I-authorize-temporary-ghostty-window-test`: create a temporary
  Ghostty window containing two tabs and one split, run only `/usr/bin/true`,
  verify exact focus through the production adapter, and close the created
  window by its stable ID.
- `make qualify-ghostty-association
  CONSENT=I-authorize-ghostty-environment-test`: create one temporary Ghostty
  window running the local probe, prove exact surface-token inheritance by the
  child process, remove its private result, and close the created window by its
  stable ID.
- `make qualify-hardware CONSENT=I-own-this-device-read`: explicitly discover,
  open non-exclusively and read bounded identity/status/keymap metadata from
  one Creator Micro 2 candidate. It performs no configuration or lighting
  mutation.
- `make observe-device-input CONSENT=I-own-this-device-observe-input
  SECONDS=30`: print normalized keys, dial detents and joystick transitions
  from the managed map without routing actions.
- `make qualify-device-lighting
  CONSENT=I-closed-other-device-configurators-and-authorize-key-lighting-test
  HOLD_SECONDS=2`: reject known configurators, display a bounded all-key color
  sequence, then clear the key LEDs without modifying ambient underglow or
  device flash.
- `make preview-device-mapping CONSENT=I-own-this-device-read`: create or
  verify the original keymap backup and print the exact non-mutating map plus
  its device/source/backup-bound transaction digest.
- `make apply-device-mapping PLAN_SHA=<preview digest>
  CONSENT=I-closed-other-device-configurators-and-authorize-one-write`:
  reject known configurators, revalidate the reviewed transaction, save a
  fresh pre-change snapshot, write once and verify full read-back.
- `make preview-device-restore CONSENT=I-own-this-device-read` and
  `make restore-device-mapping PLAN_SHA=<preview digest>
  CONSENT=I-closed-other-device-configurators-and-authorize-one-restore`: preview
  or explicitly restore the verified original backup.

Use `PACKAGE_OUTPUT=build/<new-name>` for a chosen packaging destination.
Existing apps are never overwritten or deleted. Do not describe headless
checks, synthetic state or a HID acknowledgement as qualified live device support.
Use command-scoped `DEVELOPER_DIR`; never silently change global `xcode-select`.

`scripts/swiftpm` is the shared build/run/test entry point. It uses app-owned
SwiftPM caches/configuration, disables interactive credentials and strips
GitHub/Copilot token variables. It keeps the user's global
`safe.bareRepository` policy unchanged while permitting only SwiftPM-generated
bare repositories beneath this checkout for that child command. Do not replace
it with a global Git configuration change.

## Implementation rules

- Work in an isolated `bb/<short-slug>` worktree; preserve the primary checkout.
- Add tests with behavior, use explicit types/guards and keep I/O out of pure
  state reducers. Respect Swift actor/concurrency boundaries.
- Use shared action/schema fixtures across native and bridge implementations.
- Automated smoke tests must suppress hardware access; normal app launches
  must use only the live device assembly.
- Never add blind approval macros, global keylogging, clipboard scraping,
  allow-all permissions or a replacement agent runtime as a fallback.
- Device writes require a verified original backup, preview, explicit consent
  and read-back. Ordinary lighting/remapping must not cause flash-write loops.
- Preserve cancellation scope, drafts, session history and unrelated extensions.
- Diagnostics are bounded and local. No telemetry or credentials/transcripts
  in configuration, logs, fixtures or exports.
- Use ASCII in documentation and comments. Do not copy unlicensed reference
  implementation or artwork.
- Keep unsupported features visible and disabled; update canonical docs and
  the feature-gap report when behavior or qualification changes.
