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
- `swift test` when the active toolchain, or a full Xcode discovered under `/Applications`, can discover both required ClawShell test targets

If the active Command Line Tools environment cannot import `Testing` or `XCTest`,
the script tries a discovered full Xcode by setting `DEVELOPER_DIR` for SwiftPM
test discovery and execution. If no usable full Xcode is available, it skips
SwiftPM tests with an explicit message. If test discovery succeeds but either
required target is missing, the script fails instead of passing with partial
coverage.

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

Use the matrix scaffold when starting a new local matrix package:

```sh
scripts/bag-mode-primitive-matrix-scaffold.sh \
  --output-dir .build/power-validation/bag-mode-matrix-$(date -u +%Y%m%dT%H%M%SZ)
```

The scaffold intentionally contains `TODO` manifest rows and should fail the
verifier until the rows are replaced with evidence, concrete N/A reasons, or
concrete deferrals.

Before attaching a matrix evidence root, run:

```sh
scripts/bag-mode-primitive-matrix-verify.sh --manifest .build/power-validation/bag-mode-matrix/matrix-manifest.tsv
```

This checks manifest and evidence completeness only. The verifier also rejects
manifests with no evidence rows. It does not prove the primitive is reliable.
After the matrix is attached to #29, update the readiness docs with the
pass/fail/inconclusive result before production Bag Mode implementation begins.

## Temperature Provider Harness

Use the non-destructive temperature-provider harness for #7 safety-source checks:

```sh
scripts/temperature-provider-validation.sh --output-dir .build/temperature-provider-validation/local-$(date -u +%Y%m%dT%H%M%SZ)
```

The harness writes `validation-config.txt`, command outputs, command status files, and `summary.md`. It never uses sudo and must not mark `bagModeTemperatureProviderReady=true`; production provider readiness requires the no-membership helper follow-up.

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

To run a no-prompt `powermetrics` proof attempt package:

```sh
scripts/temperature-provider-powermetrics-proof.sh \
  --output-dir .build/temperature-provider-proof/powermetrics-attempt-$(date -u +%Y%m%dT%H%M%SZ)
```

The proof-attempt harness is non-mutating and uses `sudo -n` only. On machines
without helper/root-equivalent authorization, it records permission evidence and
leaves the real proof rows as `TODO`, so verifier failure is expected.

To build the no-membership `SMAppService` provider candidate without changing
helper registration state:

```sh
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/smappservice-prepare-$(date -u +%Y%m%dT%H%M%SZ)
```

The default mode builds an ad-hoc signed app/helper bundle whose LaunchDaemon
helper runs one timeout-bounded `powermetrics` sample after registration and
approval. New artifacts default to `powermetrics --show-initial-usage -n 1 -i
1000 --samplers thermal`; set
`CLAWSHELL_TEMPERATURE_PROVIDER_SHOW_INITIAL_USAGE=false` only for comparison
runs against the earlier command shape. Set
`CLAWSHELL_TEMPERATURE_PROVIDER_POWERMETRICS_SAMPLERS=<samplers>` before
creating the artifact to compare root-owned sampler variants such as `all`,
`default`, `cpu_power`, or `thermal,cpu_power`. New artifacts derive a unique
SMAppService bundle/helper identity from the output path to avoid stale
approval/code-signing state; set
`CLAWSHELL_TEMPERATURE_PROVIDER_ID_SUFFIX=<lettersAndDigits>` only when a
deterministic comparison identity is needed. Mutating registration uses the
same prepared artifact and requires:

```sh
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/<same-smappservice-provider-artifact> \
  --register \
  --i-understand-this-registers-provider
```

After approval, append non-mutating provider output from the same artifact with:

```sh
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/<same-smappservice-provider-artifact> \
  --capture-post-approval
```

The append mode captures helper runtime context, powermetrics output/status,
`launchctl`, and unified logs. It does not promote manifest rows automatically;
review the captured output before mapping it to provider proof rows.

After cleanup approval, unregister the same prototype helper with:

```sh
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/<same-smappservice-provider-artifact> \
  --capture-unregister \
  --i-understand-this-registers-provider
```

This calls `unregister()` from the existing app bundle and records follow-up
status, `launchctl`, and unified log output.

Use the non-mutating provider proof scaffold when starting a new #25 evidence
package:

