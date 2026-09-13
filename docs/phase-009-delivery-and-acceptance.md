# Phase 009: delivery and acceptance

Status: implementation plan, current qualification ledger and acceptance
contract. A feature is implemented or qualified only where evidence is stated.

Current evidence: stage 0, the native manager and the local
configuration/diagnostic foundation are implemented. I-07 adds
native/Node mock evidence for an uninstalled read-only stage-3 observer:
private authenticated IPC, host/session/generation separation, unknown-first
snapshots, event reconciliation, capability changes, liveness/replacement and
explicit rejection of all stateful actions. The app does not start it. A
separate source-only probe joined owned disposable Copilot CLI `1.0.84-5`
sessions and produced the compatibility ceiling used by I-07.
USB HID discovery/read, durable original backup, guarded restore, reduced
15-change mapping and complete read-back now have real-device evidence.
Firmware omitted both write acknowledgements, so the transport reconciled each
timeout through a fresh read-only connection. All keys, both dial directions,
native radial joystick cardinals and steady all-key colors are physically
qualified. The production app now owns the USB device connection, shows real
input in its GUI and physically drives matching key and ambient colors.
Terminal targeting, live CLI actions, host-driven blink/pulse, Bluetooth,
sleep/wake, latency and updater remain unqualified.

## Delivery strategy

The implementation began with the native shell and deterministic contracts,
then replaced its temporary synthetic state with direct device ownership. A
stock Command Line Tools/SwiftPM build path is verified; full Xcode is not a
universal prerequisite for the native app.
Introduce live integrations only after their contracts and safety gates are
qualified. Preserve the complete agreed scope and report unsupported
integrations explicitly; do not replace them with dangerous shortcuts.

| Stage | Deliverable | Exit evidence |
|---|---|---|
| 0. Developer foundation | Verified Swift/macOS SDK and reproducible SwiftPM native build/package tooling | Local prerequisites, packaged resources and headless scaffold checks succeed; Xcode-only checks remain distinct |
| 1. Native GUI foundation | Menu panel, manager and deterministic state/input model | Headless layout and lifecycle checks pass without HID/CLI side effects |
| 2. Contract probes | Exact CLI/terminal/firmware qualification and unsupported-feature ledger | Session identity, native actions, state/visibility evidence and versions recorded without touching production work |
| 3. Session bridge | Trusted CLI-hosted extension plus private local IPC and mock receiver | Two disposable sessions demonstrate isolation, state correlation, replacement and reconnect |
| 4. Real device slice | Backed-up managed map, one action and visible mode/activity lighting | USB and Bluetooth behavior, read-back and original-map restoration exercised |
| 5. Qualified controls | Session lifecycle, model/effort, input, voice and guarded permissions | Each enabled feature has terminal-specific evidence and safety tests |
| 6. Complete product journeys | Live onboarding, settings, configuration/restore, diagnostics and optional notifications/login | A teammate completes real setup/recovery without a raw RPC console |
| 7. Internal distribution | Packaged app, compatible bridge, private diagnostics and approved updater | Install/update/uninstall/recovery exercised; gaps disclosed |
| 8. Internal release | Polished supported subset and a complete delivery report | Every shipped feature passes its acceptance cases; remaining intended features are clearly unavailable |

Signing/notarization is a later milestone. It must not be accidentally made
a prerequisite for the stakeholder's initial ad-hoc internal distribution,
but update integrity remains required.

## Integration uncertainty ledger

The CLI results below come from owned disposable sessions on 2026-09-12. The
machine-readable evidence is
[`Compatibility/copilot-cli-1.0.84-5.json`](../Compatibility/copilot-cli-1.0.84-5.json).
Partial means useful behavior was demonstrated but the full required product
contract was not.

