# Phase 001: requirements and scope

Parent: [product charter](phase-000-product-charter.md).
Status: intended first-release feature contract, not a support claim.

## Feature catalog

Every feature below is intended for the first release. A failed integration
gate may make an individual feature unavailable under the explicit gap policy.

| ID | Feature | Required behavior |
|---|---|---|
| F-01 | Bind to the selected CLI session | Follow the selected session in one explicitly chosen live CLI instance, including changes made without the pad |
| F-02 | Mode lighting | All key LEDs use white/default, blue/plan or purple/autopilot |
| F-03 | Activity and attention lighting | Apply busy, completion, acknowledgement, permission/input, error and disconnected states |
| F-04 | Native session list | Open the session-list tab/view inside Copilot CLI, not a substitute list in our manager |
| F-05 | Browse and switch sessions | Previous/Next switch deliberately; dial browsing highlights until confirmed |
| F-06 | New session | Choose an existing local project/directory, then create and select a new CLI session |
| F-07 | Native archive | Archive the selected session through the CLI's own operation, preserving history and applying the busy guard |
| F-08 | Mode control | Cycle default, plan and autopilot through validated CLI semantics |
| F-09 | Model selection | Offer models available to this session; show/read back the applied selection |
| F-10 | Reasoning effort | Offer only effort settings supported by the selected model/runtime |
| F-11 | Voice | Control Copilot CLI's built-in voice/dictation, not a substitute third-party provider |
| F-12 | Cancel | Cancel only the selected session's current foreground task |
| F-13 | Submit | Submit the existing CLI chat input, preserving the user's draft until that deliberate action |
| F-14 | Focus input | Focus the actual selected CLI chat composer without submitting or clearing it |
| F-15 | Approve/reject | Decide once on the exact already-visible pending permission request |
| F-16 | Visual remapping | Reassign supported physical controls to supported actions in the manager |
| F-17 | Brightness | Adjust key-light brightness while retaining state semantics |
| F-18 | Configuration exchange | Export/import one personal configuration as validated JSON |
| F-19 | Guided onboarding | Detect dependencies, request consent/permissions, back up, connect and verify |
| F-20 | Terminal discovery | Find Ghostty, iTerm2 and Terminal.app, show discoveries and persist the user's choice |
| F-21 | Native shell | Menu bar panel, full manager, explicit Open Copilot, pause and connection status |
| F-22 | Device restoration | Restore the saved original keymap through an explicit verified operation |
| F-23 | Both device transports | Support Creator Micro 2 Pro over USB and Bluetooth |
| F-24 | Internal updater | Check, stage and install a verified update only after explicit user approval |
| F-25 | Private diagnostics | Local bounded diagnostics, actionable errors and user-requested redacted export; no telemetry |
| F-26 | Optional notifications | OS notifications are off by default and can be enabled by the user |

## Scope clarifications

F-06 uses recent local directories and a standard folder chooser. Repository
cloning, branch/worktree creation and remote repository browsing are not part
of this feature. The CLI retains its trust and login flows.

F-07 is archive, not delete, close, forget or remove-from-our-cache. Browsing
or restoring archived sessions is left to Copilot CLI.

F-08 does not authorize changing permission mode to allow-all. If the CLI
requires confirmation to enter autopilot, preserve that confirmation.

F-09/F-10 affect subsequent work according to the runtime's contract. They
must not pretend to modify an inference already in flight.

F-11 must expose missing CLI voice support, required runtime downloads or
permissions as dependencies. Do not silently substitute macOS Dictation.

F-13 is not `session.send()` with an invented/copied prompt. It targets the
current composer. Lack of a safe composer integration is a feature gap.

F-16 supports key taps, encoder directions/press and qualified joystick
directions. Touch sensing or additional gestures are not promised merely
because the hardware has them. The bottom wide key is one physical control.

F-18 does not create a named-profile system. Import replaces the active
personal configuration only after preview and confirmation.

## Capability and health are different

Use these capability states per feature and relevant configuration:

| State | Meaning | UI |
|---|---|---|
| `supported` | Qualified implementation exists for the current configuration | Action is available when its contextual preconditions hold |
| `unavailable` | Missing implementation/API or known incompatibility | Disabled, with a reason and gap reference |
| `blocked` | Implementation exists but a prerequisite such as permission/auth is absent | Disabled, with a recovery action |
| `unknown` | Compatibility has not been established | No speculative action; offer the appropriate check |

Connection states such as disconnected, connecting and connected are separate.
A supported action can be temporarily blocked by a lost session. A live
connection does not mean every feature is supported.

Qualification is a tuple: app build, CLI build/bundled SDK, macOS, terminal,
device identity/firmware and transport. Report only the portions actually
qualified. An unavailable Bluetooth path cannot be presented as successful
Bluetooth support because USB works.

## Gap policy

When a feature cannot be implemented safely or reliably:

1. Preserve its intended requirement and assign an implementation gap.
2. Disable it rather than invoke an approximate or dangerous substitute.
3. Explain the user-visible limitation in onboarding and the action editor.
4. Include it in the final delivery report, with affected environments and
   evidence.

The stakeholder permits shipping a useful subset with disclosed gaps. That is
not permission to weaken invariants on features that do ship. All shipped
features must satisfy their applicable acceptance tests.

The following are never acceptable substitutes:

- An unregistered/new session instead of the intended live session.
- A generic Enter/`y` keystroke instead of a request-specific approval.
- Deleting session files instead of native archive.
- Killing the CLI process instead of cancelling the foreground task.
- Showing idle/green because state is unknown.
- Changing device firmware or overwriting keymaps without consent.
- Approving all tools to make the bridge work.

## Cross-cutting quality requirements

Q-01: zero wrong-target actions in qualification scenarios, including multiple
terminal windows, focus changes, stale registrations and session replacement.

Q-02: every rejected or failed action has a user-visible reason. Physical
input that is deliberately consumed for focus must be distinguishable from
an executed action.

Q-03: no device configuration write before backup and consent; no repeated
flash writes for ordinary light updates, local action remaps or reconnects
when device bindings are unchanged.

Q-04: keyboard-accessible, labeled native controls; state is never communicated
only by color. Honor relevant macOS accessibility preferences.

Q-05: bounded local data, no telemetry, no secrets in configuration/export,
and no default collection of prompts or tool content.

Q-06: compatibility failures, permission revocation and disconnects fail
explicitly. Reconnect does not replay button presses or approvals.

Q-07: measure responsiveness. Initial engineering targets are 250 ms for USB
and 500 ms for Bluetooth from native receipt of an authoritative state change
to completion of its HID write under normal connected conditions. Verify
physical color separately; a successful write/acknowledgement is not proof
that firmware applied it. These targets are not measurements already made.

Q-08: an update cannot widen permissions, silently replace configuration, lose
the original keymap backup or restart a user's CLI session.

Acceptance and reporting are owned by
[phase 009](phase-009-delivery-and-acceptance.md).
