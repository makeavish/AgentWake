# AgentWake

Close the lid. The agent keeps running.

AgentWake is a native macOS menu bar app for keeping long-running AI coding agents alive while they work, then letting the Mac return to normal sleep behavior when they are done.

It is designed for developers using tools like Claude Code and Codex CLI on a MacBook as their main machine.

## What Works Today

AgentWake is in early public release, focused on Claude Code and Codex CLI.

| Capability | Claude Code | Codex CLI |
|---|---|---|
| Auto-detect | Hooks + process detection | Hooks + process detection |
| Idle sleep | Supported | Supported |
| Lid-closed on AC | Admin-approved | Admin-approved |
| Lid-closed on battery | Works, safety cutoffs TBD | Works, safety cutoffs TBD |
| Manual protection | Protect detected sessions | Protect detected sessions |
| Pause / resume | Supported | Supported |

## Why

Long-running coding agents can work for minutes or hours. macOS can interrupt them through idle sleep or clamshell sleep, especially when a MacBook lid is closed on battery.

`caffeinate -i` helps with idle sleep, but it is easy to forget and does not track agent lifecycle. AgentWake aims to make normal sleep prevention automatic, visible, and agent-scoped without becoming a general-purpose "keep my Mac awake forever" tool.

Closed-Lid Mode currently uses macOS administrator approval to toggle the
`pmset disablesleep` primitive and records the prior value so AgentWake can
restore it when disabled.

Gemini CLI, Cursor, VS Code, and custom binaries are planned for later versions.

## Planned Later Support

- Gemini CLI
- Cursor
- VS Code
- Custom agent binaries

## Safety Model

Closed-lid battery support is treated as a guarded mode, not a blanket promise that every situation is safe.
Closed-Lid Mode is currently an explicit admin-approved local mode. It changes
`pmset disablesleep`, records the prior value, and restores that value when
disabled. Temperature-provider cutoff automation remains a guarded follow-up.

Current safeguards include:

- First-run consent before closed-lid battery mode is enabled
- A visible menu bar state when guarded mode is active

Planned safeguards include:

- Temperature warning and cutoff thresholds
- Battery floor cutoff
- Automatic release when safety limits are crossed
- A privileged helper only for the closed-lid battery path

Normal sleep prevention should work without admin privileges. macOS authorization is planned only when installing the privileged helper needed for closed-lid battery support.

The CLI vocabulary is `agentwake closed-lid status|enable|disable`. Enable and
disable may show a macOS administrator prompt because the closed-lid primitive
requires privileged power-setting changes.

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

Download the latest macOS ZIP from GitHub Releases and move `AgentWake.app` to
`/Applications`.

Current releases are ad-hoc signed. macOS may require right-click -> Open on
first launch; moving the app into `/Applications` may ask for administrator
approval depending on your machine; Lid-Closed Awake asks for administrator
approval when you turn it on or off because it changes `pmset disablesleep`.

The planned primary distribution path is a Homebrew cask. Developer ID signing
and notarization are planned after the early release path is validated and the
Apple Developer Program fee is funded. See [CHANGELOG.md](CHANGELOG.md) for
release scope and Closed-Lid Mode boundaries.

## Release Packaging

Build a local release ZIP:

```sh
scripts/package-release.sh --version v0.2.0
```

The generated artifact is ad-hoc signed and does not install/register privileged
helpers. Closed-Lid Mode uses macOS administrator approval at the moment the
user enables or disables it.

## Development

This repo now contains the first SwiftPM menu bar app skeleton. See [docs/development.md](docs/development.md) for local run and check commands.

## License

MIT
