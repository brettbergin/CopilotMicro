# Copilot Micro

A native macOS menu bar companion that turns a Work Louder Creator Micro 2 Pro
into a control surface for GitHub Copilot CLI.

The keypad mirrors the selected CLI session's mode and activity, and provides
session management, model/effort, voice, input, cancellation and permission
controls. A graphical manager provides onboarding, remapping, diagnostics and
local configuration.

**Status:** interactive GUI emulator. The menu panel, seven-area manager,
original pad editor, session/control simulator, lighting preview, app packaging,
versioned contracts, deterministic reducers, atomic local settings, previewed
portable import/export and bounded redacted diagnostics exist. Live product
hardware/CLI control remains unavailable and clearly disabled. A read-only
developer hardware probe can now discover and inspect an explicitly owned
Creator Micro 2 without changing its configuration or lighting. An
owner-restricted Unix-domain IPC package and isolated Node client now share
bounded authentication, framing, role, generation and sequence contracts, but
the app does not start that listener and no production CLI extension is
installed. A source-only disposable probe has joined owned Copilot CLI
`1.0.84-5` sessions and recorded a conservative compatibility report; it is
not production session control.

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

`make check` runs source checks, shared contract fixtures, isolated Node IPC
tests, Swift package unit tests, hidden AppKit/SwiftUI and resource smoke, and a
bounded accessory startup smoke through the production app-delegate, main-menu
and status-item wiring. It does not display a window, open the production IPC
listener, load a CLI extension, request permissions or touch a device/CLI
session, and the accessory process exits immediately. Its generated smoke
package directory is removed by an exact-path safety check. Swift tests use the
pinned official Swift Testing dependency; first resolution downloads public
packages.

`make package` prints the signed app's absolute `appPath` as JSON. Each call
uses a fresh `build/package-*` directory. Open that `.app` to see the `CM` menu
bar item and choose Open Manager. In the manager, choose demo scenarios,
edit local key assignments, use the separate input simulator and inspect the
all-key lighting projection. These interactions never open HID, attach to a
CLI, install an extension or request macOS permissions. To choose an output
location explicitly:

```sh
make package PACKAGE_OUTPUT=build/my-preview
```

The output must be a new app location under `build/`; existing bundles are
never overwritten or removed. Ad-hoc signing is not notarization. No Apple
account is required for these local builds.

## Local data

Ordinary app launches store versioned settings under
`~/Library/Application Support/Copilot Micro/`. Configuration writes are
atomic and user-only. Malformed or legacy input is preserved in bounded
recovery copies before the user explicitly installs safe defaults or a
migration replaces it.

Portable JSON includes all twelve control bindings, brightness, reduced motion
and the notification preference. Import validates the complete allowlist,
shows every change and requires confirmation. Exports omit terminal and CLI
paths, recent directories, backups, live identifiers and diagnostics.

Structured diagnostics use bounded categories and redacted messages, rotate at
three 5 MiB segments and never upload automatically. Export and clearing are
explicit manager actions; clearing diagnostics does not remove configuration
recovery material. Packaging smoke disables local storage entirely.

## Local IPC foundation

`CopilotMicroBridge` implements a 64 KiB length-prefixed Unix-domain protocol,
same-user peer checks, a private bootstrap token, strict native/bridge roles,
connection generations, monotonic per-direction sequences and bounded
in-flight request tracking. Runtime directories are mode `0700`; token and
socket files are mode `0600`. Unknown existing socket paths and symlinked
private directories fail closed.

The source-only Node client uses the same registration and frame contract.
`make test-bridge` exercises it against isolated temporary sockets; nothing
under `Bridge/` is placed in `.github/extensions/` or loaded into a real
Copilot CLI session. Production listener startup, bridge installation and
session behavior remain intentionally blocked until disposable capability
probes qualify the actual installed CLI.

## Disposable CLI qualification

`Bridge/probe/` contains a passive, source-only extension that is copied into
an owned private disposable Git repository only after exact consent. It is
never installed from this checkout and registers no tools, hooks or permission
decision handler. Structured evidence is capped at 256 records, 128 KiB total
and 8 KiB per record, uses mode `0600`, aliases live identifiers and excludes
prompts, responses, commands, tool arguments/results, paths and tokens.

