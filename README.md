# ClawShell

Close the lid. The agent keeps running.

ClawShell is a planned native macOS menu bar app for keeping long-running AI coding agents alive while they work, then letting the Mac return to normal sleep behavior when they are done.

It is designed for developers using tools like Claude Code, Codex CLI, Cursor, VS Code, and Gemini CLI on a MacBook as their main machine.

## Status

ClawShell is in early design. There is no public release yet.

The first public version is planned to focus on:

- Detecting active agent sessions automatically
- Holding normal macOS sleep while agents are working
- Supporting closed-lid runs with guarded battery and thermal controls
- Showing exactly why sleep is currently being held
- Releasing sleep prevention when agent work finishes or times out

## Why

Long-running coding agents can work for minutes or hours. macOS can interrupt them through idle sleep or clamshell sleep, especially when a MacBook lid is closed on battery.

`caffeinate -i` helps with idle sleep, but it does not fully solve closed-lid workflows. ClawShell aims to make these runs reliable without becoming a general-purpose "keep my Mac awake forever" tool.

## Planned V1 Support

| Agent | Planned V1 behavior |
|---|---|
| Claude Code | First-class local integration where available, with process fallback |
| Codex CLI | Local notification/integration where available, with process fallback |
| Gemini CLI | Local hook integration where available, with process fallback |
| Cursor | App/session-level detection |
| VS Code | App/session-level detection for stable, Insiders, and VSCodium |

Custom binaries are planned too. They will use generic process detection rather than first-class integrations.

## Safety Model

Closed-lid battery support is treated as a guarded mode, not a blanket promise that every situation is safe.

Planned safeguards include:

- First-run consent before closed-lid battery mode is enabled
- A visible menu bar state when guarded mode is active
- Temperature warning and cutoff thresholds
- Battery floor cutoff
- Automatic release when safety limits are crossed
- A privileged helper only for the closed-lid battery path

Normal sleep prevention should work without admin privileges. macOS authorization is planned only when installing the privileged helper needed for closed-lid battery support.

## Privacy Model

ClawShell is designed to be local-first.

Planned privacy constraints:

- No telemetry
- No cloud account requirement
- No prompt text reading for detection
- No terminal-content reading for detection
- No tool-argument or command-body collection
- Local logs for state changes, integration setup, helper actions, and safety cutoffs

If ClawShell installs local agent integrations, the app should show what was installed, log what config changed, and provide removal controls.

## Install

No installable build is available yet.

The planned primary distribution path is a Homebrew cask. Direct downloads may come later, with signing and notarization planned after the early release path is validated.

## Development

This repo is currently in product and technical design. Implementation will start after the technical design for detection, integrations, sleep assertions, and the privileged helper is settled.

## License

MIT
