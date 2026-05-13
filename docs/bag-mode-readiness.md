# Bag Mode Readiness

Bag Mode is blocked until the primitive, helper, and safety-provider spikes produce concrete evidence. This page is the operator checklist for issue #7.

## Current Blockers

As of the May 13, 2026 local evidence, production Bag Mode remains blocked by
three evidence issues:

| Issue | Current local state | Next operator action |
|---|---|---|
| [#29](https://github.com/makeavish/ClawShell/issues/29) primitive matrix | Real hardware `pmset disablesleep` matrix evidence is still missing. | Run the primitive matrix on target hardware, fill `manual-result.md`, verify the manifest, and attach pass/fail/inconclusive evidence. |
| [#27](https://github.com/makeavish/ClawShell/issues/27) no-membership helper prototype | `.build/helper-service-readiness/recheck-20260512T105510Z` records full Xcode/tooling available, Developer ID Application identities = 0, Developer ID Installer identities = 0, and `signedPrototypeReady=false`. `.build/helper-service-prototype/smappservice-register-stdout-20260513T040749Z` records a fresh ad-hoc `SMAppService` helper reaching enabled status, launchd `runs = 1`, root helper stdout with `uid=0`/`euid=0`, mirrored `bagModeHelperLedgerSample` JSON, root ledger `0600`, and unregister cleanup to status raw `0` / launchctl service-not-found. Reviewed fixed-command API artifacts now cover approved dry-run dispatch for `status`, `enableBagMode`, `disableBagMode`, `repair`, and `uninstall`; each recorded root execution, emitted mirrored ledger JSON, and unregistered cleanly. Post-approval status, launchctl, stdout-log, unified-log, and root-ledger schema/ownership evidence is reviewed for the local dry-run bootstrap boundary. CLI helper status/repair/uninstall command routing is automated as control-socket outcome evidence. Developer ID membership is intentionally deferred. | Complete the remaining #27 verifier proof: admin approval/password flow, reboot, update, production restore conflict behavior, production repair/uninstall behavior, failure cases, and helper-owned Bag Mode state cleanup before deciding whether fallback LaunchDaemon evidence is needed. |
| [#25](https://github.com/makeavish/ClawShell/issues/25) thermal provider proof | The unique no-membership `SMAppService` helper artifacts provide root-runtime evidence after approval, but are not verifier-accepted provider proof. `powermetrics --samplers thermal` captured only thermal pressure before timing out, `--samplers all` timed out at 1s, and the 5s `all` diagnostic has no trustworthy numeric temperature when interpreted with the hardened detector. The bounded `ioreg-smc` helper now runs as root through SMAppService without timing out, but the visible numeric candidates are under `AppleSmartBattery` and are rejected as production cutoff candidates. The refreshed alternate-source probe has no accepted non-battery numeric candidate. The explicit `ioreg-pmu` proof-attempt path now also runs as root through SMAppService, but sees PMU sensor names with no numeric readings. | Find a better helper-owned source, then capture provider freshness, cadence, timeout, coverage, and fail-closed evidence. |

Readiness harnesses, scaffolds, and verifier success are support gates only.
They do not close #7 without the real evidence above.

## Primitive Validation

`pmset disablesleep` is still only a candidate primitive. Start with a baseline-only capture:

Current artifact: [Bag Mode Primitive Matrix](bag-mode-primitive-matrix.md).

PR #22 added the primitive validation harness, but the candidate primitive is not proven. The real hardware reliability matrix is tracked in [#29](https://github.com/makeavish/ClawShell/issues/29).

```sh
scripts/bag-mode-primitive-validation.sh --case-id apple-silicon-battery-internal
```

The baseline run does not change power settings. It creates:

- `validation-config.txt`
- `manual-result.md`
- `before/` power snapshot

Only run the mutating lid-close window when the target hardware scenario is ready:

```sh
sudo scripts/bag-mode-primitive-validation.sh \
  --case-id apple-silicon-battery-internal \
  --hold-seconds 300 \
  --apply \
  --i-understand-this-changes-power-settings
```

Mutating mode requires root so rollback cannot stall on an expired sudo prompt. It records the prior `disablesleep` value, applies `/usr/bin/pmset disablesleep 1`, captures `during-applied/`, waits for the manual lid-close/reopen window, captures `after-lid-window/`, and restores the prior `disablesleep` value. On macOS versions where `pmset -g custom` omits the `disablesleep` row until it is customized, the harness treats the missing row as the default/off value `0` for rollback.

If you started with a baseline-only directory, rerun that exact directory:

```sh
sudo scripts/bag-mode-primitive-validation.sh \
  --output-dir .build/power-validation/<baseline-case-dir> \
  --case-id apple-silicon-battery-internal \
  --hold-seconds 300 \
  --apply \
  --continue \
  --i-understand-this-changes-power-settings
```

The harness preserves the original `before/` snapshot, refreshes
`validation-config.txt` to `mode=apply` with the captured prior `disablesleep`
value, replaces the baseline README with the mutating run handoff, and then
writes the remaining apply-mode snapshots.

For reboot-while-held scenarios, use a dedicated evidence directory and run the explicit reboot mode:

```sh
sudo scripts/bag-mode-primitive-validation.sh \
  --case-id apple-silicon-battery-reboot-held \
  --apply \
  --reboot-held \
  --i-understand-this-changes-power-settings
```

The script writes `ROLLBACK_REQUIRED.txt` before exiting and intentionally does not roll back before reboot. After the Mac restarts, capture state before rollback, restore the prior value listed in that file, and capture rollback state:

```sh
CLAWSHELL_PMSET_REDACT_METADATA=1 scripts/pmset-snapshot.sh <evidence-dir>/post-reboot
sudo /usr/bin/pmset disablesleep <prior value>
CLAWSHELL_PMSET_REDACT_METADATA=1 scripts/pmset-snapshot.sh <evidence-dir>/after-rollback
```

The harness redacts host/user metadata by default. Fill in `manual-result.md`, attach the evidence directory to issue #29, and summarize or cross-link the result on issue #7. Every primitive matrix case must include reboot state or an explicit `N/A` reason in `manual-result.md`.

## Required Matrix

| Dimension | Required coverage |
|---|---|
| macOS | 13, 14, 15+ where available |
| CPU | Apple Silicon and Intel if Intel support remains in scope |
| Power | AC and battery |
| Display | Internal only, external display, no external display |
| Lid | Open, closed, reopen recovery |
| Primitive lifecycle now | app quit, app crash, reboot while held |
| Helper lifecycle after #27 | helper restart, helper upgrade mid-hold |

Each case must record the exact command applied, rollback command, `pmset -g custom`, `pmset -g assertions`, available IORegistry state, lid-close result, and reboot state when relevant.

## Helper Spike

The helper proof must answer whether Bag Mode can use a local/admin-approved
helper without Apple Developer Program membership. `SMAppService` LaunchDaemon
is still the preferred first target; the latest ad-hoc no-membership helper
artifact reached enabled status and bootstrapped as root, so fallback
LaunchDaemon evidence is not justified by the earlier approval-pending register
state alone. Homebrew cask install/upgrade/uninstall semantics are a related
packaging gate unless the prototype is exercised through a cask-installed app.

Current artifact: [Helper Service Readiness](helper-service-readiness.md).

The May 12, 2026 source/readiness check kept `SMAppService` as the source-backed
first target to prototype. Full Xcode is now detected from
`/Applications/Xcode.app` even when the active `xcode-select` directory points
at Command Line Tools, but this local environment has no Developer ID signing
identities and the product plan defers Apple Developer Program membership until
traction or donations justify it. The May 13, 2026 no-membership
`SMAppService` helper artifact
`.build/helper-service-prototype/smappservice-register-stdout-20260513T040749Z`
reached enabled status, was submitted by ServiceManagement, recorded root
execution, and wrote a readable stdout mirror containing
`bagModeHelperLedgerSample`. A
later cleanup capture called `unregister()` successfully, moved status from raw
`1` to raw `0`, and left `launchctl` unable to find the daemon. A follow-up
command-specific artifact,
`.build/helper-service-prototype/smappservice-command-enableBagMode-pending-20260513T051953Z`,
also reached enabled status and ran `enableBagMode` once as root in dry-run
mode with `uid=0`, `euid=0`, launchd `runs = 1`, exit code `0`, mirrored
ledger JSON, and clean unregister evidence. After waiting at least 15 seconds
for approval propagation, follow-up artifacts for `disableBagMode`, `repair`,
and `uninstall` also reached enabled status, ran once as root in dry-run mode,
emitted mirrored ledger JSON, and unregistered cleanly back to raw `0`. The
reviewed command set now covers the fixed-command API row boundary for dry-run
dispatch only. The status, launchctl, stdout-log, and unified-log captures also
cover the local post-approval bootstrap boundary. The mirrored
`bagModeHelperLedgerSample` plus root-owned `0600` ledger file evidence covers
the dry-run root-ledger schema/ownership boundary. The required #27 prototype
still needs the rest of the lifecycle evidence rather than another
bootstrap-only, dry-run-command, ledger-shape-only, or unregister-only capture,
including admin approval/password flow evidence because these artifacts do not
prove which System Settings UI was shown before enablement.

Before attaching a helper prototype package, run:

```sh
scripts/helper-service-prototype-verify.sh \
  --manifest .build/helper-service-prototype/<case-id>/prototype-manifest.tsv
```

This verifies evidence structure only. The prototype still requires a real
app/helper bundle or fallback helper install package, admin approval or password
flow, production restore conflict behavior, production repair/uninstall
behavior, reboot, update, failure-case, helper-owned Bag Mode state cleanup, and
optional cask/package evidence. CLI helper status/repair/uninstall command
outcomes are covered by the control-router tests, but production helper-backed
repair and uninstall behavior remains open.

Required notes:

- Bundle layout and launchd label
- App/helper local signing/auth model, and Developer ID designated requirements only when available
- XPC or Mach service name
- Caller audit-token validation result
- Install, update, uninstall, and repair commands tested
- What happens when the caller is unsigned, wrong bundle id, wrong user, or stale app version
- Root-owned ledger path, owner, file mode, schema, and sample contents
- Restore behavior when current values match `expectedCurrentValues`
- Conflict behavior when user/system settings changed after ClawShell
- App launch reconciliation against a stale helper ledger
- Helper launch reporting for stale-held state
- Helper upgrade mid-hold behavior
- `clawshell helper status`, `clawshell helper repair`, and `clawshell uninstall --remove-helper --remove-integrations` outcomes

Non-Developer-ID public builds may expose Bag Mode only after the local/ad-hoc signed and hash/pairing-pinned helper path passes real validation and the UI labels the local helper trust model clearly. Truly unsigned helper experiments stay development-only.

## Temperature Provider Spike

The provider proof must choose a fresh, permission-compatible temperature source for Bag Mode.

Current artifact: [Temperature Provider Check](temperature-provider-check.md).

The May 12, 2026 non-root source check did not select a production provider. `ProcessInfo.thermalState` remains a supplemental coarse signal, `pmset -g therm` did not provide current numeric temperature evidence, and AppleSmartBattery temperature did not prove closed-bag coverage or freshness. Later no-membership `SMAppService` provider runs proved that an ad-hoc helper can launch as root on this machine. The tested `powermetrics` sampler variants did not provide a trustworthy numeric cutoff source. The bounded `ioreg-smc` diagnostic source now runs as root through SMAppService without timing out, but its visible numeric candidates are under `AppleSmartBattery`; new proof attempts reject those battery-context values as production cutoff candidates. The explicit `ioreg-pmu` diagnostic source runs `/usr/sbin/ioreg -r -c AppleARMPMUTempSensor -l`; the helper-owned SMAppService PMU run completed without timing out, but saw no numeric candidates. The refreshed alternate-source probe also has no accepted non-battery numeric candidate. Helper-side provider validation is tracked in [#25](https://github.com/makeavish/ClawShell/issues/25).

Before attempting helper/root sampling, run the non-mutating preflight:

```sh
scripts/temperature-provider-helper-readiness.sh \
  --output-dir .build/temperature-provider-helper-readiness/<case-id>
```

The preflight records whether helper-equivalent `powermetrics` sampling can run
without a user-visible prompt. It does not prove provider freshness, cadence,
closed-bag coverage, fail-closed behavior, or reliability.

To create a no-prompt `powermetrics` proof-attempt package, run:

```sh
scripts/temperature-provider-powermetrics-proof.sh \
  --output-dir .build/temperature-provider-proof/powermetrics-attempt-$(date -u +%Y%m%dT%H%M%SZ)
```

This records the command path, helper/root-equivalent permission behavior,
timeout behavior, ProcessInfo supplemental state, and numeric output when
available. If non-interactive root/helper authorization is unavailable, the
artifact is intentionally incomplete and should fail the structural verifier
until real helper/root samples, cadence, coverage, and fail-closed evidence are
attached.

To inventory non-`powermetrics` source candidates without sudo, run:

```sh
scripts/temperature-provider-alt-source-probe.sh \
  --output-dir .build/temperature-provider-proof/alt-source-probe-$(date -u +%Y%m%dT%H%M%SZ)
```

This captures SMC, PMU temperature sensor, die temperature controller, and
IOReport-style discovery evidence. It separates accepted numeric candidates
from rejected battery-context candidates. It does not prove helper ownership or
select a numeric cutoff source.

To build the no-membership `SMAppService` provider candidate without changing
helper registration state, run:

```sh
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/smappservice-prepare-$(date -u +%Y%m%dT%H%M%SZ)
```

New artifacts default to `powermetrics --show-initial-usage -n 1 -i 1000
--samplers thermal` for reproducible comparison with existing evidence. On this
machine, the tested `powermetrics` variants have not produced a trustworthy
numeric cutoff source under the provider contract, so treat further
`powermetrics` runs as comparison/diagnostic work. To compare root-owned sampler
variants without hand-editing the helper, set
`CLAWSHELL_TEMPERATURE_PROVIDER_POWERMETRICS_SAMPLERS=<samplers>` before
creating the artifact, for example `all`, `default`, `cpu_power`, or
`thermal,cpu_power`.

To test the helper-owned I/O Registry SMC diagnostic source, create the artifact
with `CLAWSHELL_TEMPERATURE_PROVIDER_SOURCE=ioreg-smc`. That mode runs
`/usr/sbin/ioreg -r -c AppleSMCKeysEndpoint -l` from the approved helper. The
current SMAppService artifact runs that bounded source as root within the 1
second timeout, but the observed numeric candidates are under
`AppleSmartBattery`. New proof attempts reject those candidates for production
cutoff evidence and must promote a better helper-owned source before #25 can
close.

To test the PMU I/O Registry inventory path, create the artifact with
`CLAWSHELL_TEMPERATURE_PROVIDER_SOURCE=ioreg-pmu`. That mode runs
`/usr/sbin/ioreg -r -c AppleARMPMUTempSensor -l`. On this machine the direct
generated-helper run completed within the timeout with
`numericTemperatureCandidateCount=0`, and the approved SMAppService PMU run
also launched as root with `numericTemperatureCandidateCount=0`.

Each artifact also gets a unique SMAppService identity derived from its output
path so repeated ad-hoc attempts do not reuse stale approval/code-signing state.

Mutating registration uses the same prepared artifact and requires:

```sh
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/<same-smappservice-provider-artifact> \
  --register \
  --i-understand-this-registers-provider
```

After macOS approval, wait at least 15 seconds, then append helper-owned provider
output to the same artifact with:

```sh
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/<same-smappservice-provider-artifact> \
  --capture-post-approval
```

The append mode captures helper runtime context, provider output/status,
`launchctl`, and unified logs without auto-promoting manifest rows.

After cleanup approval, unregister the same prototype helper with:

```sh
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/<same-smappservice-provider-artifact> \
  --capture-unregister \
  --i-understand-this-registers-provider
```

This records follow-up status, `launchctl`, and unified log output for cleanup.

The mocked fail-closed safety contract is covered in `BagModeSafetyPolicy` and `ClawShellCoreChecks`: warning, cutoff, stale, unavailable, permission-denied, parse-failed, helper-crashed, unsupported-hardware, timeout, insufficient closed-bag coverage, missing/invalid battery, battery floor, and hysteresis transitions are executable checks. This does not select or validate the no-membership helper temperature provider.

Before attaching helper provider proof, run:

```sh
scripts/temperature-provider-proof-verify.sh \
  --manifest .build/temperature-provider-proof/<case-id>/provider-manifest.tsv
```

This verifies evidence structure only. The provider still needs real
helper/helper-equivalent samples for source, freshness, cadence, timeout,
permission behavior, fail-closed behavior, and closed-bag coverage.

Required notes:

- Numeric cutoff source tested: `ioreg-smc`, SMC, `powermetrics`, IOReport, or other helper-owned source
- `ProcessInfo.thermalState` role: supplemental-only
- Permission prompt or root requirement
- Reading freshness and timeout behavior
- Parse failure behavior
- Whether the reading covers closed-bag thermal risk well enough
- Recorded max reading age against the 10 second freshness requirement
- 1 second command timeout behavior
- Feasibility of 5 second active sampling and 30 second idle sampling
- Stale, unavailable, permission-denied, and parse-failed cases
- Evidence that fail-closed behavior blocks Bag Mode before arming or releases it when armed

Thermal cutoff tests must use mocks or simulated providers. Do not intentionally overheat hardware.

## Codex Early Signal Recheck

Re-check Codex source/docs for any supported signal before `notify`. If no earlier lifecycle signal exists, keep the current process-detected semantics with `notify` only marking turn completion.

Current artifact: [Codex Early Signal Check](codex-early-signal-check.md).

The May 12, 2026 source check found upstream Codex hook events before legacy `notify`: `SessionStart`, `UserPromptSubmit`, and tool hooks provide earlier native lifecycle signals, while `Stop` is a native completion signal before legacy `notify`. ClawShell now installs redaction-safe native Codex hooks while preserving legacy `notify` and process detection as fallback paths. See [Codex Native Hooks](codex-native-hooks.md).

Required artifact:

- Source/docs URLs or repository commit checked
- Check date
- Search terms and files inspected
- Observed `notify` semantics
- Any candidate earlier lifecycle signal found or rejected
- Final conclusion
- Linked TDD update or follow-up issue, if behavior changed or remains blocked

## Issue #7 Closeout

Issue #7 is not complete until every failed or inconclusive primitive, helper, temperature, or Codex assumption has either:

- an updated TDD finding, or
- a linked follow-up issue with the blocking evidence.

Follow-up issues are blocker tracking, not proof. The primitive path remains open until #29 records pass/fail/inconclusive hardware evidence and the TDD/readiness docs are updated.
