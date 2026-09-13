# Phase 003: controls and lighting

Scope: F-02, F-03, F-05, F-08 through F-17.
Status: agreed UX; exact wire behavior requires hardware qualification.

Implementation status: `CopilotMicroCore` contains deterministic
physical-contact normalization, session reduction and lighting projection.
USB firmware `0.6.2` has physical evidence for all key contacts, both dial
directions, native radial joystick cardinals and steady
white/blue/purple/amber/green/red/off output. The production app owns the USB
device service and renders real controls while driving matching key/ambient
colors. Host-driven blink/pulse, Bluetooth, sleep/wake and event-to-light
latency remain unqualified.

## Physical model

Creator Micro 2 Pro reference evidence describes 13 switch/LED positions under
12 keycaps. The wide bottom key covers two positions and is one user-facing
control. The top row's electrical order is reversed relative to visual order.

Use stable logical control IDs in configuration, not incidental device
enumeration indices. Keep variant-specific matrix mapping inside the device
adapter. The reference mapping below is a qualification starting point, not a
promise for every firmware/hardware revision.

| Visual position | Logical control | Reference matrix ID | Default action |
|---|---|---|---|
| Top left | `key.new` | 0 | New session/project chooser |
| Top right | `key.sessions` | 1 | Open native Sessions list |
| Second row, first | `key.previous` | 2 | Previous session |
| Second row, second | `key.next` | 3 | Next session |
| Second row, third | `key.archive` | 4 | Archive selected session |
| Second row, fourth | `key.mode` | 5 | Cycle mode |
| Third row, first | `key.model` | 6 | Model picker |
| Third row, second | `key.effort` | 7 | Reasoning-effort picker |
| Third row, third | `key.voice` | 8 | CLI voice/dictation |
| Third row, fourth | `key.cancel` | 9 | Cancel foreground task |
| Bottom wide | `key.submit` | 10 and 11 | Submit current CLI input |
| Bottom right | `key.focus` | 12 | Focus CLI input |

`key.*` identifiers name physical positions/default roles, not immutable
assignments. The editor may assign another supported action to a position.

| Control | Default behavior |
|---|---|
| Dial clockwise/counterclockwise | Open/browse native session list; move highlight |
| Dial press | Confirm highlighted item in a verified active picker |
| Joystick north/south | Navigate the verified active session/model/effort menu |
| Joystick east | Confirm a verified picker; approve once only in an exact visible tool-permission context |
| Joystick west | Back/cancel a verified picker; reject only in an exact visible tool-permission context |
| Joystick diagonals | No product action until deliberately supported and mapped |
| Touch sensor | Not required initially; disclose lack of support rather than invent a gesture |

Native UI and companion pickers must not compete for the same gesture. If
their contexts are ambiguous, reject the gesture and explain. A confirm
gesture with no qualified active context is not a generic Enter key.

## Input normalization

Normalize raw firmware input into press/release, dial detents and joystick
direction events. Apply device-specific de-duplication before routing actions.

- Treat the two wide-key positions as one physical gesture. One press must
  never submit twice.
- Trigger one-shot actions on a qualified press edge, not both press and release.
- Held approval/rejection, submit, new, archive and cancel controls must not
  auto-repeat.
- Dial/list navigation may repeat at a bounded, tested rate. Do not overflow
  command queues or skip stale-target checks.
- A joystick must return through a qualified neutral/deadzone transition
  before another one-shot confirmation; ignore unqualified diagonals.
- Do not replay input after reconnect, wake, session replacement or permission
  recovery.
- Remapping is constrained by capability and safety rules. Renaming a binding
  cannot turn approval into unrestricted text injection.

Exact debounce/deadzone parameters are engineering settings derived from
observed hardware, not fabricated physical specifications. Record them and
exercise slow, rapid, held and simultaneous input.

On the qualified USB firmware, key and dial events use `v.oai.hid`; the
joystick uses `kb.radial` with normalized angle/distance. Measured cardinal
centers are approximately east `0.013`, south `0.238`, west `0.487` and north
`0.762`. The current normalizer activates at distance `0.5`, releases at `0.2`,
accepts angles within `0.0625` of a cardinal center and ignores diagonals.
A controlled held-key test produced one press/release pair without repeat.
Center, far-left and far-right presses of the two-contact wide key each
produced one logical Submit pair.

## Mode colors

| Product mode | Runtime meaning | Default hue |
|---|---|---|
| Default | Ordinary interactive/standard CLI mode | White |
| Plan | Plan mode | Blue |
| Autopilot | Autopilot mode | Purple |

