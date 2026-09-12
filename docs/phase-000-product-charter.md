# Phase 000: product charter

Status: agreed product direction; developer tooling and an emulator-only
native scaffold exist, with no live integrations yet.
Decision date: 2026-09-11.
Product: Copilot Micro.
Repository: `github-app-micro2`.

## Purpose

Give an internal development team a polished physical interface to GitHub
Copilot CLI without replacing the CLI, starting an unrelated agent for each
button press, or requiring users to memorize terminal shortcuts.

The device should make the selected chat's mode and activity immediately
recognizable and make common session operations deliberate, predictable and
recoverable.

## Goals and outcomes

| Goal | Observable outcome |
|---|---|
| G-01: understand the selected session | All key LEDs show its mode/activity according to one documented state machine |
| G-02: manage work from the pad | Supported controls operate the intended existing CLI session, not whichever terminal happens to receive a keystroke |
| G-03: make setup approachable | A teammate can discover their terminal, CLI and device, grant permissions, install the bridge with consent, and verify a reversible mapping |
| G-04: provide a polished native experience | Menu bar status, a full graphical manager, explicit errors, recovery, remapping and update handling form one coherent application |
| G-05: preserve trust | No blind approval, silent session substitution, unexpected credential access, hidden telemetry or automatic loss of the original keymap |

A successful release is useful as an end-to-end internal product, not a
collection of raw RPC experiments. However, an integration that cannot be
implemented reliably may be skipped. Its gap must be visible in the product
and in the delivery report; it must not be hidden behind a success-shaped
fallback.

## Audience and supported context

- Internal developers, initially using one Copilot CLI window and switching
  between sessions inside that instance.
- Apple Silicon M1 and newer. Intel is out of scope.
- macOS Tahoe 26.x; 26.6.2 is the initial qualification baseline, not proof
  that every Tahoe patch has already been exercised.
- Creator Micro 2 Pro, over USB and Bluetooth.
- Ghostty, iTerm2 and Terminal.app.
- A documented, qualified CLI version may be a prerelease using experimental
  extensions. Arbitrary installed CLI versions are not automatically supported.

If multiple CLI instances are detected, the user explicitly selects the
controlled instance. Only one instance/session is the active hardware target
at a time. A global multi-agent dashboard is not required.

## Product boundaries

Copilot Micro owns hardware configuration, local preferences, the native
manager and a narrow bridge to the CLI. Copilot CLI owns session semantics,
agent execution, policies, archives, chat drafts and its existing voice system.

The first release is not:

- A GitHub Copilot desktop-app integration.
- A new agent/chat frontend or a cloud-hosted controller.
- A complete replacement for Work Louder Input.
- A custom firmware project or an original Creator Micro/QMK/VIA integration.
- A public, universally compatible hardware product.
- An archived-session browser or restore interface.
- A saved-prompt-template system, multi-profile system or automatic
  project-dependent layout switcher.
- An always-approve mechanism.

## Document map and canonical ownership

| Document | Owns |
|---|---|
| [001: requirements and scope](phase-001-requirements-and-scope.md) | Feature IDs, scope and capability reporting |
| [002: user experience](phase-002-user-experience.md) | Onboarding, menu bar, manager, focus and journeys |
| [003: controls and lighting](phase-003-controls-and-lighting.md) | Physical layout, contextual controls and LED state |
| [004: session lifecycle](phase-004-session-lifecycle.md) | Session actions, cancellation, archive, input and voice |
| [005: architecture and contracts](phase-005-architecture-and-contracts.md) | Components, bridge protocol and integration evidence |
| [006: device and configuration](phase-006-device-and-configuration.md) | HID, backups, persistence, remapping and import/export |
| [007: security, privacy and safety](phase-007-security-privacy-and-safety.md) | Trust boundaries, authorization and fail-closed rules |
| [008: distribution and support](phase-008-distribution-and-support.md) | Internal packaging, updater and compatibility policy |
| [009: delivery and acceptance](phase-009-delivery-and-acceptance.md) | Implementation order, qualification and gap report |

