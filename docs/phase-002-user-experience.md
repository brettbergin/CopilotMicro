# Phase 002: user experience

Scope: F-01, F-04 through F-21, F-24 through F-26.
Detailed action semantics live in [phase 004](phase-004-session-lifecycle.md).

## Interaction principles

The CLI remains the working surface. Copilot Micro explains and configures
the hardware, rather than duplicating the conversation UI.

Show the selected terminal, CLI instance and session whenever an action could
affect work. Use plain action names and specific recovery messages. Never
represent a local selection as a successful native CLI selection until the
host confirms it.

The application stays in the menu bar when its manager window closes. Use
native SwiftUI/AppKit conventions, resizable content, accessible labels,
keyboard navigation and readable light/dark appearances. The device has no
documented text display; action labels live in the manager or qualified picker
overlays.

## First-run onboarding

| Step | UI and behavior | Completion condition |
|---|---|---|
| 1. Welcome | Explain CLI-only scope, managed-key behavior and internal-build limitations | User elects to set up |
| 2. Find terminals | Show detected Ghostty, iTerm2 and Terminal.app with resolved paths | User explicitly chooses a validated preferred terminal |
| 3. Find CLI | Discover executable/version, show qualification status and missing dependencies | Version is compatible or feature gaps are clearly accepted |
| 4. Connect device | Show product, transport and firmware; handle multiple candidates explicitly | User chooses a verified Creator Micro 2 Pro |
| 5. Permissions | Explain Input Monitoring and any feature-specific Accessibility/Automation need | Required grants confirmed, or affected features shown blocked |
| 6. Install bridge | Show the user-scoped extension path, ownership and purpose | User consents; extension joins the intended CLI and handshakes |
| 7. Back up and preview | Read original map, save durable backup, show managed controls and changed bindings | Backup validates and user approves the planned write |
| 8. Verify | Check selected-session identity, an innocuous action and a visible lighting walk | Results distinguish real success from ACK-only behavior |
| 9. Finish | Summarize supported controls, gaps, restore action and local storage | User understands the active configuration |

Allow onboarding to resume after a denied permission or disconnected device.
Do not treat cancellation as failure, discard a good original backup, or
repeat already-confirmed destructive steps.

### Terminal discovery

Inspect common locations, including `/Applications`, `~/Applications`,
`/System/Applications` and `/System/Applications/Utilities`, using app metadata
to identify valid bundles. Deduplicate results and offer manual selection of
another installation of a supported terminal.

Display only what was actually found. Do not silently prefer the first item,
even if only one is found; ask the user to confirm. Persist the chosen bundle
identity and resolved location in durable local configuration. Revalidate
before use. If it disappears, explain and reopen selection rather than
launching a different terminal silently.

CLI discovery must account for GUI applications' restricted PATH. Inspect
approved/common installation paths and user-selected executable locations;
do not run arbitrary shell startup files just to guess a binary.

## Menu bar panel

Clicking the status item opens a compact panel containing:

- Device identity, USB/Bluetooth state and available battery information.
- Preferred terminal, controlled CLI instance and selected session.
- Textual mode/activity/attention state corresponding to the lights.
- Prominent issues and feature gaps, with appropriate recovery actions.
- Pause/resume controls, Open Copilot when no instance is connected, and
  Open Manager.
- An optional launch-at-login control, off until the user opts in.
- Update availability, Settings/Diagnostics access and Quit.

Do not require the menu bar panel to remain open for the bridge to run.
Battery values must indicate unavailable/stale data rather than inventing a
percentage.

**Paused** means hardware-triggered CLI actions and state lighting are stopped;
it does not restore the original mapping. Say this explicitly. Keep enough
lifecycle observation to reconnect safely, but do not queue paused presses.

## Full manager

