# Copilot Micro

A native macOS menu bar companion that turns a Work Louder Creator Micro 2 Pro
into a control surface for GitHub Copilot CLI.

The keypad mirrors the selected CLI session's mode and activity, and provides
session management, model/effort, voice, input, cancellation and permission
controls. A graphical manager provides onboarding, remapping, diagnostics and
local configuration.

**Status:** direct-device macOS GUI with physically verified USB input and
lighting. The packaged app opens the Creator Micro 2 vendor HID interface,
validates the managed keymap, shows real key, dial and radial joystick events,
and applies matching runtime color/brightness to the 13 key LEDs and ambient
underglow. It does not write device flash. The owner-restricted IPC package,
read-only extension entry point and native session reconciler
implement the qualified Copilot CLI `1.0.84-5` observation subset. Normal app
launches now start the private authenticated listener and display its state,
and the signed app bundles the observer as an inert resource. An explicit
confirmation flow can install that exact observer into the user extension
directory with a versioned hash receipt; collisions and externally modified
files are preserved and blocked. After installation, the user can choose a
project and explicitly open a new token-bearing Copilot window in the one
qualified Ghostty installation. All stateful CLI actions remain disabled.
Validated terminal and CLI discovery plus the shared exact-target contract are
implemented. Ghostty `1.3.1` exact window/tab/terminal observation and focus
are qualified through its documented AppleScript API, including focus from
another foreground app and cleanup of a temporary multi-tab/split test window.
App-created Ghostty surfaces now carry a one-time association token into their
child process. The bridge registration can carry that token, and a race-safe
native registry resolves either launch/registration ordering without allowing
token reassignment. Live qualification proved exact child environment
inheritance and cleanup. Automatic association of an already running Copilot
CLI instance remains disabled because Ghostty exposes neither the terminal
child PID nor TTY. The packaged installation and launch flow has not yet been
used to claim a real Copilot CLI registration.

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
and status-item wiring. It validates the inert bundled observer resource but
does not display a window, open the production IPC listener, inspect or change
the user extension directory, load a CLI extension, request permissions or
touch a device, and the accessory process exits immediately. Hardware access
is explicitly suppressed only for smoke validation. Its generated smoke
package directory is removed by an exact-path safety check. Swift tests use the
pinned official Swift Testing dependency; first resolution downloads public
packages.

`make package` prints the signed app's absolute `appPath` as JSON. Each call
uses a fresh `build/package-*` directory. Open that `.app` to see the `CM` menu
bar item and choose Open Manager. A normal launch immediately attempts the
qualified non-exclusive HID connection. Close Work Louder Input and grant the
app Input Monitoring when macOS requests it. The manager then shows live
physical input and controls both key lighting and ambient underglow. The
Diagnostics view shows the exact user extension destination before offering
installation; installation and Open Copilot both require separate explicit
user actions. To choose an output location explicitly:

```sh
make package PACKAGE_OUTPUT=build/my-preview
```

The output must be a new app location under `build/`; existing bundles are
never overwritten or removed. Ad-hoc signing is not notarization. No Apple
account is required for these local builds. Because ad-hoc signatures are tied
to the built binary's code hash, replacing a development build requires a fresh
Input Monitoring grant. Install a build at a stable path before granting it.

## Local data

The direct-device manager keeps its current connection and input event list in
memory only. It does not upload telemetry or store raw HID reports. The
versioned configuration and bounded diagnostic libraries remain available for
later onboarding and CLI integration, but they are not exposed as pretend
device state in the current GUI.

## Local IPC foundation

`CopilotMicroBridge` implements a 64 KiB length-prefixed Unix-domain protocol,
same-user peer checks, a private bootstrap token, strict native/bridge roles,
connection generations, monotonic per-direction sequences, liveness and
bounded in-flight request tracking. Runtime directories are mode `0700`; token
and socket files are mode `0600`. Unknown existing socket paths and symlinked
private directories fail closed.

`Bridge/src/extension.mjs` is a thin host-provided-SDK entry point. It registers
no tools, hooks or permission handler, launches no CLI process, forwards no raw
SDK method and reads no GitHub/Copilot token. It joins only its host foreground
session, authenticates to the app-owned local socket, starts each extension
lifetime unknown, reconciles bounded snapshots after qualified events, sends
heartbeats and rejects all 16 production actions with compatibility-aware
reasons. Pending permission counts never become request authority.

