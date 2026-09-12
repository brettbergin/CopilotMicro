# Phase 004: session lifecycle and action semantics

Scope: F-01, F-04 through F-15.
Safety owner: [phase 007](phase-007-security-privacy-and-safety.md).

## Identity and selection

Maintain a live binding containing controlled CLI instance identity, session
ID, connection generation, terminal identity and qualified capabilities.
Human-readable session names and working directories are display metadata,
not unique authorization identities.

The hardware follows the session actually selected in the controlled CLI.
Manual CLI session changes must replace the binding and lighting state.
Never continue addressing the old session because it occupies a cached pad
slot. During replacement, disable actions until the new binding synchronizes.

If multiple terminal/CLI instances match discovery, ask the user which one to
control. Do not select the most recently modified history file or first PID.
Saved preferences are hints to revalidate, not proof that a process is live.

Scope the first release to one controlled CLI instance at a time. Other CLI
instances and their work must remain unaffected. Do not promise an inventory
of every live/saved session by parsing private session databases.

## Lifecycle

| State | Allowed operations |
|---|---|
| No CLI | Native settings, diagnostics, device restore, explicit Open Copilot |
| Discovering/attaching | Observe progress; no session mutation |
| Bound but unsynchronized | Hydrate capabilities/state; no speculative action |
| Ready | Context-qualified actions |
| Replacing/reconnecting | Invalidate stale controls/requests; no replay |
| Paused | Native recovery/configuration; no hardware-triggered CLI actions |
| Shutting down | Clear owned runtime lighting when possible; release device/IPC; preserve keymap and CLI process |

Opening Copilot is an explicit action using the validated preferred terminal
and chosen local directory. Preserve ordinary CLI login/trust prompts. Do not
add allow-all flags, change global CLI settings, install a new CLI build
silently or treat launch as proof of bridge connection.

## Action catalog semantics

### List and navigation

Open the actual Copilot CLI session-list tab/view. The adapter must demonstrate
the host action, not substitute a similar command from a different product.

Previous/Next select through native semantics. Dial/joystick browsing moves a
highlight and requires confirmation. Read back the selected session and wait
for its live binding before enabling subsequent stateful actions.

If only a subset of navigation is qualified, expose that subset explicitly.
No unsupported `session list --json` command or fabricated shortcut may become
an implementation assumption.

### Create

The user chooses an existing local directory in our native chooser. Cancel
has no effect on the current session. Confirm requests a new native CLI
session in that directory and selects it after host confirmation.

Do not mutate the existing session's directory/history to simulate creation.
Do not silently launch a separate agent runtime. If the same-instance
creation path cannot be qualified, record F-06 as a gap.

### Archive

Archive preserves history and uses the CLI's own archive operation. Never
delete, rename or directly edit session files/databases.

The action sequence is:

1. Resolve and display the exact selected session.
2. Check authoritative foreground, background, queue and pending-input state.
3. If foreground work is busy, ask whether to cancel that foreground task.
4. If confirmed, request that cancellation and observe it settling.
5. Recheck all relevant work. If background/queued work or unresolved human
   input remains, stop and explain; do not widen cancellation scope.
6. Invoke native archive only when safe and the target remains unchanged.
7. Observe archive success and the CLI's resulting selected-session state.

A stale selection, unavailable work snapshot, failed cancellation or timed-out
archive is not success. Do not retry an archive blindly after an ambiguous
timeout. Reconcile first.

Preserve native confirmations about unsent drafts during archive and other
session transitions. Do not dismiss a host confirmation to force an action.

### Cancel

Cancel affects only the current foreground task in the selected session.
It does not intentionally cancel background agents, discard queued prompts,
archive a session, kill the terminal or undo side effects.

`abort()` acknowledgement means the request was accepted, not necessarily
that the task has stopped. Observe the result and distinguish requested,
cancelled, already idle and failed/unknown outcomes. `sendAndWait()` timing out
does not cancel anything.

Queued work may subsequently start under native CLI behavior. Explain that
Cancel is not a global pause. Keep cancellation separate from device Pause.

### Mode

Cycle default, plan and autopilot according to validated CLI operations.
Confirm/read back mode before presenting the new steady or blinking hue.
Preserve any host confirmation or policy restriction. Autopilot selection
must not be implemented by enabling allow-all permissions.

### Model and reasoning effort

Use available models/capabilities from the selected session's own runtime and
authentication context. Do not hard-code the research-time model roster.

Selection applies to subsequent work. Explain pending/effective state when a
task is already running. Read back the model/effort, and handle changes made
outside the pad. Unsupported effort values remain unavailable.

Use native pickers where qualified, or a clearly session-bound non-activating
companion picker that does not steal the terminal's input focus. Picker
navigation is not authorization to send arbitrary keyboard events.

### Voice

Integrate only the CLI's built-in voice/dictation for this release. Discover
its actual availability and native start/stop behavior on the qualified build.
Preserve microphone/model/provider setup and privacy flows.

Do not silently download voice models, change providers, invoke Superwhisper
or substitute macOS Dictation. Missing support is F-11's gap. Show the actual
recording/listening state if available; do not toggle a local boolean and
claim it represents the CLI.

### Focus and submit

Focus targets the actual CLI composer without clearing, modifying or
submitting it. Submit sends that existing draft exactly once.

Do not use a new `session.send()` call as a substitute for submitting the
user's current draft. Do not read the clipboard or scrape/copy conversation
text to synthesize a replacement prompt.

Context-sensitive Enter is permitted only through a qualified input path that
establishes the intended composer and preserves its contents. If a permission
dialog, picker, question or other UI owns Enter, reject Submit or perform only
the expressly supported focus action. Do not accidentally approve a dialog.

The global first-press focus guard still applies when another application or
terminal surface is frontmost.

### Permission decisions

Joystick east/west may approve once/reject only when all conditions hold:

- The controlled CLI and selected session are the exact visible target.
- The specific tool-permission prompt was already visible before the press.
- Its unresolved request ID and displayed operation are unambiguous.
- The bridge is allowed to submit that scoped decision without bypassing policy.

Do not equate `permission.requested` with proof that the prompt is visible.
Resolve by request ID, check whether the decision applied, and observe its
completion. Another interface may answer first; a rejected stale response is
normal and must not be retried on the next prompt.

One press never approves all tools, future requests or an unseen queued
request. Plan approval, general questions and unrelated dialogs are separate
contexts, not tool-permission aliases.

## Failures and feature-specific gaps

Prefer typed session APIs. Validated terminal/UI automation is acceptable for
focus, navigation and submission where appropriate, with explicit context
checks and no global coordinate scripts.

The exact session-list, archive, composer, voice and visible-permission
contracts are qualification gates. Record unavailable controls rather than
inventing API/shortcut behavior. See the initial evidence ledger in
[phase 005](phase-005-architecture-and-contracts.md) and gap report in
[phase 009](phase-009-delivery-and-acceptance.md).
