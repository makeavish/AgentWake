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
- Normal assertion ownership/release and failed-release retry behavior: covered by `AssertionManagerTests`
- Safety transitions, stale sensors, unavailable sensors, and hysteresis: covered by `BagModeSafetyPolicy` checks in `ClawShellCoreChecks`
- Settings migration, atomic write, corrupt settings recovery
- Export redaction and exclusion rules

## Contract Test Matrix

`Tests/ClawShellContractTests` is the home for integration and contract tests. Fixture slots already exist under `Tests/ClawShellContractTests/Fixtures/`, and the harness asserts that each slot is present as a directory.

The registered contract coverage rows are:

- Adapter redaction: fail if payloads or logs contain prompts, tool args, cwd, transcript paths, or environment values
- Adapter no-op behavior when ClawShell is not running
- Control endpoint auth failure, replay rejection, and rate limiting: covered through the Unix socket by `ControlServerTests`
- Control endpoint peer PID identity: covered by socket tests that reject client-supplied PID rotation
- Config patcher fixtures for Claude Code and Codex CLI: covered by `IntegrationContractTests`
- Config merge/removal preserving unrelated user config: covered by `IntegrationContractTests`
- CLI command behavior: covered by parser, local client, and socket transport tests in `ControlServerTests`

## Integration Checks

The V1 integration layer has both portable checks and contract fixtures:

- `HookAdapterMapper` reduces Claude Code hook stdin and Codex `notify` payloads to ClawShell's minimal event schema.
- Adapter output is host-safe and empty on success/no-op, including when ClawShell is not running.
- Claude Code patching preserves existing hook groups, adds only owned command handlers, and removes only handlers containing ClawShell's owner marker.
- Codex patching owns native hook groups for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, and `Stop`, keeps the top-level `notify` fallback, forwards a previous notify command through the adapter, preserves unrelated TOML and user hooks, and restores the previous notify line on removal.
- Native Codex hook stdin is reduced to ClawShell's minimal event schema without prompt text, raw cwd, transcript paths, tool input, tool output, or assistant text. See [codex-native-hooks.md](codex-native-hooks.md) for confidence transitions.
- Integration removal persists per-agent `doNotAutoInstall` suppression and writes a local audit event.

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

Use the normal assertion validation harness to capture `before`, `during`, and `after` snapshots around a temporary non-privileged IOPM hold:

```sh
scripts/normal-assertion-validation.sh
```

Use the timed idle harness for AC/battery idle behavior runs under the current machine power profile:

```sh
bash scripts/timed-idle-validation.sh
```

Use the timed idle preflight helper before a clean run to avoid spending a full hold window when the machine is not clean right now:

```sh
scripts/timed-idle-preflight.sh
```

Preflight is only a readiness check. It does not create validation evidence.
When it finds non-ClawShell blockers, it prints cleanup hints for common
assertions such as WindowServer `UserIsActive`, powerd display-on,
sharingd/Handoff, Slack/WebRTC, coreaudiod audio activity, and Codex/Electron.
#5 closed by explicit owner sign-off on the documented non-conclusive lifecycle
evidence.

See [power-validation.md](power-validation.md) for the current normal assertion policy, disk/display assertion status, timed-idle caveats, and hardware result matrix.

## Bag Mode Primitive Harness

Use the Bag Mode primitive harness only for issue #7/#29 evidence:

```sh
sudo scripts/bag-mode-primitive-validation.sh \
  --output-dir .build/power-validation/bag-mode-matrix/apple-silicon-battery-internal \
  --case-id apple-silicon-battery-internal \
  --apply \
  --i-understand-this-changes-power-settings
```

The default run is baseline-only and non-mutating. Mutating lid-close or reboot-held runs require root and explicit acknowledgement; attach the evidence directory and filled `manual-result.md` to the primitive matrix issue. For reboot-held evidence, add `--reboot-held`, follow `ROLLBACK_REQUIRED.txt`, capture `post-reboot/`, roll back, and capture `after-rollback/`.

