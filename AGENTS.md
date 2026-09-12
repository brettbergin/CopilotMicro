# Copilot Micro development

This is a native macOS project, not a Python service. The product contract is
the ten `docs/phase-00*.md` documents; start with phase 000 for ownership.

## Current implementation boundary

Developer setup tooling and an emulator-only native menu bar/manager scaffold
exist. Controls/lighting simulation and live CLI/device integrations are not
implemented yet. Complete the GUI/emulator before connecting live integrations.

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
- `make test-core`: pinned Swift Testing unit suite, with XCTest disabled.
- `make build`: compile the native arm64 executable.
- `make package`: build/sign an app in a fresh generated output directory.
- `make smoke-test`: package, run hidden UI/resource and bounded accessory
  lifecycle smoke, then safely remove its generated package directory.
- `make lint` / `make format`: source checks / Swift formatting.
- `make check`: lint, Node/Core tests and packaged headless smoke.

Use `PACKAGE_OUTPUT=build/<new-name>` for a chosen packaging destination.
Existing apps are never overwritten or deleted. Do not describe headless
checks, an emulator or a HID acknowledgement as qualified live device support.
Use command-scoped `DEVELOPER_DIR`; never silently change global `xcode-select`.

`scripts/swiftpm` is the shared build/test entry point. It uses app-owned
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
