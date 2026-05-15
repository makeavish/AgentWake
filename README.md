# AgentWake

Keep coding agents running while your Mac would normally sleep.

AgentWake is a planned native macOS menu bar app for keeping long-running AI coding agents alive while they work, then letting the Mac return to normal sleep behavior when they are done.

It is designed for developers using tools like Claude Code and Codex CLI on a MacBook as their main machine.

## Status

AgentWake is in early design. There is no public release yet.

The first public version is planned to focus on:

- Detecting active agent sessions automatically
- Holding normal macOS sleep while agents are working
- Showing exactly why sleep is currently being held
- Releasing sleep prevention when agent work finishes or times out
- Showing Closed-Lid Mode as unavailable until the helper lifecycle and live
  temperature-provider validation gates are complete

## Why

Long-running coding agents can work for minutes or hours. macOS can interrupt them through idle sleep or clamshell sleep, especially when a MacBook lid is closed on battery.

`caffeinate -i` helps with idle sleep, but it is easy to forget and does not track agent lifecycle. AgentWake aims to make normal sleep prevention automatic, visible, and agent-scoped without becoming a general-purpose "keep my Mac awake forever" tool.

Closed-Lid Mode remains a planned guarded path after the helper and
temperature-provider validation gates pass.

## Planned First Version Support

| Agent | Planned behavior |
|---|---|
| Claude Code | First-class local hook integration where available, with process fallback |
| Codex CLI | Native lifecycle hooks where available, legacy `notify` completion fallback, and process fallback |

Gemini CLI, Cursor, VS Code, and custom binaries are planned for later versions.

## Planned Later Support

- Gemini CLI
- Cursor
- VS Code
- Custom agent binaries

## Safety Model

Closed-lid battery support is treated as a guarded mode, not a blanket promise that every situation is safe.
Closed-Lid Mode is currently unavailable in the app until helper lifecycle and live
temperature-provider validation are complete.

Planned safeguards include:

- First-run consent before closed-lid battery mode is enabled
- A visible menu bar state when guarded mode is active
- Temperature warning and cutoff thresholds
- Battery floor cutoff
- Automatic release when safety limits are crossed
- A privileged helper only for the closed-lid battery path

Normal sleep prevention should work without admin privileges. macOS authorization is planned only when installing the privileged helper needed for closed-lid battery support.

## Privacy Model

AgentWake is designed to be local-first.

Planned privacy constraints:

- No telemetry
- No cloud account requirement
- No prompt text reading for detection
- No terminal-content reading for detection
- No tool-argument or command-body collection
- Local logs for state changes, integration setup, helper actions, and safety cutoffs

If AgentWake installs local agent integrations, the app should show what was installed, log what config changed, and provide removal controls.
The V1 adapter contract reduces native hook payloads to a minimal event schema and discards prompts, tool arguments, raw cwd values, transcript paths, and environment data before events reach AgentWake.

## Install

No hosted or Homebrew installable build is available yet.

The planned primary distribution path is a Homebrew cask. Direct downloads may come later, with signing and notarization planned after the early release path is validated.
See [CHANGELOG.md](CHANGELOG.md) for the pending v1 release scope and Closed-Lid Mode boundary.

## Release Packaging

Build a local release ZIP:

```sh
scripts/package-release.sh --version v0.1.0
```

The generated artifact is ad-hoc signed, does not install/register privileged
helpers, and keeps Closed-Lid Mode unavailable for the v0.1.0 scope.

## Development

This repo now contains the first SwiftPM menu bar app skeleton. See [docs/development.md](docs/development.md) for local run and check commands.

## License

MIT