The source-only Node client and native reconciler use the same registration and
frame contract. Replacement keeps host, session and generation identities
separate; stale generations, out-of-order state and liveness expiry invalidate
the binding. Normal packaged-app launches create or load the owner-only
bootstrap material, start the Unix socket listener, reconcile authenticated
registrations and connect surface tokens to the shared Ghostty association
registry. The menu and Diagnostics view report listener/connection state.
Smoke mode suppresses all bridge filesystem and socket access.

`make test-bridge` and `make test-core` exercise these paths using isolated
mocks and temporary real sockets. Packaging copies only the five reviewed
`Bridge/src/` modules into the signed app resources. The app never installs
them automatically: after confirmation it writes the exact files to
`~/.copilot/extensions/copilot-micro-session-bridge`, records their version
and SHA-256 hashes under application support, blocks unrelated or modified
destinations, retains an app-owned prior version on update, and refuses a
project that shadows the same extension name. Explicit Open Copilot creates a
new Ghostty surface instead of typing into an existing shell. Plugin-origin
name-collision preflight, uninstall, terminal selection UI and a real
app-to-CLI registration remain pending.

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

## Terminal and CLI discovery

Run the read-only local discovery probe with:

```sh
make qualify-terminals
```

The probe inspects supported application bundles in `/Applications`,
`~/Applications`, `/System/Applications` and
`/System/Applications/Utilities`, plus approved Copilot CLI executable paths.
It reads bundle metadata and executable attributes only. It does not launch a
terminal, run Copilot, inspect shell startup files or select a preferred
terminal.

On macOS `26.6.2` it found Ghostty `1.3.1` at
`/Applications/Ghostty.app`, Terminal `2.15` at
`/System/Applications/Utilities/Terminal.app`, and Copilot CLI `1.0.84-5` at
the stable Homebrew path `/opt/homebrew/bin/copilot`. iTerm2 was not installed.
The discovery model validates manual selections, deduplicates canonical paths
and requires explicit reselection if a saved application or CLI path moves;
it never silently switches to another installation with the same bundle ID.
See
[`Compatibility/terminal-discovery-macos-26.6.2.json`](Compatibility/terminal-discovery-macos-26.6.2.json).

`CopilotMicroTerminal` also defines the shared process/window/tab/pane target,
UI-context evidence and argument-array Open Copilot launch contracts. Its
Ghostty adapter reads only stable surface IDs, requires an explicit
CLI-instance binding, rejects multiple running Ghostty processes or a
different selected installation, and re-reads the hierarchy after focus before
reporting success. It never infers identity from terminal title or working
directory.

Run the read-only Ghostty probe only after approving macOS Automation access:

```sh
make qualify-ghostty CONSENT=I-authorize-read-only-ghostty-automation
```

The separately gated round-trip creates one temporary window containing two
tabs and one split, runs only `/usr/bin/true`, verifies exact focus from
another foreground app and closes only the created window:

```sh
make qualify-ghostty-roundtrip \
  CONSENT=I-authorize-temporary-ghostty-window-test
```

The association qualifier creates one temporary window running only the local
probe executable. It verifies that Ghostty passes an exact one-time
`COPILOT_MICRO_SURFACE_TOKEN` into the child process, removes the private
result and closes the exact created window:

```sh
make qualify-ghostty-association \
  CONSENT=I-authorize-ghostty-environment-test
```

The live macOS `26.6.2` result is recorded in
[`Compatibility/ghostty-1.3.1-macos-26.6.2.json`](Compatibility/ghostty-1.3.1-macos-26.6.2.json).
Ghostty's scripting dictionary has no terminal child PID or TTY, so existing
manually launched CLI sessions cannot be bound safely. App-created surface
token transport is implemented and live-qualified. The packaged app now starts
the authenticated bridge and exposes an explicit install-and-launch path, but
that path has not yet claimed a real extension registration. Composer, picker,
permission and question context also remain unavailable rather than being
approximated with terminal text or global keystrokes.

## Live hardware app and qualification

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
`1` (firmware layer number `2`), three layers and key rows `[2,4,4,3]`; see
[`Compatibility/creator-micro-2-0x8298-firmware-0.6.2-usb.json`](Compatibility/creator-micro-2-0x8298-firmware-0.6.2-usb.json).
This proves read-only transport and explicitly disproves any assumption that
the active layer is the first layer. Follow-on USB qualification has also
verified reversible keymap writes, physical input and key lighting. Bluetooth
and exact Pro marketing identity remain unqualified.