```sh
scripts/temperature-provider-proof-scaffold.sh \
  --output-dir .build/temperature-provider-proof/local-$(date -u +%Y%m%dT%H%M%SZ)
```

The scaffold is not evidence. It intentionally omits `validation-config.txt`
and `manual-result.md`, and required manifest rows start as `TODO`, so it should
fail the verifier until real helper/root provider evidence is captured.

The verifier checks that `validation-config.txt`, `manual-result.md`, and the
TSV manifest contain rows/fields for helper-owned numeric provider evidence,
freshness within 10s, 5s/30s cadence, 1s timeout, prompt-free sampling,
ProcessInfo as supplemental-only, closed-bag coverage, fail-closed cases, logs,
and conditional combined-signal evidence. It is a structural gate only; it does
not select a provider or run privileged sampling.

## Helper Service Readiness Harness

Use the non-mutating helper readiness harness before attempting a helper prototype:

```sh
scripts/helper-service-readiness.sh --output-dir .build/helper-service-readiness/local-$(date -u +%Y%m%dT%H%M%SZ)
```

The harness records code-signing identity count and local tool availability. It
also distinguishes the active `xcode-select` developer directory from a full
Xcode install discovered under `/Applications`, because Xcode can be installed
while the active developer directory still points at Command Line Tools. It does
not install, register, approve, unregister, or run a helper.

Use the helper prototype evidence verifier before attaching #27 evidence:

```sh
scripts/helper-service-prototype-verify.sh \
  --manifest .build/helper-service-prototype/<case-id>/prototype-manifest.tsv
```

To build the no-membership `SMAppService` candidate package without changing
helper registration state:

```sh
scripts/helper-service-smappservice-prototype.sh \
  --output-dir .build/helper-service-prototype/smappservice-prepare-$(date -u +%Y%m%dT%H%M%SZ)
```

The default mode is intentionally incomplete evidence: it builds an ad-hoc
signed app/helper bundle and captures layout/signing/status outputs plus
dry-run command parser smoke output for `status`, `enableBagMode`,
`disableBagMode`, `repair`, and `uninstall`, but leaves the required
`fixed-command-api`, registration, approval, reboot, update, uninstall, and
failure-case rows as `TODO`. Registration requires an explicit acknowledgement flag:
`--register --i-understand-this-registers-helper`.
New artifacts derive a unique SMAppService bundle/helper identity from the
output path, and write it to `appBundleIdentifier`, `helperLabel`, and
`identitySuffix` in `validation-config.txt`. Set
`CLAWSHELL_HELPER_PROTOTYPE_ID_SUFFIX=<lettersAndDigits>` only when a
deterministic comparison identity is needed.

After any required System Settings approval, append non-mutating status evidence
to the same artifact directory:

```sh
scripts/helper-service-smappservice-prototype.sh \
  --output-dir .build/helper-service-prototype/<same-smappservice-register-artifact> \
  --capture-post-approval
```

The append mode captures controller status, `launchctl` state, helper runtime
logs, and unified logs. It does not call `register()` or `unregister()`, and it
does not promote manifest rows automatically; review the captured output before
turning any `TODO` row into evidence.

After cleanup approval, append mutating unregister evidence to the same artifact
directory:

```sh
scripts/helper-service-smappservice-prototype.sh \
  --output-dir .build/helper-service-prototype/<same-smappservice-register-artifact> \
  --capture-unregister \
  --i-understand-this-registers-helper
```

This cleanup mode calls `unregister()` from the existing app bundle, then
captures follow-up `status`, `launchctl`, and unified log evidence. It does not
promote manifest rows automatically. Review the captured output before mapping
it to `helper-uninstall`, `helper-uninstall-state-cleanup`, and the manual
uninstall fields, then run the verifier.

Use the non-mutating prototype scaffold when starting a new #27 evidence
package:

```sh
scripts/helper-service-prototype-scaffold.sh \
  --output-dir .build/helper-service-prototype/local-$(date -u +%Y%m%dT%H%M%SZ)
```

The scaffold is not evidence. It intentionally omits `validation-config.txt`
and `manual-result.md`, and required manifest rows start as `TODO`, so it should
fail the verifier until real helper evidence is captured.

The verifier checks `validation-config.txt`, `manual-result.md`, and the TSV
manifest for the required app/helper signing or local auth model, `SMAppService` or fallback install path, approval,
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