Use the actual selected CLI session's mode, including changes made through
its keyboard/mouse UI. Do not infer mode from our last issued command.

Unknown runtime modes are unknown, not default/white. Keep the last known
color out of the live-state display when it could mislead. The manager must
explain the missing state.

Exact RGB values are presentation tokens to tune against the standard CLI
hues and the physical LEDs during qualification. The requirement is the
agreed white/blue/purple semantic match, not an unsupported promise of
colorimetric identity with the screen.

## LED state machine

All key LEDs display the same selected-session state. Do not assign different
sessions to different key colors or retain fixed action colors.

Evaluate this precedence, highest first:

| Condition | Key LEDs | Textual state |
|---|---|---|
| Paused or no valid live CLI binding | Off | Paused or Disconnected |
| Live binding but state cannot be established | Off | State unknown, with explanation |
| Unresolved selected-session error | Steady red | Error |
| Verified pending permission/question/elicitation/plan decision | Amber pulse | Needs permission or Needs input |
| Selected session still has active foreground/background work | Blink current mode color | Working |
| Clean completion not acknowledged | Steady green | Completed |
| Otherwise idle with known mode | Steady mode color | Default, Plan or Autopilot |

Connection loss overrides a cached error/completion. A device write failure
must surface in the menu bar even when the app cannot physically display red.
An ordinary rejected button press is action feedback, not proof that the
underlying CLI session itself has failed.

Do not promote every recoverable tool error into a terminal session failure.
Clear a prior task-error indication only on authoritative recovery or verified
new work, not on a repaint, poll or ordinary acknowledgement. Classify actual
host error/recovery signals during qualification.

Pulse means a smooth brightness envelope; busy blink means an obvious
on/off mode-color pattern. Initial tuning may use a one-second attention
pulse and a 500 ms full busy cycle. Make the effect definitions deterministic
and test them; do not rely on firmware effect labels alone.

In reduced-motion presentation, use steady amber for attention and steady
mode color for busy, with the corresponding text/badge in the menu bar.
Other states retain their normal steady colors. Explain the non-animated
alternative in Lighting settings and honor the macOS preference.

Brightness is user-adjustable. Clamp to the qualified device range. Setting
brightness to zero does not disable textual status. Avoid maximum brightness
as an unexplained default.

The ambient underglow is part of the selected-session status display and must
match the key LEDs in color, brightness and effect. The app owns both runtime
lighting zones while connected, discloses that behavior in the manager and
does not write lighting state to device flash.

The first physical lighting sequence used `v.oai.thstatus` at 35% brightness.
All 13 key LEDs visibly followed white, blue, purple, amber, green, red and
off. The bottom ambient LEDs deliberately did not follow because the probe
never called the zone API. The production app subsequently used
`v.oai.rgbcfg` and `v.oai.thstatus` together; physical testing confirmed that
the key LEDs and bottom ambient underglow match. Firmware acknowledgement alone
is not the physical evidence; the observed behavior is recorded separately.

A crash, sleeping host or lost device transport may prevent the final off
write and leave the firmware's previous light visible. Qualify any firmware
timeout/reset mechanism before relying on it; otherwise disclose this limit.
The LEDs are status feedback, not an independent fail-safe signal.

## Completion and acknowledgement

A clean completion follows real work and an authoritative quiescent outcome.
An initial idle connection, a completed tool call, a timeout waiting for a
response or an abort is not success/green.

When work completes while the selected chat is already visible, remain green
until a later verified user interaction. Do not clear it immediately because
the window was already frontmost.

Acknowledgement may be established by a user-initiated native session
selection/view, verified scoped interaction, or a successful user action
against that session. A state poll or background event does not acknowledge
anything. New work takes precedence and begins mode-colored blinking.

The CLI adapter must identify which acknowledgement signals it actually
supports. If ordinary typing/scrolling visibility cannot be observed safely,
report the limitation and retain green until a verified acknowledgement.
Do not implement unrestricted keyboard logging to approximate this behavior.

## Busy and pending state

Prefer `session.idle` over `assistant.turn_end` for whole-session quiescence
on qualified builds. Track root versus subagent events and outstanding
permission/input request IDs. Completion of one request must not clear
attention while another remains pending.

Some live events are ephemeral. Rehydrate supported snapshots on attach and
reconnect; until state is established, show unknown rather than guessed green.
Cancelling only the foreground task can leave the session working because
background work remains. That is expected, not a failed color update.

Read [phase 004](phase-004-session-lifecycle.md) for action outcomes and
[phase 009](phase-009-delivery-and-acceptance.md) for physical verification.
