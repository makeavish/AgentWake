# Testing

ClawShell uses two automated gates today:

- `ClawShellCoreChecks` is the portable local gate. It runs on the current Command Line Tools environment even when `Testing` and `XCTest` are unavailable.
- SwiftPM test targets are the standard test home for CI and full Xcode toolchains.

Run the complete local validation script:

```sh
scripts/validate.sh
```

The script runs:

- `swift build`
- `swift run ClawShellCoreChecks`
- `swift run ClawShell --smoke-test`
- `swift test` only when the active toolchain can discover both required ClawShell test targets

If the local toolchain cannot import `Testing` or `XCTest`, the script skips SwiftPM tests with an explicit message. If test discovery succeeds but either required target is missing, the script fails instead of passing with partial coverage.

## Unit Test Matrix

`Tests/ClawShellCoreTests` is the home for unit tests. The issue #9 coverage plan is registered in `IssueNineCoveragePlanTests`; rows are promoted from `pendingImplementation` as behavior-level assertions land.

- Session transition matrix: covered by `AgentSessionStateMachineTests`
- PID reuse and process restart dedupe: covered by `AgentSessionStateMachineTests`
- Out-of-order hook events
- Grace timer reset and non-reset rules: covered by `AgentSessionStateMachineTests`
- Manual override precedence and persistence
- Safety transitions, stale sensors, unavailable sensors, and hysteresis
- Settings migration, atomic write, corrupt settings recovery
- Export redaction and exclusion rules

## Contract Test Matrix

`Tests/ClawShellContractTests` is the home for integration and contract tests. Fixture slots already exist under `Tests/ClawShellContractTests/Fixtures/`, and the harness asserts that each slot is present as a directory.

The registered contract coverage rows are:

- Adapter redaction: fail if payloads or logs contain prompts, tool args, cwd, transcript paths, or environment values
- Adapter no-op behavior when ClawShell is not running
- Control endpoint auth failure, replay rejection, and rate limiting: covered through the Unix socket by `ControlServerTests`
- Control endpoint peer PID identity: covered by socket tests that reject client-supplied PID rotation
- Config patcher fixtures for Claude Code and Codex CLI
- Config merge/removal preserving unrelated user config
- CLI command behavior: covered by parser, local client, and socket transport tests in `ControlServerTests`

## Coverage Status

- `automated`: covered by the current portable checks or SwiftPM tests.
- `fixtureSlot`: the contract-test slot exists now; behavior-level fixtures land with the feature.
- `pendingImplementation`: the required row is registered and should become executable as the owning implementation issue lands.
- `manualChecklist`: the row is intentionally gated on hardware validation.

## Power Snapshot Harness

Use the non-destructive snapshot harness before and after power-management experiments:

```sh
scripts/pmset-snapshot.sh
```

The harness captures `pmset` and power-state diagnostics without changing power settings. It must not be used as proof that ClawShell blocks clamshell sleep; it only records state for validation artifacts.

## Manual Hardware Checklist

Hardware validation is gated and must be run intentionally on supported machines. Do not intentionally overheat hardware; thermal cutoff validation uses mocks or simulated sensor providers.

- AC lid close
- Battery lid close
- Reboot while held
- App crash while held
- Helper crash and restart
- Helper upgrade mid-hold
- Concurrent power setting changes by the user or system

For each manual case, attach:

- Exact command or build used
- macOS version
- CPU architecture
- Power source
- Display topology
- Lid state and reopen recovery result
- Lifecycle condition under test
- `pmset -g custom`
- `pmset -g assertions`
- Relevant IORegistry state if available
- Whether lid-close sleep was actually blocked
- Rollback command
- State after reboot, when applicable
