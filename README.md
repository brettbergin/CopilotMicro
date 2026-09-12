# Copilot Micro

A native macOS menu bar companion that turns a Work Louder Creator Micro 2 Pro
into a control surface for GitHub Copilot CLI.

The keypad mirrors the selected CLI session's mode and activity, and provides
session management, model/effort, voice, input, cancellation and permission
controls. A graphical manager provides onboarding, remapping, diagnostics and
local configuration.

**Status:** early native foundation. The menu bar, Open Manager/Quit actions,
emulator-only manager window, app packaging, versioned contracts and
deterministic controls/session/lighting reducers exist. The complete GUI
simulator and live hardware/CLI integrations are not implemented yet.

## Developer setup

Local native builds use Swift 6, Swift Package Manager and Apple's macOS SDK
from the installed Command Line Tools. **Full Xcode and an Apple account are
not required for this build path.** A native SwiftUI/AppKit app, ad-hoc signing,
relocated bundle resources and headless window/view creation were verified
with Command Line Tools Swift 6.3.3 and macOS SDK 26.5 on macOS 26.6.2.

With Node installed, check local prerequisites without changing the global
developer-tool selection:

```sh
make doctor
```

Select an installed toolchain for just one command when needed:

```sh
DEVELOPER_DIR="/Library/Developer/CommandLineTools" make doctor
```

The developer tools are declared in `Brewfile`. Review that file and install
missing tools with
`brew bundle install --file=Brewfile --no-upgrade`, then run `make doctor`.
The checker is read-only; it does not install tools or log into Copilot.

Full Xcode is a separate prerequisite for Xcode-specific UI automation, not
for the local native app. `make doctor-xcode` checks that optional environment
strictly. Such checks can later use an authorized macOS CI runner with Xcode
preinstalled; no CI run or UI automation is claimed here.

Build and check the current foundation:

```sh
make check
make package
```

`make check` runs source checks, shared contract fixtures, Node/Core unit tests,
hidden AppKit/SwiftUI and resource smoke, and a bounded accessory startup smoke
through the production app-delegate, main-menu and status-item wiring. It does
not display a window, request permissions or touch a device/CLI session, and
the accessory process exits immediately. Its generated smoke package directory
is removed by an exact-path safety check. Core tests use the pinned official
Swift Testing dependency; first resolution downloads public packages.

`make package` prints the signed app's absolute `appPath` as JSON. Each call
uses a fresh `build/package-*` directory. Open that `.app` to see the `CM` menu
bar item and choose Open Manager. To choose an output location explicitly:

```sh
make package PACKAGE_OUTPUT=build/my-preview
```

The output must be a new app location under `build/`; existing bundles are
never overwritten or removed. Ad-hoc signing is not notarization. No Apple
account is required for these local builds.

Swift Testing 6.2.4 can emit a known compile-time macro shutdown diagnostic
with this toolchain. Do not suppress it or skip rebuilding changed tests;
see the [toolchain notes](docs/phase-008-distribution-and-support.md).
All nonzero build/test exits remain failures.

Build and test SwiftPM commands use app-owned caches, home, temporary and
security directories, disable interactive credentials, strip GitHub/Copilot
token variables and apply a command-scoped Git include limited to this
repository. SwiftPM can inspect only its generated bare repositories here while
your global `safe.bareRepository=explicit` policy remains unchanged.

## Product documentation

Start with [the product charter and document map](docs/phase-000-product-charter.md).
The ten `docs/phase-00*.md` documents record the product decisions from the
2026-09-11 stakeholder interview and define the implementation and acceptance
contracts. Their numbering is a reading order, not a claim that any engineering
phase has shipped.

Implementation begins with the native GUI/emulator after developer setup,
then adds qualified live integrations. Simulation is never presented as
successful CLI or hardware control.

The initial target is an internal team using Apple Silicon Macs on macOS Tahoe
26.x, with 26.6.2 as the first qualification baseline. Intended terminals are
Ghostty, iTerm2 and Terminal.app; both USB and Bluetooth are intended for the
Creator Micro 2 Pro. GitHub Copilot desktop-app integration is out of scope.

This is an internal project. No open-source license is granted at this stage.
Do not copy unlicensed reference code or assets into it.
