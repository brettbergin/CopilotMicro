# Phase 005: architecture and integration contracts

Status: target architecture supporting the agreed product. The native
menu bar/manager scaffold, packaging, version-1 schema, action/control
catalogs, shared fixtures, deterministic Core state model and isolated
configuration/diagnostics module exist. The authenticated local socket,
source-only Node client, shared negative IPC fixtures, disposable CLI
capability probe, uninstalled production observer source and native session
reconciler now exist. The app does not start the socket and no production
extension is installed. I-07 implements only the qualified read-only session
subset and rejects stateful actions. The device boundary now includes bounded
IOKit HID transport, guarded original backup/restore, a reduced 15-change
active-layer map, normalized `v.oai.hid` keys/dial and native `kb.radial`
joystick input, plus physically qualified steady all-key color output through
`v.oai.thstatus`. The app-owned USB device service now connects at normal
launch, validates the managed map, projects normalized physical input into the
GUI and applies matching key/ambient runtime lighting through
`v.oai.thstatus` and `v.oai.rgbcfg`. Terminal targeting and physical input
routing to Copilot CLI remain disabled.

## Component boundaries

| Component | Responsibility | Must not own |
|---|---|---|
| Native application | SwiftUI/AppKit menu bar, manager, onboarding and local preferences | Agent execution or a second chat frontend |
| Device service | IOKit discovery, raw HID, key normalization, lighting and reversible configuration | CLI credentials or permission policy |
| Session coordinator | One controlled CLI instance, selected-session binding, state projection and action preconditions | A shadow session/archive database |
| Terminal adapters | Discovery and verified targeting for Ghostty, iTerm2 and Terminal.app | Generic screen-coordinate macros |
| CLI-hosted extension | Join the live session, expose qualified state and execute a narrow action set | Arbitrary local RPC forwarding or default auto-approval |
| Local bridge transport | Authenticated user-local IPC, bounded messages, generations and outcomes | Public network listening |
| Configuration store | Versioned settings, backups, migrations and import/export | Tokens or copied conversation history |
| Update service | Qualified internal release discovery, verification, staging and approved replacement | CLI updates, session restart or silent permission changes |

Use an ordinary native menu bar app, not a kernel/system extension. Swift
Package Manager builds the local native executable and independently testable
Swift modules for state, configuration and protocols. A deterministic packager
owns `.app` metadata, resources and ad-hoc signing. Full Xcode is optional for
separately qualified Xcode-specific UI automation, not a local build gate. The small
JavaScript extension uses the SDK provided by its CLI host. A separate
always-running privileged daemon or cloud backend is not required.

## Why the CLI-hosted extension

Public SDK documentation describes extensions as CLI-forked Node processes.
`joinSession()` joins the current foreground session using a parent-process
connection. Extensions reload when the foreground session is replaced and
stop when the CLI exits.

This is not the same as launching a new SDK client, cold-resuming persisted
history, or connecting a fresh `copilot -p` process. Preserve the real TUI and
do not depend on undocumented attachment to an arbitrary process.

Treat each extension lifetime as a new registration generation. User-level
installation does not mean one extension instance lives forever. The native
app can receive multiple instance registrations but activates only the
explicitly controlled one.

### Qualified CLI behavior

Disposable interactive qualification on 2026-09-12 used Copilot CLI
`1.0.84-5`, build `0de509ce`, host-provided SDK `1.0.13-preview.4` and child
Node `v24.20.0` on Darwin ARM64. The sanitized machine-readable result is
[`Compatibility/copilot-cli-1.0.84-5.json`](../Compatibility/copilot-cli-1.0.84-5.json).

`joinSession()` succeeded. Replacing the foreground session with `/clear`
started a second extension lifetime, joined a second session alias under the
same host alias and terminated both lifetimes cleanly. Arbitrary selection
among existing sessions was not exercised, so foreground binding remains
partial rather than fully qualified.

The tested extension could read bounded mode, model, task, queue, pending
permission, command and extension snapshots. It observed turn/idle,
mode-change, background-task and tool-execution boundaries. Interactive and
plan mode round-tripped and was restored. The current reasoning effort could
be written back unchanged. No different model was selected and next-turn
model/effort semantics were not exercised.

No tested extension RPC provided native session list/switch/new/archive,
actual TUI composer focus/submit or native voice lifecycle. These operations
remain unavailable; `session.send()` is not an acceptable composer substitute.

The source-only probe registers no tools, hooks or permission decision handler.
Hook registration was tested separately and triggered an elevated-permission
prompt, so passive production observation must not depend on hooks. Calling
`permissions.setRequired({required: true})` returned success in a supplemental
disposable run, but a visible TUI permission prompt still did not emit
`permission.requested` to the extension. Pending counts therefore do not
establish exact visible-request authority and F-15 remains disabled.

