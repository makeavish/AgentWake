# AgentWake

Close the lid. The agent keeps running.

AgentWake is a native macOS menu bar app for long-running Claude Code and
Codex CLI work:

- keeps the Mac awake while active agent sessions run
- shows a glanceable menu bar state
- releases sleep protection when sessions finish
- can keep the Mac active manually for a chosen duration or indefinitely
- supports explicit helper-backed Lid-Closed Awake with release-only battery and
  thermal safety cutoffs
- lets you pause protection for a chosen duration when you intentionally want
  macOS to sleep

It is designed for developers using tools like Claude Code and Codex CLI on a MacBook as their main machine.

## What Works Today

AgentWake is in early public release, focused on Claude Code and Codex CLI.

| Capability | Claude Code | Codex CLI |
|---|---|---|
| Auto-detect | Hooks + process detection | Hooks + process detection |
| Idle sleep | Supported | Supported |
| Lid-closed on AC | Helper-backed | Helper-backed |
| Lid-closed on battery | Works, release-only safety cutoffs | Works, release-only safety cutoffs |
| Manual Mac Active | Duration-based | Duration-based |
| Pause / resume | Supported | Supported |
| Launch at login | Optional Settings toggle | Optional Settings toggle |

## Why

Long-running coding agents can work for minutes or hours. macOS can interrupt them through idle sleep or clamshell sleep, especially when a MacBook lid is closed on battery.

`caffeinate -i` helps with idle sleep, but it is easy to forget and does not track agent lifecycle. AgentWake aims to make normal sleep prevention automatic, visible, and agent-scoped, while still offering an explicit timed or indefinite manual hold when you need one.

Lid-Closed Awake uses an installed privileged helper to toggle the
`pmset disablesleep` primitive while AgentWake is already keeping the Mac awake.
After the one-time helper approval, AgentWake can restore the prior value
without another password prompt when that sleep protection ends or when you turn
Lid-Closed Awake off.

Gemini CLI, Cursor, VS Code, and custom binaries are planned for later versions.

## Planned Later Support

- Gemini CLI
- Cursor
- VS Code
- Custom agent binaries

## Safety Model

Closed-lid battery support is treated as a guarded mode, not a blanket promise that every situation is safe.
Lid-Closed Awake is currently an explicit helper-backed local mode. It changes
`pmset disablesleep` only while AgentWake is already keeping the Mac awake,
records the prior value, and restores that value when protection ends or when
disabled. Safety cutoffs are release-only: AgentWake turns Lid-Closed Awake off
when a limit is crossed, and it does not auto-resume.

Current safeguards include:

- First-run consent before closed-lid battery mode is enabled
- A visible menu bar state when guarded mode is active
- Configurable battery floor release, defaulting to 15%
- Direct IOReport temperature cutoff preflight/release using the stored Settings
  threshold when the provider returns a usable sample, with fail-closed behavior
  otherwise
- Critical macOS thermal-pressure release

Normal sleep prevention works without admin privileges. macOS authorization is
only for approving the privileged helper needed for closed-lid battery support.

The CLI vocabulary is `agentwake closed-lid status|enable|disable`. Enable is
available only while AgentWake is actively keeping the Mac awake. Enable or
disable uses the installed helper; if the helper has not been approved yet,
run `agentwake helper repair` and approve AgentWake in System Settings.

## Settings

Settings exposes:

- Launch at login
- Per-agent enable/disable toggles for Claude Code and Codex CLI
- Integration details, including config paths and owned changes
- Safety thresholds for Lid-Closed Awake
- Keep Mac Active with duration choices
- Pause Sleep Protection with duration choices
- Event log, diagnostic copy, and uninstall actions

Uninstall removes AgentWake-owned hooks, turns off launch at login, restores
AgentWake-owned Lid-Closed Awake state, moves the app bundle to Trash, and quits.
For reinstall testing, the uninstall confirmation can also remove saved
AgentWake settings so hook auto-install suppression does not carry into the next
launch.

## Privacy Model

AgentWake is designed to be local-first.

Planned privacy constraints:

- No telemetry
- No cloud account requirement
- No prompt text reading for detection
- No terminal-content reading for detection
- No tool-argument or command-body collection
- Local logs for state changes, integration setup, helper actions, and safety cutoffs

If AgentWake installs local agent integrations, the app shows the config path, previews owned hook changes, logs setup/removal, and provides removal controls.
The V1 adapter contract reduces native hook payloads to a minimal event schema and discards prompts, tool arguments, raw cwd values, transcript paths, and environment data before events reach AgentWake.

## Install

Download the latest macOS ZIP from
[GitHub Releases](https://github.com/makeavish/AgentWake/releases/latest),
unzip it, and move `AgentWake.app` to `/Applications`.

Current releases are ad-hoc signed. macOS may require right-click -> Open on
first launch; moving the app into `/Applications` may ask for administrator
approval depending on your machine; Lid-Closed Awake asks for administrator
approval only while installing/approving the helper. It restores normal sleep
when the current AgentWake protection ends.

The planned primary distribution path is a Homebrew cask. Developer ID signing
and notarization are planned after the early release path is validated and the
Apple Developer Program fee is funded. See [CHANGELOG.md](CHANGELOG.md) for
release scope and Closed-Lid Mode boundaries.

## Release Packaging

Build a local release ZIP:

```sh
scripts/package-release.sh --version v0.2.2
```

The generated artifact is ad-hoc signed and bundles the privileged helper. It
does not register or activate that helper during packaging; the app registers it
only after explicit Lid-Closed Awake consent.

## Development

This repo contains the SwiftPM menu bar app, hook adapter, CLI, and validation
scripts. See [docs/development.md](docs/development.md) for local run and check
commands.

## License

MIT