These documents are authoritative for this project. Research references explain
feasibility; they do not override interview decisions or establish implemented
behavior. When documents overlap, the canonical owner above controls details.
Safety constraints apply across every feature.

## Decision register

This is the consolidated result of nine interview rounds, not an open
brainstorm. Technical probes below do not reopen settled product choices.

| Decision | Agreement |
|---|---|
| D-01: audience and quality | Internal team; polished end-to-end experience |
| D-02: integration | CLI only for the foreseeable future |
| D-03: lighting | All key LEDs mirror the selected session; default white, plan blue, autopilot purple |
| D-04: activity | Blink mode color while busy; completed work stays green until acknowledged |
| D-05: completion already visible | Remain green until subsequent user interaction, not a timer |
| D-06: attention and errors | Amber pulse for human input; steady red for error; off without a live CLI connection |
| D-07: session operations | Native list, switch, project-aware new session and native archive |
| D-08: archive | Preserve history; ask before cancelling busy work; do not restore archives in this app |
| D-09: extra controls | Mode, model, effort, voice, cancel, submit, focus and approve/reject |
| D-10: physical UX | Agreed default layout; contextual dial/joystick; GUI reassignment |
| D-11: focus guard | A first press from another application focuses the selected CLI only; another press is required to act |
| D-12: permission decision | One press only for the exact permission prompt already visibly active in the selected CLI; approve once |
| D-13: cancellation | Only the selected session's foreground task; preserve background work and queued prompts |
| D-14: integration fallback | Prefer APIs; validated UI automation for appropriate navigation/input operations; never blind approvals |
| D-15: platform | Creator Micro 2 Pro USB/Bluetooth; M1+; Tahoe 26.x |
| D-16: terminal setup | Discover Ghostty/iTerm2/Terminal, show results, ask preference, persist locally |
| D-17: onboarding | Guided, consent-based bridge installation and reversible keymap setup |
| D-18: application UX | Compact menu bar panel plus full manager; explicit Open Copilot when disconnected |
| D-19: configuration | One personal configuration, JSON import/export; no named profiles initially |
| D-20: notifications | LEDs/menu bar by default; OS notifications opt-in |
| D-21: distribution | Internal unsigned/ad-hoc builds first; code signing/notarization later |
| D-22: updates | Built-in updater with explicit approval; internal GitHub Releases using existing `gh` authentication where needed |
| D-23: privacy | Local configuration/diagnostics; no telemetry; user-requested redacted export |
| D-24: licensing | Internal-only for now; no copying unlicensed reference code/assets |
| D-25: unsupported features | Skip unsafe/unreliable features and report each gap explicitly |
| D-26: quit behavior | Keep managed device mapping; explicit Restore Original Mapping; no routine flash rewrite on quit |

## Definitions

**Selected session:** the session selected in the explicitly controlled CLI
instance. It is not an independent, potentially different selection in our GUI.

**Foreground application:** the macOS application currently receiving user
interaction. A CLI session can be selected without its terminal being frontmost.

**Visible target:** the exact terminal window/tab/pane displaying the selected
CLI session, verified by the terminal adapter.

**Acknowledged completion:** a completed session that the user subsequently
selects/views or interacts with through a verified signal. Existing visibility
at the instant of completion is not acknowledgement.

**Gap:** intended functionality unavailable on a particular qualified or
candidate configuration, recorded with its reason, impact and disposition.

## Change control

Implementation may choose internal types, helpers and libraries consistent
with these contracts. It must not silently change cancellation scope, approval
semantics, data collection, archive meaning or device ownership.

Record intentional requirement changes against the affected feature and
acceptance IDs, update canonical and dependent documents together, and explain
the impact. Do not treat an API convenience as permission to redesign the
user's workflow.