| ID | Area | Status | Current result | Required result or gap |
|---|---|---|---|---|
| U-01 | Foreground-session extension lifecycle | Partial | `joinSession()` and `/clear` replacement/reload worked under one host; arbitrary existing-session selection was not tested | Join/replacement/selection synchronization demonstrated |
| U-02 | Authoritative initial state and acknowledgement | Partial | Mode/task/queue/pending snapshots and activity boundaries were observable; verified user acknowledgement was not | Mode, activity, pending requests and user acknowledgement qualified; unsupported signals disclosed |
| U-03 | Native list/switch/new/archive operations | Unavailable | No callable extension surface demonstrated these host UI operations | Real host behavior, not fabricated commands or private-file edits |
| U-04 | Exact terminal window/tab/pane targeting | Contract only | Validated installation/CLI discovery, exact preference revalidation and typed process/window/tab/pane evidence are implemented; no terminal adapter is qualified | Separate evidence for each terminal |
| U-05 | Existing composer focus/submit | Unavailable | Completion trigger metadata was readable; no actual draft focus/submit API was demonstrated | Preserve and submit the actual draft once; no `session.send()` substitute |
| U-06 | CLI voice lifecycle/dependencies | Unavailable | No voice RPC or live voice command was demonstrated | Native voice start/stop/state and required grants verified |
| U-07 | Visible request and permission authority | Unavailable | Pending counts were readable; event bridging returned success but delivered no permission event for a visible TUI prompt | Request-ID-specific one-shot decision, visibility and concurrent-response races verified |
| U-08 | Model and effort capabilities | Partial | Current model/choices read; interactive/plan restored; same effort written/read; no different model or next-turn semantics | Available values/read-back and next-turn semantics verified |
| U-09 | Current Pro firmware and both transports | Partial | USB PID `0x8298`, firmware `0.6.2`, layer normalization, original restore, reduced 15-change map, production app ownership, all keys/dial directions, native radial joystick cardinals and matching steady key/ambient colors are physically verified | Bluetooth, sleep/wake, animated lighting and event-to-light latency remain |
| U-10 | Safe internal built-in updater | Unproven | No updater probe in this work package | Configured source/auth, trusted integrity and recoverable replacement, or disabled updater with gap |

Qualification probes must not authorize production tools, alter real work, flash
firmware, change global CLI permissions or attach to sessions without explicit
test ownership.

## Acceptance matrix

