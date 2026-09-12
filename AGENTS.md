# Copilot Micro development

This is a native macOS project, not a Python service. The product contract is
the ten `docs/phase-00*.md` documents; start with phase 000 for ownership.

## Current implementation boundary

Developer setup tooling exists. The native app, GUI/emulator and live
CLI/device integrations are not implemented yet. Build the GUI/emulator
before connecting live integrations.

Use Swift 6 with SwiftUI/AppKit, an XcodeGen-managed project and a local Swift
package for native code. Use a small `.mjs` bridge with the CLI-provided SDK.
Do not place unfinished bridge code in `.github/extensions/`, where opening
the repository could load it into a real session.

## Canonical commands

- `make doctor-xcode`: read-only full Xcode/SDK prerequisite check.
- `make doctor`: read-only developer prerequisite report.
- `make test-doctor`: isolated Node tests for the prerequisite checker.
- `make check`: current setup-tooling syntax and tests only.

No native application build/test command exists yet. Do not describe setup
checks, an emulator or a HID acknowledgement as qualified app/device support.
Use command-scoped `DEVELOPER_DIR`; never silently change global `xcode-select`.

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