Interactive qualification is preferred. Prompt mode excludes project
extensions unless `GITHUB_COPILOT_PROMPT_MODE_EXTENSIONS=true` and requires
`--allow-all-tools`; those conditions are not the production architecture.
The interactive qualifier lets the CLI create its own local session because
passing a fresh `--session-id` triggered a slow remote lookup and 404 fallback.

## Evidence ledger

Initial research was performed on 2026-09-11 against CLI `1.0.84-4`. Public
SDK `v1.0.13` independently corroborated the extension contract. Live
qualification then used the exact `1.0.84-5` tuple above. This is capability
evidence for one build, not an arbitrary-version support promise. Additional
SDK source was inspected at `0cb0050ef4a6206808c7229ee11715f01bc256b0`,
pinned where cited below.

| Surface | Evidence | Required qualification |
|---|---|---|
| Foreground extension join | [Released SDK extension guide](https://github.com/github/copilot-sdk/blob/v1.0.13/nodejs/docs/extensions.md#L19-L23) | Attach, replace, reload, disconnect and preserve the TUI |
| Passive permission behavior | [Released extension implementation](https://github.com/github/copilot-sdk/blob/v1.0.13/nodejs/src/extension.ts#L98-L144) | Observe without stealing or auto-answering the CLI's prompts |
| Event subscriptions/direct handlers | [CLI extension tutorial](https://docs.github.com/en/copilot/tutorials/create-an-extension) | Event coverage and deterministic action dispatch on the chosen build |
| Send, abort and model controls | [SDK session methods](https://github.com/github/copilot-sdk/blob/0cb0050ef4a6206808c7229ee11715f01bc256b0/nodejs/src/session.ts#L2050-L2160) | Exact cancellation scope, model timing and error outcomes |
| Whole-session idle | [SDK event schema](https://github.com/github/copilot-sdk/blob/0cb0050ef4a6206808c7229ee11715f01bc256b0/nodejs/src/generated/session-events.ts#L1578-L1617) | Background-aware state and reconnect snapshots |
| Multiple observers/permission handling | [SDK multi-client tests](https://github.com/github/copilot-sdk/blob/v1.0.13/nodejs/test/e2e/multi-client.e2e.test.ts#L134-L195) | Actual extension authority and races with the terminal |
| Commands and UI context | [CLI command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference) | Native list/archive/new/composer/voice contracts, not guessed names |
| Device integration | [micro-manager hardware guide](https://github.com/schacon/micro-manager/blob/32caf5a429cd0618dbb8c8354e34223d601ee235/docs/hacking.md) | Exact Pro identity, firmware, layer and transport |
| Vendor layer support | [Work Louder release notes](https://github.com/worklouder/cm-v2-fw-releases/releases/tag/v0.6.0-rc.10) | Visible effects and reversible current-firmware behavior |

Many low-level `session.rpc.*` groups are experimental. Type declarations do
not establish that every extension can invoke them. Do not claim a native
archive, visible-prompt or composer API until it is demonstrated.

No unlicensed reference implementation/assets may be copied. These links are
evidence and interoperability context, not a reuse license.

## Local IPC contract

This is a protocol we will implement, not a built-in public Copilot endpoint.
Prefer a Unix-domain socket under a private per-user runtime directory.
Restrict directory/socket permissions, verify peer identity where available,
and authenticate registrations against the installed bridge's bootstrap
material. Do not expose an unauthenticated localhost HTTP control server.

The channel must provide:

- A protocol version and application/bridge versions.
- Explicit CLI instance/session identity and connection generation.
- Feature capabilities with reasons for non-supported states.
- State snapshots plus ordered incremental updates.
- Action requests and explicit accepted/completed/rejected/failed outcomes.
- Liveness/heartbeat information and bounded reconnect behavior.
- Correlation and replay protection, without forwarding arbitrary SDK RPC.

Implementation status: `CopilotMicroBridge` and `Bridge/src/` implement this
contract through authenticated registration, bounded snapshots, event-driven
reconciliation, heartbeats, replacement/liveness invalidation and explicit
action rejection. The transport retains its 64 KiB big-endian length prefix,
mode `0700` runtime directories, mode `0600` socket/bootstrap files, macOS peer
UID checks, private 256-bit bootstrap token, strict peer roles, connection
generations, monotonic sequences and 64-request in-flight bound. Swift and Node
consume the same `Contracts/fixtures/ipc-v1/manifest.json` negative cases.

The production observer registers `tools: []` and no hooks or permission
handler. It never launches a CLI, requests tokens, forwards raw SDK calls or
executes arbitrary commands. Event payloads are reduced to bounded reason
categories; full state is reconciled through the qualified read-only RPC set.
Pending permission snapshots carry counts only, not request IDs. Capability
snapshots advertise no supported stateful action, and the native reconciler
rejects any production snapshot that does.

This remains isolated source/mock evidence: the native app does not start the
server, production source is not installed under `.github/extensions/`, and no
live CLI qualification was rerun for I-07. The disposable probe's existing
`1.0.84-5` evidence is the compatibility ceiling.

### Registration

A registration includes CLI instance identity, session ID, a fresh connection
generation, observed CLI/SDK versions, terminal-target evidence and capability
snapshot. The native app authenticates it before showing it as controllable.

`instanceId` identifies one live CLI host lifetime; `generation` identifies
one bridge connection. Extension reload/session replacement changes the latter
without inventing a different CLI instance. Correlate with verified host/
terminal evidence, not just a reused PID. If that correlation cannot be
established, suspend control and require explicit reselection.

Do not persist a live PID/registration as authority across restarts. A
same-user malicious process is not fully contained by filesystem permissions;
document that limit and avoid claiming IPC authentication protects a
compromised macOS account.

### State snapshot

The logical state includes known/unknown mode, foreground/background activity,
pending attention IDs/kinds, terminal outcome, selected-session identity and
available UI-context evidence. A state revision increases when action-relevant
context changes.

`visiblePermissionRequestId`, if supported, is an adapter assertion derived
from qualified host/UI evidence. It is not an existing SDK field assumed from
`permission.requested`. Omit/mark it unknown when unavailable; disable approval.

A new connection starts unknown. Establish initial snapshots and subscribe
without a missed-event window. Reconcile gaps/out-of-order events rather than
replaying an obsolete state. No snapshot should contain the full transcript.

I-07 subscribes immediately after `joinSession()`, before opening the local IPC
connection. Events seen during attachment are folded into the first
reconciliation. Later qualified events reserve a newer context revision and
invalidate native derived state until the matching snapshot arrives. Native
liveness expiry, replacement and generation mismatch clear capabilities,
model state and action context.

### Action request

An example of our proposed envelope:

```json
{
  "protocolVersion": 1,
  "messageType": "action",
  "requestId": "unique-action-id",
  "instanceId": "registered-cli-instance",
  "sessionId": "actual-cli-session-id",
  "generation": "registration-generation",
  "contextRevision": 42,
  "action": {
    "type": "session.cancelForeground"
  }
}
```

The runtime action ID is distinct from a permission request ID. Permission
actions additionally identify the exact pending permission and use only
approve-once or reject.

Validate schema, size, enum values, identity, generation, revision and relevant
live preconditions. Reject unknown action types and arbitrary method/command
strings. Recheck sensitive conditions immediately before execution.

An accepted request is not completed work. Return an explicit outcome and
read back the relevant host state. Keep in-flight operations correlated.
On ambiguous timeouts, reconcile; do not blindly resend Submit/New/Archive/
Approve or other non-idempotent actions.

### Disconnect and replacement

Disconnect invalidates the binding, pending UI context and all queued physical
actions. Clear owned live-state lighting when possible. Reconnection creates a
new generation, synchronizes state and only then permits new input.

Do not resume a saved session to manufacture a live connection. Do not replay
approval, submit or archive requests from a previous generation.

## Terminal/UI integration contract

Each terminal adapter must demonstrate exact target discovery and focus,
not merely launching a bundle ID. Observe the actual CLI process/window/tab/
pane relationship through qualified interfaces.

A terminal-specific implementation may use carefully checked APIs or
Accessibility/Automation for appropriate focus/navigation/input behavior.
Register the required permissions and disabled-feature consequences.

Controls that depend on UI state must distinguish the composer, native
session list, model/effort picker, tool permission, question and plan review.
No arbitrary global Enter, Escape or `y` event is an acceptable generic API.

Report terminal-specific gaps separately. Success in Ghostty does not qualify
iTerm2 or Terminal.app.

I-08 now provides `CopilotMicroTerminal` as the shared native boundary. It
validates supported application metadata and in-bundle executables, discovers
approved Copilot CLI paths without evaluating shell startup files, preserves
explicit exact-path preferences, and defines typed process/window/tab/pane,
UI-context and argument-vector launch contracts. The contract does not claim
that an adapter has established exact focus: `.applicationOnly`, wrong-surface,
unavailable and unknown evidence remain distinct from `.exact`.

## Deterministic state and observability

Implement LED projection and action preconditions as testable deterministic
logic, separate from HID and UI adapters. Typed events, timers and explicit
snapshots drive state; the model does not decide how to route a hardware event.

Use structured, bounded local logging at connection, configuration, action
and update boundaries. Correlate by local action/session aliases and outcomes,
not secret payloads. Extension stdout is reserved for its host protocol; do
not corrupt it with debug output.

No extra agent invocation is needed to route a button, select a mode or ask
for cancellation. Actions that actually start/resume agent work retain the
CLI's ordinary usage and policy behavior.
