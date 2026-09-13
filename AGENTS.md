# Copilot Micro development

This is a native macOS project, not a Python service. The product contract is
the ten `docs/phase-00*.md` documents; start with phase 000 for ownership.

## Current implementation boundary

Developer setup tooling, a complete interactive GUI emulator and the
deterministic controls/session/lighting contract layer exist. Versioned local
settings, portable import/export and bounded redacted diagnostics are
implemented. The authenticated local IPC package and isolated Node client now
exist, but the app does not start a socket and no production CLI extension is
installed. A passive source-only probe qualified bounded surfaces in owned
disposable Copilot CLI `1.0.84-5` sessions. The production source tree contains
an uninstalled read-only extension entry point and native session reconciler
for that qualified observation subset; every stateful action remains rejected
until I-15. Native Creator Micro 2 developer tools now provide guarded backup,
restore and reduced mapping, normalized keys/dial/native radial joystick input,
and bounded key lighting without changing flash or ambient underglow. The app
still starts no live service or routes physical actions to Copilot CLI.
Preserve the emulator/live boundary and do not widen qualified authority.

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
checks, an emulator or a HID acknowledgement as qualified live device support.
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
- Keep emulator and live service assemblies mutually exclusive.
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