If opening the vendor collection is denied, grant Input Monitoring to the app
or terminal running the probe, wake the device and retry. `make check` never
opens HID. A normal packaged app launch now opens the qualified USB device,
checks firmware/status/keymap state and displays normalized input in the GUI.

## Reversible device mapping preview

The guarded setup tool stores the full original keymap in a user-only,
device-associated integrity envelope before it can authorize a configuration
write. It never prints the raw serial or full keymap. Generate the exact
non-mutating preview with:

```sh
make preview-device-mapping CONSENT=I-own-this-device-read
```

The current USB preview verified the persisted original backup and proposes 15
changes: keys `AG00` through `AG12` and dial directions `AG13`/`AG14` on active
array index `1` (firmware layer number `2`). Encoder press, all joystick
bindings, lighting, macros, other layers and unknown fields are preserved.
Firmware `0.6.2` emits native `kb.radial` notifications for the joystick, so
joystick input does not require persistent keymap changes.

Applying or restoring requires the exact transaction digest printed by a fresh
preview and a declaration that other device configurators are closed. The
digest binds the
operation, private device association, source and target configurations,
verified backup, active profile/layer and normalized change set. A mutating
command rejects known Work Louder configurators, rechecks the source, saves a
fresh pre-change snapshot, writes the full keymap once and verifies a complete
read-back. Unexpected competing RPC responses block the write when detected
during preflight; traffic first observed afterward preserves the verified
receipt and emits an explicit contention warning. These commands are
intentionally not part of `make check`.

Firmware `0.6.2` applied the first USB `fs.write` without returning its
acknowledgement.
The setup tool treats that timeout as ambiguous, reconnects read-only and
reports success only if the complete keymap matches the reviewed target.

The first USB write was independently read back at the exact target SHA-256
and proved timeout reconciliation, but physical input showed that firmware
layer number `2` selects zero-based array index `1`, not index `2`. The device
was then restored to the verified original and the reduced 15-change target
was applied and fully read back at
`960f81df54396b8000c564b8d8e2a717d010e1699151cc83170966b67d7d1285`.

With the managed map present, observe normalized hardware input without
routing any actions:

```sh
make observe-device-input CONSENT=I-own-this-device-observe-input SECONDS=30
```

The bounded observer prints only sanitized key/control identifiers and
press/release or detent transitions. It does not connect to Copilot CLI.

USB firmware `0.6.2` emits keys and dial actions through `v.oai.hid` and the
joystick through `kb.radial`. Measured cardinal angles are approximately east
`0.013`, south `0.238`, west `0.487` and north `0.762`. Normalization activates
at distance `0.5`, returns to neutral at `0.2`, ignores diagonal sectors and
requires neutral before another direction. Controlled tests verified a held
key does not repeat and that center/left/right presses of the two-contact wide
key each produce one logical Submit press/release pair.

Run the bounded physical key-lighting sequence with:

```sh
make qualify-device-lighting \
  CONSENT=I-closed-other-device-configurators-and-authorize-key-lighting-test \
  HOLD_SECONDS=2
```

On the qualified USB tuple, all 13 key LEDs physically displayed white, blue,
purple, amber, green, red and off at 35% brightness. Every command returned
`{"ok":1}`. The original probe left the ambient zone unchanged. The production
GUI now writes the key and ambient zones together, and physical testing
confirmed that both match the selected color. Neither path writes device
flash. Host-driven blink/pulse timing, Bluetooth, sleep/wake and latency remain
unqualified. Sanitized probe evidence is recorded in
[`Compatibility/live-creator-micro-2-0x8298-firmware-0.6.2-usb.json`](Compatibility/live-creator-micro-2-0x8298-firmware-0.6.2-usb.json).

## Production session observation source

The production observer source is not a qualification launcher and is not
installed by any repository command. I-07 promotes only behavior already
qualified by the disposable probe; installation, live app activation and every
stateful control remain future work.

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

The current app is a live hardware manager. CLI integration is added only
after its targeting and action contracts are qualified.

The initial target is an internal team using Apple Silicon Macs on macOS Tahoe
26.x, with 26.6.2 as the first qualification baseline. Intended terminals are
Ghostty, iTerm2 and Terminal.app; both USB and Bluetooth are intended for the
Creator Micro 2 Pro. GitHub Copilot desktop-app integration is out of scope.

This project is available under the MIT license in [`LICENSE`](LICENSE). Do not
copy unlicensed reference code or assets into it.