The initial live report is
[`Compatibility/copilot-cli-1.0.84-5.json`](Compatibility/copilot-cli-1.0.84-5.json).
On Copilot CLI `1.0.84-5` (build `0de509ce`, bundled SDK
`1.0.13-preview.4`, child Node `v24.20.0`):

- `joinSession()` succeeded and `/clear` produced a replacement extension and
  session lifetime under the same host; arbitrary existing-session selection
  was not demonstrated.
- Mode, model, effort, task, queue and limited event surfaces were readable.
  Interactive/plan mode round-tripped and was restored, but model/effort
  next-turn semantics remain partial.
- Native session list/switch/new/archive, actual composer focus/submit and
  voice lifecycle were unavailable from the tested extension surface.
- Pending permission counts were readable, but a visible TUI permission prompt
  did not emit `permission.requested` to the extension even after the
  per-client event bridge reported success. Hardware approve/reject remains
  unavailable.

Run only the isolated tests during normal development:

```sh
make test-cli-probe
```

Launching a new live probe requires an interactive terminal and exact consent:

```sh
make qualify-cli CONSENT=I-own-this-disposable-session
```

Add `ACTIVE=1` only to exercise the fixed reversible mode/effort probes in the
owned session. The qualifier does not pass a synthetic session ID, strips
GitHub/Copilot token environment variables and removes only its marker-verified
workspace unless explicitly kept. Normal `make check` stages/tests the probe
but never launches Copilot CLI.

## Read-only hardware qualification

`CopilotMicroDevice` implements native IOKit discovery and a bounded,
byte-oriented 64-byte HID JSON-RPC transport. Candidate selection requires
Work Louder vendor ID `0x303A`, product ID `0x8297` or `0x8298`, a Creator
Micro 2 product name, vendor usage page `0xFF00` usage `1`, and 64-byte input
and output reports. The transport opens non-exclusively and exposes only three
read methods: `sys.version`, `device.status`, and `fs.read` for
`keymap.json`.

Run the explicit developer probe:

```sh
make qualify-hardware CONSENT=I-own-this-device-read
```

The output omits the serial number and full keymap. It reports bounded identity,
firmware, status and keymap-shape metadata. The initial USB qualification found
product `Creator Micro 2`, PID `0x8298`, firmware `0.6.2`, active layer index
`2`, three layers and key rows `[2,4,4,3]`; see
[`Compatibility/creator-micro-2-0x8298-firmware-0.6.2-usb.json`](Compatibility/creator-micro-2-0x8298-firmware-0.6.2-usb.json).
This proves read-only transport and explicitly disproves any assumption that
the active layer is the first layer. It does not yet qualify Bluetooth, Pro
marketing identity, physical input, lighting or keymap writes.

If opening the vendor collection is denied, grant Input Monitoring to the
terminal running the probe, wake the device and retry. `make check` never opens
HID. The packaged GUI remains emulator-only until the later live service
assembly is complete.

## Reversible device mapping preview

The guarded setup tool stores the full original keymap in a user-only,
device-associated integrity envelope before it can authorize a configuration
write. It never prints the raw serial or full keymap. Generate the exact
non-mutating preview with:

```sh
make preview-device-mapping CONSENT=I-own-this-device-read
```

The current USB preview verified the persisted original backup and proposed 19
changes: keys `AG00` through `AG12` and dial directions `AG13`/`AG14` on active
layer `2`, plus cardinal joystick events `AG15` through `AG18` in the unique
layer containing the radial sectors. Encoder press, joystick diagonals,
lighting, macros, other layers and unknown fields are preserved.

Applying or restoring requires the exact transaction digest printed by a fresh
preview and the corresponding full consent phrase. The digest binds the
operation, private device association, source and target configurations,
verified backup, active profile/layer and normalized change set. A mutating
command opens the HID interface exclusively, rechecks the source, saves a
pre-change snapshot, writes the full keymap once and verifies a complete
read-back. Exclusive configuration access may require granting Input Monitoring
to the terminal running the command. These commands are intentionally not part
of `make check`.

No device mapping has been applied yet. Physical input and lighting remain
unqualified until the reviewed mapping is explicitly approved and exercised.

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
