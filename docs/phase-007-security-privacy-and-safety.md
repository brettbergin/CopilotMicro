# Phase 007: security, privacy and safety

Status: design constraints and acceptance requirements, not a security audit
or claim that an implementation has been reviewed.

Implementation status: local configuration and diagnostics now use user-only
paths, bounded schemas, atomic replacement, recovery copies, deterministic
diagnostic rotation and explicit redacted export. The isolated local IPC layer
now enforces private filesystem modes, same-user peer checks, bootstrap
authentication, strict roles, bounded frames, generations and ordered
sequences. It is not started by the app and has not joined a CLI session.
A separate passive probe has joined owned disposable CLI sessions without
using the production IPC path. Live production extension authority and updater boundaries remain design
requirements. The read-only
hardware qualifier now opens one exact candidate non-exclusively and allowlists
only version, status and keymap reads. Its evidence excludes the serial number
and full configuration. The separate device setup path stores a private
integrity-checked original backup and requires a closed-configurator
declaration, known-configurator rejection, a
device/source/target/backup/change-bound transaction digest, fresh pre-change
snapshot, competing-response detection, exact consent and complete read-back
before reporting a write as successful. No real mapping write has been
performed yet.

## Trust boundaries

| Boundary | Risk | Required control |
|---|---|---|
| Device to native app | Malformed/duplicate input and wrong-device selection | Identity/capability validation, bounded parsing and input normalization |
| Native app to CLI bridge | Wrong-session actions, spoofing and replay | User-local authenticated IPC, explicit identities/generations and allowlisted messages |
| Session events to LEDs/UI | Stale or misleading status | Reconciliation, request correlation and explicit unknown state |
| Button to permission decision | Unseen/broad/stale authorization | Exact already-visible request, approve once, policy preservation and no replay |
| Imported JSON to preferences | Command injection or destructive replacement | Strict versioned schema, no executable content, preview and confirmation |
| Backup to device | Wrong-device or destructive restoration | Device association, integrity checks, compatible schema and read-back |
| Release source to installed app | Malicious/tampered/downgraded executable | Authenticated source, independently verified update integrity and explicit installation approval |

## Non-negotiable action invariants

S-01: no stateful CLI action without a valid live binding to the intended
instance, session and terminal surface.

S-02: the first hardware press from a different foreground app/surface focuses
only. Never replay its action after focus completes.

S-03: permission approval is once, for one unresolved request already visibly
active in the selected CLI before the press. No generic keystroke approval.

S-04: changing mode, installing the bridge, updating or importing configuration
must not enable allow-all tools/paths/URLs or override managed CLI policy.

S-05: cancellation does not widen to background work, queued prompts or process
termination. Archive must stop rather than widen cancellation scope.

S-06: keymap writes require a verified backup, explicit consent and read-back.

S-07: missing information is unknown/blocked, not inferred success or idle.

S-08: disconnect, restart and generation change invalidate pending actions and
approval context. No blind retry of non-idempotent operations.

A skipped feature may not violate these invariants as a convenience fallback.

## Permission handling

Start with a passive extension observer. The default bridge must not install
an approve-all handler or answer requests merely because it received an event.

On Copilot CLI `1.0.84-5`, registering hooks triggered an explicit elevated
permission prompt, so the passive probe registers no hooks. Ordinary event
subscriptions and bounded read-only RPC snapshots loaded without that
elevation. Hook permission is not a prerequisite the product may request just
to monitor state.

The tested permission event bridge is not sufficient for F-15.
`permissions.setRequired({required: true})` returned success, but the extension
still did not receive `permission.requested` while the selected TUI visibly
displayed a disposable shell permission prompt. Pending-request counts are
readable but do not prove which request is visible. Treat this capability as
unavailable, not partially safe, until exact visibility and decision authority
are independently demonstrated.

Enabling hardware approval requires verifying both the extension's authority
and an exact visible-request binding. Required host consent must be explicit
during setup; policy denial leaves F-15 blocked/unavailable.

A decision identifies connection generation, session ID and permission
request ID. Validate the displayed context and outstanding request immediately
before applying it. Handle the terminal, remote client or another observer
answering first. A false/not-applied result is not a successful approval.

Held buttons, joystick repeat, two wide-key contacts or reconnection cannot
produce additional decisions. Never promote approve-once to session-wide or
permanent approval.

