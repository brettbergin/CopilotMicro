# Copilot Micro

A native macOS menu bar companion that turns a Work Louder Creator Micro 2 Pro
into a control surface for GitHub Copilot CLI.

The keypad mirrors the selected CLI session's mode and activity, and provides
session management, model/effort, voice, input, cancellation and permission
controls. A graphical manager provides onboarding, remapping, diagnostics and
local configuration.

**Status:** product/design foundation only. There is no application
implementation or qualified hardware/CLI integration in this repository yet.

Start with [the product charter and document map](docs/phase-000-product-charter.md).
The ten `docs/phase-00*.md` documents record the product decisions from the
2026-09-11 stakeholder interview and define the implementation and acceptance
contracts. Their numbering is a reading order, not a claim that any engineering
phase has shipped.

The initial target is an internal team using Apple Silicon Macs on macOS Tahoe
26.x, with 26.6.2 as the first qualification baseline. Intended terminals are
Ghostty, iTerm2 and Terminal.app; both USB and Bluetooth are intended for the
Creator Micro 2 Pro. GitHub Copilot desktop-app integration is out of scope.

This is an internal project. No open-source license is granted at this stage.
Do not copy unlicensed reference code or assets into it.
