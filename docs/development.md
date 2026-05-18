# Development

AgentWake is a native macOS menu bar app built with SwiftPM.

## Requirements

- macOS 13 or newer
- Swift 6.0 or newer from Xcode or Command Line Tools

## Run Locally

```sh
./script/build_and_run.sh
```

This builds `AgentWake` and `AgentWakeHookAdapter`, stages
`dist/AgentWake.app`, and opens it as a real app bundle. Prefer this path for
menu bar, Settings, launch-at-login, and prompt behavior. Direct
`swift run AgentWake` runs the executable without the normal bundle context and
is only useful for narrow smoke/debug work.

The app starts as an accessory menu bar process. Normal sleep protection does
not require admin privileges. Lid-Closed Awake can prompt for administrator
approval because it changes `pmset disablesleep`.

## Check

```sh
scripts/validate.sh
```

The portable checks cover the state/menu model, lifecycle component boundaries,
persistence/privacy contracts, safety policy behavior, CLI parsing, AppKit
launch smoke, and V1 integration primitives: adapter redaction/no-op behavior,
Claude Code and Codex config patching, native Codex hook reduction,
owned-block removal, and integration removal suppression.

The local Command Line Tools environment may lack `Testing` and `XCTest`, so `AgentWakeCoreChecks` remains the portable assertion gate for those machines. When full Xcode is installed under `/Applications`, `scripts/validate.sh` uses it through `DEVELOPER_DIR` for SwiftPM tests without requiring `sudo xcode-select`. On CI and full toolchains with `Testing` or `XCTest`, `swift test` runs the standard SwiftPM test targets.

See [testing.md](testing.md) for the full validation matrix, contract-test structure, power snapshot harness, and manual hardware checklist.

## Local Data

AgentWake stores local state under `~/Library/Application Support/AgentWake/`:

- `settings.json` contains versioned settings.
- `logs/audit.jsonl` contains bounded local audit events.
- `run/hook-token` is a per-launch adapter token and is removed when the control server stops.
- `cwd-hash-salt` is an app-local salt used to HMAC agent cwd values before they reach the state machine.

User-facing Settings currently manage launch-at-login preference, per-agent
enablement, pause duration, and Lid-Closed Awake safety thresholds. The safety
settings are persisted in `settings.json`; battery floor and macOS critical
thermal pressure are enforced by the runtime release-only safety monitor, while
direct temperature thresholds are stored for the future temperature-provider
path.

Removing an agent hook records an auto-install suppression in `settings.json` so
AgentWake does not silently reinstall a hook the user removed. The app uninstall
sheet has an optional fresh-install cleanup checkbox, and the CLI has
`agentwake uninstall --remove-integrations --remove-settings`, to clear that
saved suppression before reinstall testing.

Pre-release ClawShell state under `~/Library/Application Support/ClawShell/` is
not migrated. The integration patchers still recognize and remove legacy
ClawShell-owned Claude Code and Codex CLI hooks so early dogfood installs do not
keep duplicate product-owned hooks after the rename.

Config exports exclude logs, runtime tokens, helper ownership state, integration status paths, cwd hashes, and hook payloads. Custom executable paths can still reveal local machine details, so exported config should be shared carefully.