Plan review, elicitation and general questions are not interchangeable with
tool permissions. Amber attention lighting may cover all of them, but their
control behavior remains distinct.

## macOS permissions

Request only permissions needed by enabled features and explain why:

- Input Monitoring for the demonstrated HID integration path.
- Accessibility for qualified UI inspection/event delivery where used.
- Automation for terminal-specific Apple Events/System Events paths where used.
- Notifications only after user opt-in.
- Voice permissions through the CLI's own voice setup; do not silently claim
  microphone ownership in the companion.

A denied/revoked grant disables the affected operation with recovery guidance.
Do not repeatedly nag, modify TCC databases, strip quarantine or suppress
system security checks.

Unsigned/ad-hoc internal builds may require renewed grants after replacement.
This is a documented limitation, not justification for bypassing protection.

## Local IPC and extension trust

No public network listener. Use owner-restricted local endpoints, peer checks,
authenticated registration, message size/rate bounds and explicit schemas.
Never expose raw SDK method names or arbitrary shell execution as the
companion protocol.

Do not request sensitive environment variables such as GitHub tokens for
routine device/session control. The CLI retains its authentication. Store
bridge bootstrap material separately from portable configuration and exclude
it from logs/exports.

Show the extension's installed path and ownership. Project/user/plugin
extension name collisions or unexpected shadowing are errors to diagnose,
not reasons to silently overwrite another extension.

These controls reduce accidental/cross-process misuse. They do not claim
isolation from malware already running as the same macOS user or a compromised
trusted CLI/extension host.

## Data policy

No usage telemetry, analytics or automatic error uploads. Configuration and
diagnostics remain local. Copilot CLI retains its independent existing network
behavior; the companion does not add conversation forwarding.

Do not collect/store by default:

- Prompts, chat drafts, responses or full session transcripts.
- Tool arguments/results, permission command text or source-code contents.
- Tokens, auth headers, environment dumps or voice recordings.
- Clipboard contents or system-wide keystrokes.

Disposable probe evidence follows the same boundary. It is limited to 256
JSONL records, 128 KiB total and 8 KiB per record, uses user-only mode `0600`,
aliases host/session/request identifiers and records only allowlisted event
categories and bounded RPC summaries. PTY transcripts used during manual
qualification are temporary test evidence and must never be committed.

The manager may show necessary live identity/context without persisting it.
Use scoped host interaction evidence for completion acknowledgement; do not
build a keylogger to detect that a chat has been read.

## Diagnostics and export

Use structured local events with timestamps, correlation aliases, component,
operation, capability/version, outcome and bounded error categories.
Redact paths, raw device serials, account identifiers and sensitive free text
from export. A sanitized error message should still explain the failure.

Initial engineering retention limit: at most three 5 MiB diagnostic segments.
Rotate deterministically and allow clearing them. Protect the original keymap
backup separately; diagnostic rotation must not delete recovery material.

Export is an explicit user action. Preview what is included and its scope,
then create a redacted file for the user to share. Do not attach it to GitHub,
upload it or disclose secrets automatically. Test redaction with seeded secret,
path, prompt and command examples.

## Update authentication

The updater may contact the configured internal/private GitHub release source.
Use the user's existing `gh` authentication through narrowly scoped commands
where required. Do not extract or copy Copilot credentials, persist another
token in JSON, or forward auth headers to untrusted redirect destinations.

A GitHub URL and downloaded checksum alone are not sufficient authenticity
for executable replacement. Require a trusted verification mechanism, such
as a signed manifest/payload with a pinned verification key, even while the
application itself is ad-hoc signed.

If authenticated retrieval, signature verification or compatibility checks
cannot be implemented, F-24 is a disclosed gap and automatic installation is
disabled. Manual distribution is a clearly labeled fallback, not a successful
built-in update.

## Restore and removal

Removing Copilot Micro must not remove Copilot CLI, unrelated extensions,
terminal preferences or other Work Louder software.

Offer device restore before removing the managed bridge. If the device is
unavailable, explain that restoration was not performed and preserve the
backup. Remove only app-owned files whose identity/ownership is established;
retain modified user files unless the user explicitly elects removal.

Do not permanently delete CLI sessions as part of archive, uninstall or
cleanup.