Record every supported row or explicit N/A/deferred reason in a tab-separated manifest:

```tsv
caseId	status	evidenceDir	naReason
apple-silicon-battery-internal	evidence	apple-silicon-battery-internal	evidence attached
macos-13-intel	deferred		No Intel test host in scope for this run
external-display	n/a		No external display physically available
```

Before attaching a matrix evidence root, run:

```sh
scripts/bag-mode-primitive-matrix-verify.sh --manifest .build/power-validation/bag-mode-matrix/matrix-manifest.tsv
```

This checks manifest and evidence completeness only. It does not prove the primitive is reliable. After the matrix is attached to #29, update the readiness docs with the pass/fail/inconclusive result before production Bag Mode implementation begins.

## Temperature Provider Harness

Use the non-destructive temperature-provider harness for #7 safety-source checks:

```sh
scripts/temperature-provider-validation.sh --output-dir .build/temperature-provider-validation/local-$(date -u +%Y%m%dT%H%M%SZ)
```

The harness writes `validation-config.txt`, command outputs, command status files, and `summary.md`. It never uses sudo and must not mark `bagModeTemperatureProviderReady=true`; production provider readiness requires the signed-helper follow-up.

Use the helper-equivalent preflight before attempting root/helper
`powermetrics` sampling:

```sh
scripts/temperature-provider-helper-readiness.sh --output-dir .build/temperature-provider-helper-readiness/local-$(date -u +%Y%m%dT%H%M%SZ)
```

This preflight is non-mutating and never prompts for sudo; it uses `sudo -n`
only to classify whether helper-equivalent sampling is available without a
user-visible authorization path. It must always record
`providerProofReady=false` because it does not prove freshness, cadence,
closed-bag coverage, fail-closed behavior, or provider reliability.

Thermal cutoff and fail-closed behavior are tested with mocked provider inputs through `BagModeSafetyPolicy`. These tests cover warning, cutoff, stale, unavailable, permission-denied, parse-failed, helper-crashed, unsupported-hardware, timeout, coverage-insufficient, missing/invalid battery, battery floor, and hysteresis transitions without intentionally heating hardware.

Use the helper provider proof verifier before attaching #25 evidence:

```sh
scripts/temperature-provider-proof-verify.sh \
  --manifest .build/temperature-provider-proof/<case-id>/provider-manifest.tsv
```

The verifier checks that `validation-config.txt`, `manual-result.md`, and the
TSV manifest contain rows/fields for helper-owned numeric provider evidence,
freshness within 10s, 5s/30s cadence, 1s timeout, prompt-free sampling,
ProcessInfo as supplemental-only, closed-bag coverage, fail-closed cases, logs,
and conditional combined-signal evidence. It is a structural gate only; it does
not select a provider or run privileged sampling.

## Helper Service Readiness Harness

Use the non-mutating helper readiness harness before attempting a signed `SMAppService` prototype:

```sh
scripts/helper-service-readiness.sh --output-dir .build/helper-service-readiness/local-$(date -u +%Y%m%dT%H%M%SZ)
```

The harness records code-signing identity count and local tool availability. It
also distinguishes the active `xcode-select` developer directory from a full
Xcode install discovered under `/Applications`, because Xcode can be installed
while the active developer directory still points at Command Line Tools. It does
not install, register, approve, unregister, or run a helper.

Use the signed prototype evidence verifier before attaching #27 evidence:

```sh
scripts/helper-service-prototype-verify.sh \
  --manifest .build/helper-service-prototype/<case-id>/prototype-manifest.tsv
```

The verifier checks `validation-config.txt`, `manual-result.md`, and the TSV
manifest for the required app/helper signing, `SMAppService`, approval,
bootstrap, reboot, update, uninstall, failure-case, `launchctl`, and log
evidence rows. It is a structural gate only; it does not sign, install,
register, approve, unregister, or run a helper.

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