| ID | Features | Required scenario and expected outcome |
|---|---|---|
| A-01 | F-19, F-20 | Detect multiple/no terminals, show actual findings, confirm preference, persist it, and recover from a removed app without silent fallback |
| A-02 | F-01 | Two disposable CLI instances/sessions exist; select one, replace its foreground session and reconnect; no action reaches the other or an old generation |
| A-03 | F-02 | Change default/plan/autopilot from both CLI and pad; all key LEDs follow white/blue/purple for the actual selected session |
| A-04 | F-03 | Busy uses mode blink; pending human input uses amber pulse; error red; no connection/unknown off; no guessed green |
| A-05 | F-03 | Complete work while already visible: green persists until later verified interaction; select/view a completed session to acknowledge; abort/initial idle never count as clean completion |
| A-06 | F-01, F-04, F-05, F-13, F-14, F-15 | From another app or wrong terminal pane, first press only focuses; no queued/delayed original action; next press independently validates context |
| A-07 | F-04 | Sessions opens the actual native CLI session-list tab/view |
| A-08 | F-05 | Dial/joystick moves highlight without premature selection; Confirm/Back behave correctly; Previous/Next use qualified native selection |
| A-09 | F-06 | Chooser cancellation preserves the current session; a chosen existing directory creates/selects a new native session without mutating the old session's directory |
| A-10 | F-07 | Idle archive uses native archive, retains recoverable history, and reflects the CLI's resulting selection |
| A-11 | F-07, F-12 | Busy archive requests cancellation consent, cancels only foreground work, and refuses archive while background/queued work or unresolved input remains |
| A-12 | F-12 | Cancel does not kill CLI, drop queued prompts, stop unrelated/background agents or claim rollback; request acknowledgement is distinguished from settled cancellation |
| A-13 | F-08 | Mode cycles/read-back match host behavior and preserve policy/any autopilot confirmation without enabling allow-all |
| A-14 | F-09, F-10 | Runtime model/effort choices reflect capabilities; changes made outside the pad are observed; in-flight inference is not claimed to have changed |
| A-15 | F-11 | CLI voice starts/stops through a qualified path, missing dependencies are explicit, and no alternative provider or unapproved download is used |
| A-16 | F-13 | Submit preserves and sends the existing draft exactly once; wide-key duplication/hold and non-composer dialogs do not cause another submission or approval |
| A-17 | F-14 | Focus reaches the actual composer without clearing/submitting content |
| A-18 | F-15 | Approve/reject requires the exact already-visible request, targets it once, respects policy, handles another client answering first, and rejects held/stale/reconnected events |
| A-19 | F-16 | Every supported physical control is remappable; invalid/unsupported actions are explained; editor selection does not execute an action |
| A-20 | F-17 | Brightness clamps safely, preserves state meaning and remains useful with textual status at zero brightness |
| A-21 | F-18 | Import/export preserves supported portable settings; malformed/future-schema/arbitrary-command data cannot change active config or install/run anything |
| A-22 | F-19, F-22 | Setup cannot write without backup/consent; restore verifies identity/integrity and read-back; mismatched or externally changed maps are not silently overwritten |
| A-23 | F-21, F-22 | Closing manager keeps app alive; Pause/Quit do not rewrite keymap; original restore remains explicit; no CLI is silently launched |
| A-24 | F-23 | USB and Bluetooth, sleep/wake, unplug/replug and transport switch recover without stale input; ACK-only lighting failure is not counted as physical success |
| A-25 | F-24 | Missing auth, tampered/signature-failing artifacts, incompatible versions and failed replacement cannot install; explicit approval, recovery and preserved CLI/config/backups are exercised |
| A-26 | F-25 | Local diagnostics are bounded; planted tokens/prompts/paths/commands do not leak into export; no telemetry/network upload occurs |
| A-27 | F-26 | Notifications default off, require opt-in, and omit sensitive content |
| A-28 | F-19, F-21 | Core onboarding/manager flows work with keyboard/accessibility labels; textual state exists independently of color; disconnected hardware is never shown as connected |
| A-29 | F-01, F-15, F-25 | Wrong peers, malformed/oversized/out-of-order messages, duplicate requests and stale generations fail explicitly without action; reconnect requires synchronization |
| A-30 | F-02, F-03, F-23 | Measure authoritative native event receipt to HID write completion against the 250 ms USB/500 ms Bluetooth targets; separately verify physical output and reduced-motion presentation |
| A-31 | F-01, F-21, F-25 | Focus-consumed, rejected, timed-out and failed actions show distinct useful feedback without corrupting session-state lighting or silently retrying |
| A-32 | F-19, F-24 | Bridge install/update/uninstall handles collisions, modified files and incompatible protocols without overwriting unrelated extensions or restarting CLI |
| A-33 | F-16, F-22, F-23 | Fragmented UTF-8, large/invalid configs, interrupted writes, non-first active layers, external map changes and competing clients cannot lose the original map or trigger repeated flash writes |

### Cross-cutting coverage

| Quality requirement | Acceptance evidence |
|---|---|
| Q-01: correct target | A-02, A-06, A-18, A-29 |
| Q-02: explicit action feedback | A-31 |
| Q-03: reversible, bounded device writes | A-22, A-23, A-24, A-33 |
| Q-04: accessible native experience | A-28, A-30 |
| Q-05: bounded private data | A-21, A-26, A-27 |
| Q-06: explicit incompatibility/disconnect behavior | A-01, A-02, A-18, A-24, A-29, A-32 |
| Q-07: measured responsiveness | A-30 |
| Q-08: safe updates | A-25, A-32 |

All S-01 through S-08 invariants in
[phase 007](phase-007-security-privacy-and-safety.md) apply across these tests.
No skipped feature waives an invariant for a shipped feature.

## Qualification matrix

For every shipped terminal-dependent feature, record Ghostty, iTerm2 and
Terminal.app separately. Exercise USB and Bluetooth for hardware-dependent
features. Record the actual Apple Silicon model, Tahoe patch/build, app,
CLI/bundled SDK and firmware versions.

Use 26.6.2 as the initial baseline. Supporting Tahoe 26.x as a policy is not
evidence that all patches have been tested. Mark unqualified combinations
honestly and expand evidence deliberately.

Cases must include:

- CLI not running, not logged in, incompatible, disconnected and replaced.
- Missing/revoked Input Monitoring and any feature-specific UI grants.
- Multiple terminal windows/tabs/panes and a different foreground app.
- Native session changes made without the hardware.
- Concurrent foreground/background work and queued prompts.
- Permission, question, plan and picker context collisions.
- Rapid/held/duplicate physical input and wide-key contact duplication.
- Update interruption and ad-hoc trust/permission re-grant behavior.

