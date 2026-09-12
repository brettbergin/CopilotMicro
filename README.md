# Copilot Micro

A native macOS menu bar companion that turns a Work Louder Creator Micro 2 Pro
into a control surface for GitHub Copilot CLI.

The keypad mirrors the selected CLI session's mode and activity, and provides
session management, model/effort, voice, input, cancellation and permission
controls. A graphical manager provides onboarding, remapping, diagnostics and
local configuration.

**Status:** product/design foundation and developer setup tooling. The native
application and hardware/CLI integrations are not implemented or qualified yet.

## Developer setup

Install full [Xcode](https://apps.apple.com/app/xcode/id497799835) from Apple
and open it once to finish its license/component setup. Command Line Tools
alone are insufficient for the native app/UI workflow.

With Node installed, check the Xcode prerequisite without changing the global
developer-tool selection:

```sh
make doctor-xcode
```

For a nonstandard installation, select it for just the command:

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" make doctor-xcode
```

The developer tools are declared in `Brewfile`. Once full Xcode setup is
complete, review that file and install missing tools with
`brew bundle install --file=Brewfile --no-upgrade`, then run `make doctor`.
The checker is read-only; it does not install tools or log into Copilot.

Run `make check` for the setup checker's syntax/tests. This does not build or
qualify a native application. Missing prerequisites are reported explicitly.

## Product documentation

Start with [the product charter and document map](docs/phase-000-product-charter.md).
The ten `docs/phase-00*.md` documents record the product decisions from the
2026-09-11 stakeholder interview and define the implementation and acceptance
contracts. Their numbering is a reading order, not a claim that any engineering
phase has shipped.

Implementation begins with the native GUI/emulator after developer setup,
then adds qualified live integrations. Simulation is never presented as
successful CLI or hardware control.

The initial target is an internal team using Apple Silicon Macs on macOS Tahoe
26.x, with 26.6.2 as the first qualification baseline. Intended terminals are
Ghostty, iTerm2 and Terminal.app; both USB and Bluetooth are intended for the
Creator Micro 2 Pro. GitHub Copilot desktop-app integration is out of scope.

This is an internal project. No open-source license is granted at this stage.
Do not copy unlicensed reference code or assets into it.
