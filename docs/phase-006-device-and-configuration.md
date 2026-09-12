# Phase 006: device and configuration

Scope: F-16 through F-20, F-22, F-23.

## Supported hardware boundary

Qualify Creator Micro 2 Pro over USB and Bluetooth. Do not infer support for
Base, Codex-branded variants, original Creator Micro, QMK/VIA or other devices
sharing a vendor ID.

Discover product identity, HID collections, firmware and transport before
writing. Select explicitly if multiple candidates exist. Use stable
device-specific identity where available; when it is absent, require explicit
selection and stronger restore confirmation rather than guessing.

Reference evidence uses vendor ID `0x303A`, Pro-family product information,
vendor usage page `0xFF00`/usage `1`, report ID `0x06`, and a shared,
non-exclusive connection. The vendor ID alone is not a sufficient match.
USB and Bluetooth may enumerate their collections differently.

Raw HID reference framing is a 64-byte report with up to 61 bytes of RPC
payload per fragment. Implement byte-oriented reassembly, including UTF-8
boundaries, before JSON decoding. Bound memory/time and reject malformed data
with an explicit diagnostic. Do not copy the reference's assumptions about
small configuration size or silently discard parse failures.

Request IDs, outstanding requests, timeout cleanup and reconnect handling
must prevent collisions and stale-response association. Qualification must
establish actual firmware limits and pacing.

## Managed bindings

The reference stock-firmware path assigns `KV_OAI_AG*` bindings on an active
layer so the host receives events and can drive individual keys. These
bindings replace ordinary keystrokes and are persisted in device flash.

Do not assume that the active profile is an array index or that the active
layer is always the first layer. Read and validate actual selection and
schema. Preserve unrelated keys/layers, unknown device fields, macros and
lighting settings.

Do not silently manage controls the product has not qualified, such as touch
or diagonal joystick actions. Persistent remapping must not depend on an
unverified physical matrix.

Stock firmware is the baseline. Firmware installation/flashing is outside
initial scope. Explain a required compatible firmware version and leave any
vendor update to an explicit separate user operation.

## Backup and write transaction

Before the first managed write for a device:

1. Read the current full configuration and relevant lighting state.
2. Validate it and save a durable, device-associated original backup.
3. Record source identity, firmware, schema, timestamp and integrity checksum.
4. Show a human-readable diff and explain loss of ordinary keystrokes.
5. Obtain explicit consent.
6. Apply the minimal compatible change once.
7. Read back and verify the expected map while checking preserved fields.
8. Verify actual input behavior and physical lighting.

A JSON-RPC acknowledgement alone is not success. A failed or ambiguous write
must leave a recoverable state and show Restore/retry guidance. Do not
automatically overwrite the original backup with the managed mapping.

Before later configuration writes, keep a bounded pre-change recovery
snapshot. Detect external changes made by Input or another configurator;
do not overwrite them silently with a stale cached copy.

Ordinary light changes and local action reassignment must not rewrite the
device keymap when its event bindings are already correct.

## Restore and quit

Restore Original Mapping is an explicit manager action. Verify device
association and backup integrity, preview the operation and request
confirmation. Apply the saved compatible configuration, read back, and
verify ordinary behavior. A mismatched device or incompatible schema blocks
restoration with an explanation; do not force it.

Orderly Quit keeps Copilot-managed bindings for fast restart. Clear owned
runtime lighting when possible and release the transport. Explain that
managed keys need Copilot Micro running. Pause also leaves bindings in place.

No routine restore/reapply loop on quit, reconnect or login. A crash or
unplug cannot guarantee a final write; recovery must not rely on one.

## Competing clients

Work Louder Input and other integrations may write the same device.
Shared HID access is not exclusive ownership or reliable arbitration.

Warn when contention is detected or suspected, stop unsafe configuration
writes, and explain which competing software the user may need to close.
Do not kill other applications. Unexpected response IDs are a diagnostic
signal, not proof of another process's identity.

When switching USB/Bluetooth, bind the same verified physical device where
possible, invalidate stale handles, discard old physical events and
resynchronize before enabling actions.

## Local storage

Use durable application support storage, for example:

```text
~/Library/Application Support/Copilot Micro/
  config.json
  backups/
  compatibility/
  diagnostics/
```

The user's requested local preference "cache" is durable configuration, not
an evictable cache. Use a separate cache directory for disposable update
downloads or discovery acceleration.

Use user-only permissions, atomic replacements and explicit schema versions.
Malformed settings produce a recovery UI and preserve the original file;
do not silently reset a device or perform a default action.

### Configuration responsibilities

| Data | Persistence |
|---|---|
| Preferred terminal bundle identity/location | Durable, revalidated before launch |
| Chosen CLI executable hint | Durable local hint, version/identity revalidated |
| Control-to-action bindings | Durable schema-validated allowlisted action IDs |
| Brightness and optional notifications | Durable preferences |
| Recent project directories | Bounded local history, removable by the user |
| Last successful qualification tuple | Cacheable evidence, never a substitute for a live handshake |
| Original keymap backup | Durable, device-specific, never silently replaced |
| Live PID/session generation/pending approval | Memory only; re-established after reconnect |
| Credentials or transcripts | Not stored in configuration |

Suggested engineering bounds are 20 recent directories, one protected
original backup per device plus five pre-change snapshots, and bounded
diagnostic retention defined in [phase 007](phase-007-security-privacy-and-safety.md).
These limits should be visible where users clear local data.

## JSON import/export

Export one portable personal configuration with a schema version, supported
control bindings, brightness and appropriate non-secret preferences.
Exclude machine-specific executable paths, device backups, authentication,
live IDs, recent directories and diagnostic history.

An illustrative portable shape:

```json
{
  "schemaVersion": 1,
  "product": "Copilot Micro",
  "bindings": {
    "key.sessions": "session.openList",
    "key.new": "session.create",
    "key.submit": "input.submit",
    "key.cancel": "session.cancelForeground"
  },
  "lighting": {
    "brightness": 0.3
  }
}
```

The example is partial and does not imply unlisted bindings become silently
unassigned. Define the complete versioned schema before implementation;
an import preview must make every added/changed/unassigned control clear.

Reject unsupported schema versions, invalid ranges, unknown action IDs and
malformed content without changing the active configuration. Do not execute
commands or install components from imported data. Show unsupported bindings
as gaps rather than guessing replacements.

After validation, show a diff, require confirmation, save atomically and keep
the previous configuration recoverable. Local remapping does not authorize
additional device writes; if any are genuinely required, use the separate
device transaction and consent flow.

## Qualification emphasis

Test both transports with real hardware. Exercise unplug/replug, sleep/wake,
Bluetooth sleep/pairing, switching transport, wide-key duplicate events, fast
dial input, joystick neutral transitions, non-ASCII/large configurations,
missing grants, concurrent clients and interrupted writes.

The emulator must reproduce important negative cases, including ACK-only
lighting success and unbound controls. It does not establish physical HID,
Bluetooth or LED correctness.