## Evidence and test layers

Use unit tests for deterministic state/actions/configuration and byte framing.
The current native/Node IPC tests cover temporary local sockets, shared negative
fixtures and deterministic I-07 observer/reconciler behavior. They provide
partial A-02/A-29 evidence for identity separation, replacement, stale
generation rejection, ordered reconciliation and liveness, not live production
session isolation. Every action rejection is tested, but no action execution is
qualified. The disposable probe provides bounded evidence for U-01 through
U-08 only; it does not use the production bridge. Use further
contract/integration tests with owned disposable CLI sessions for installed
bridge and terminal behavior. Use real-device qualification for physical
geometry, lighting, transport and restore.

The hardware tools and production app provide partial U-09 evidence and validate byte-fragment
reassembly, request bounds, active profile identity, a non-first active layer,
durable backup, an actual restore, the reduced managed map, complete read-back,
physical input, production USB service ownership and matching steady
key/ambient output. They do not fully satisfy A-22, A-24, A-30 or A-33 because
interruption recovery, Bluetooth, sleep/wake, animated output and latency
remain unexercised.

Headless UI tests do not qualify hardware. Mock request responses do not qualify
the real CLI. HID acknowledgements do not prove visible LEDs. A successful
compile does not qualify app onboarding or permissions.

Use the canonical commands as source scaffolding lands. Currently `make check`
covers source checks, shared native/Node IPC fixtures, isolated Node client
tests, isolated probe privacy/classification tests, Swift package tests,
packaged hidden native smoke and a bounded accessory
startup smoke through the production delegate, main-menu and status-item
lifecycle wiring. The smoke opens no manager window or production listener,
exits immediately and removes only its exact generated package directory.
`make package` produces the retained ad-hoc-signed app. These do not establish
complete GUI interaction, XCUITest, terminal or hardware qualification; do not
describe unimplemented or unexercised acceptance cases as passing.

`make qualify-cli CONSENT=I-own-this-disposable-session` is an explicit
interactive live target and is not part of `make check`. It stages the passive
extension in a private owned disposable repository, strips GitHub/Copilot token
environment variables and cleans only marker-verified paths. The default probe
registers no tools, hooks or permission handler.

No I-07 command installs or loads `Bridge/src/extension.mjs`, and `make check`
does not launch Copilot CLI or open HID. The shipped app resource enables the
direct device service during normal launches but starts no production CLI
listener or session service.

Measure Q-07's host-event-to-HID-write targets under defined connected
conditions and separately observe physical output. Track regression evidence
with the relevant feature and configuration tuple.

## Delivery report contract

Every implementation delivery ends with:

| Field | Required content |
|---|---|
| Build identity | Commit/version and package type |
| Supported configuration | Actual app/CLI/SDK/OS/terminal/firmware/transport evidence |
| Shipped features | F-IDs with corresponding acceptance evidence |
| Gaps | Each skipped/blocked feature, exact reason, affected users and disposition |
| Safety result | Wrong-target, approval, cancellation and device-recovery outcomes |
| Operational limitations | Ad-hoc trust friction, update dependencies and known recovery needs |
| Data policy | Confirmation of local-only diagnostics and export behavior |

Classify a gap as unimplemented, upstream API missing, incompatible version,
permission/policy blocked or qualification failed. Include a safe workaround
only when it is real and does not change the feature's meaning.

Do not say "complete" while omitting a requested feature. A useful, polished
subset is acceptable under the stakeholder's explicit gap policy; misleading
support claims and unsafe substitutes are not.

## Current completion boundary

The phase-00 documentation, native foundation, direct-device GUI, local storage,
diagnostics, authenticated IPC contract, disposable CLI qualification and I-07
read-only observer/reconciler source are implemented. I-08 validated terminal
and CLI installation discovery and the shared exact-target contract. Production
USB hardware ownership, normalized input display and matching key/ambient
runtime lighting are physically verified. Stateful CLI control,
terminal-specific targeting, Bluetooth, animated lighting, sleep/wake, latency,
updater and their complete acceptance journeys remain future work.
Compatibility evidence and mock I-07 checks are work-package results, not a
claim that the CLI controller is complete.