| Area | Contents |
|---|---|
| Overview | Device/CLI/terminal health, selected session, supported features and onboarding recovery |
| Controls | Physical pad drawing, selected control, assigned action, contextual behavior and reset-to-default |
| Lighting | Brightness, explanatory state legend and a safe preview distinct from real session state |
| Connection and Settings | Preferred terminal, controlled instance, launch at login, optional notifications and dependencies |
| Configuration | JSON import/export with preview; original keymap backup information and explicit restore |
| Updates | Current/candidate version, compatibility, integrity status, release notes and approved installation |
| Diagnostics | Bounded redacted event history, actionable errors and explicit export |

Use one active personal configuration. Do not add profile tabs or automatic
per-project mappings.

Clicking a control in the visual editor edits its assignment; it does not
execute that action. A separate clearly labeled test operation, if offered,
must apply the same targeting and safety rules as real input.

Unassignable or unsupported actions remain discoverable with an explanation.
Changing a local action assignment does not imply rewriting device flash.

## Focus-before-action contract

For a hardware action targeting the CLI:

1. Resolve the live controlled instance, selected session and exact terminal
   window/tab/pane.
2. If another application or the wrong terminal surface is frontmost, attempt
   to focus the intended surface.
3. Consume that press without executing its original action, whether focusing
   succeeds or fails. Give feedback.
4. A subsequent physical press is evaluated from scratch and may execute only
   if its own preconditions now hold.

Do not save a delayed action, arm a timer to execute it, or interpret the next
press as confirmation of the previous button's action. A different next
button means a different requested action.

Being in the preferred terminal application is insufficient if the wrong
window/tab/pane is active. If exact targeting cannot be established, record a
feature/terminal gap. No generic foreground-keyboard fallback.

Local configuration controls and an explicitly opened native project chooser
have their own UI scope. They do not become a loophole for background CLI
actions or permission approval.

## Key journeys

### Browse sessions

Sessions opens the CLI's native session-list tab/view. Dial movement opens
that view if necessary, then changes the highlighted candidate without
selecting a session on every detent. Joystick up/down navigates. Confirm
selects the candidate; Back exits without changing the selected session.

Previous/Next are explicit direct-switch actions, not another spelling of
highlight-only browsing. Boundary behavior follows the verified native CLI
list, including wrapping only if the native action supports it.

### Create a session

New opens a native project/directory chooser showing recent local directories
and Browse. The user selects an existing directory and confirms creation.
Cancel leaves the current CLI session unchanged. Confirm creates/selects the
new session through a qualified CLI path; preserve any CLI trust/login prompt.

Do not change the old session's working directory as a shortcut to creating
the new one. A separate process is not a silent substitute for creation in
the controlled CLI.

### Archive

Show enough context to identify the selected session. When idle and safe,
invoke native archive. When busy, ask whether to cancel its foreground task
first; after confirmed cancellation, check again. If background/queued work
remains, explain why archive cannot proceed. Do not cancel that other work.

Show the CLI-confirmed post-archive selection. Finding/restoring the archive
is performed in Copilot CLI, not a new archive manager here.

### Human attention

All key LEDs pulse amber while verified human input is pending. Existing CLI
permission dialogs remain authoritative. Joystick approval/rejection acts
only on the exact already-visible permission prompt under
[phase 007](phase-007-security-privacy-and-safety.md).

An arbitrary question, plan review or model picker is not a tool permission
prompt and must not inherit the approve-once behavior.

## Error and accessibility UX

Default feedback is LEDs plus menu bar/manager indicators. OS notifications
are opt-in and must not disclose prompts, tool arguments or sensitive paths.
Do not toast every successful key press.

Provide text labels for Working, Needs permission, Needs input, Completed,
Error, Disconnected and Unsupported. A red light alone is not sufficient
diagnosis. Respect reduced-motion preferences with a clear, documented
non-animated alternative; do not disable the meaning of attention states.

Onboarding and core manager flows must be usable without the physical device
through an explicitly labeled emulator. Emulator state never masquerades as
connected hardware or a verified production CLI session.
