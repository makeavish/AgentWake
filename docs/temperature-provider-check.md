# Temperature Provider Check

Check date: May 12, 2026

Issue: [#7](https://github.com/makeavish/ClawShell/issues/7)

Follow-up: [#25](https://github.com/makeavish/ClawShell/issues/25)

App-side artifact: `.build/temperature-provider-validation/local-20260512T023358Z`

Helper-equivalent preflight artifact: `.build/temperature-provider-helper-readiness/recheck-20260512T100451Z`

SMAppService provider artifact: `.build/temperature-provider-proof/smappservice-real-20260512T163358Z`

## Question

Which fresh, permission-compatible temperature source is reliable enough for Bag Mode cutoff decisions?

## Method

Added `scripts/temperature-provider-validation.sh`, a non-destructive harness that does not use sudo and does not intentionally heat hardware.

Command used:

```bash
scripts/temperature-provider-validation.sh --output-dir .build/temperature-provider-validation/local-20260512T023358Z
```

Sources tested:

- Apple `ProcessInfo.thermalState`
- `pmset -g therm`
- `powermetrics -n 1 -i 1000 --samplers thermal`
- AppleSmartBattery top-level I/O Registry temperature and update fields

Reference:

- [Apple ProcessInfo.ThermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate)

## Local Result

| Source | Permission behavior | Freshness/timeout behavior | Numeric temperature | Closed-bag coverage | Result |
|---|---|---|---|---|---|
| `ProcessInfo.thermalState` | Works without root | Harness probe returned within 5s probe timeout; app API is not a shell command | No | Closed-bag coverage not proven; app-side coarse thermal-pressure/liveness signal only | Supplemental signal only |
| `pmset -g therm` | Works without root | Returned within the 1s command timeout | No current numeric temperature in this run | Warning history/status, not a sensor source | Not a cutoff provider |
| `powermetrics --samplers thermal` | Refused non-root execution with `powermetrics must be invoked as the superuser` | Returned within the 1s command timeout when non-root | Not available without root | Not validated in this artifact | Follow-up required |
| AppleSmartBattery I/O Registry fields | Works without root when battery service exists | Returned within the 1s command timeout; update age was 12s in this run, above the 10s freshness target | Battery pack/virtual values were present | Battery temperature does not prove CPU/package or closed-bag thermal coverage | Context only |
| SMAppService helper `powermetrics --samplers thermal` | Ad-hoc/no-membership helper launched as root | Helper hit the 1s timeout before a complete sample | No numeric temperature observed | Not validated; no cutoff signal captured | Helper path viable, command not proven |

Captured values from `validation-config.txt`:

```text
processInfoThermalState=nominal
processInfoNumericTemperature=false
pmsetCurrentNumericTemperature=false
pmsetThermTimedOut=false
pmsetThermExitCode=0
powermetricsPermissionState=requiresRoot
powermetricsTimedOut=false
powermetricsExitCode=1
batteryTemperatureCelsius=31.95
batteryVirtualTemperatureCelsius=45.75
batteryUpdateAgeSeconds=12
batteryFreshWithin10Seconds=false
candidateSelected=none
bagModeTemperatureProviderReady=false
```

## Failure Behavior

Production Bag Mode must fail closed for:

- provider unavailable
- stale reading
- permission denied
- parse failure
- helper crash or timeout
- unsupported hardware

The harness records these as evidence fields but does not enable production behavior.

The mocked fail-closed contract is now executable in `BagModeSafetyPolicy` and covered by the portable `ClawShellCoreChecks` gate. Those checks cover warning, cutoff, stale, unavailable, permission-denied, parse-failed, helper-crashed, unsupported-hardware, timeout, coverage-insufficient, missing/invalid battery, battery floor, and hysteresis behavior. They do not select a production provider or prove helper-side sampling.

## Helper-Equivalent Readiness

Added `scripts/temperature-provider-helper-readiness.sh`, a non-mutating
preflight for the helper/root sampling path. It never prompts for sudo. When
the current user is not root, it uses `sudo -n` only so missing authorization is
recorded as evidence instead of blocking the run.

Command used:

```bash
scripts/temperature-provider-helper-readiness.sh --output-dir .build/temperature-provider-helper-readiness/recheck-20260512T100451Z
```

Captured values from `validation-config.txt`:

```text
hardwareArch=arm64
runningAsRoot=false
effectiveUserIdRedacted=true
batteryPresent=true
powermetricsAvailable=true
sudoNonInteractiveAvailable=false
powermetricsHelperPermissionState=sudoPasswordRequired
powermetricsHelperTimedOut=false
powermetricsHelperExitCode=1
numericTemperatureOutput=false
helperSamplingCandidateAvailable=false
providerProofReady=false
```

This preflight explained the earlier non-interactive shell blocker. The later
SMAppService run below moved past that blocker by launching the provider helper
as root; the current local blocker is now provider output quality, not helper
authorization.

## No-Membership SMAppService Provider Run

The no-membership `SMAppService` provider artifact
`.build/temperature-provider-proof/smappservice-real-20260512T163358Z`
registered, reached enabled state, launched once as a system LaunchDaemon, and
unregistered cleanly.

Relevant lifecycle evidence:

```text
statusAfterRegisterRaw=2
statusAfterApprovalRaw=1
launchctlRuns=1
helperRuntimeUid=0
helperRuntimeEuid=0
unregisterStatusBeforeRaw=1
unregisterStatusAfterRaw=0
launchctlAfterUnregister=service-not-found
```

The helper runtime proved root ownership, but the selected command did not
produce a usable numeric provider sample under the required deadline:

```text
command=/usr/bin/powermetrics -n 1 -i 1000 --samplers thermal
timeoutSeconds=1
timedOut=true
durationSeconds=2
helperOwned=true
numericTemperatureObserved=false
```

This is useful evidence for the helper mechanism, not proof of a production
temperature provider. The next #25 work should test a faster helper-owned
source or a different command shape before attempting freshness, cadence,
closed-bag coverage, and fail-closed evidence.

## Conclusion

No production Bag Mode temperature provider is selected from the non-root app-side sources tested.

`ProcessInfo.thermalState` is permission-compatible and useful as a supplemental app-side thermal-pressure/liveness signal, but it is coarse, non-numeric, and does not prove closed-bag coverage. `pmset -g therm` did not provide current numeric temperature evidence. AppleSmartBattery temperature is useful context when present, but it is not enough for CPU/package or closed-bag thermal risk and did not meet the 10 second freshness target in the local run. The no-membership `SMAppService` path can launch a helper as root on this machine, but the tested `powermetrics --samplers thermal` command timed out under the 1 second provider deadline without numeric output; [#25](https://github.com/makeavish/ClawShell/issues/25) must still prove helper/root numeric output, freshness, cadence, timeout, and coverage.

Production Bag Mode remains blocked until [#25](https://github.com/makeavish/ClawShell/issues/25) validates a no-membership helper or helper-equivalent provider that can supply fresh, permission-compatible thermal evidence with the required fail-closed behavior.

## Helper Provider Proof Verifier

Before attaching helper/helper-equivalent provider proof to #25, run:

```bash
scripts/temperature-provider-proof-verify.sh \
  --manifest .build/temperature-provider-proof/<case-id>/provider-manifest.tsv
```

To capture the first no-prompt `powermetrics` proof attempt without waiting for
an interactive helper/root flow, run:

```bash
scripts/temperature-provider-powermetrics-proof.sh \
  --output-dir .build/temperature-provider-proof/powermetrics-attempt-$(date -u +%Y%m%dT%H%M%SZ)
```

This package records the prompt-free `powermetrics` attempt, permission state,
timeout behavior, ProcessInfo supplemental state, and numeric output if
available. On the current machine, non-interactive sampling still records
`sudoPasswordRequired`, so the package remains incomplete proof until helper or
root-equivalent sampling is available.

To build the no-membership `SMAppService` provider candidate without changing
helper registration state, run:

```bash
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/smappservice-prepare-$(date -u +%Y%m%dT%H%M%SZ)
```

The default mode builds an ad-hoc signed app/helper bundle whose LaunchDaemon
helper runs one timeout-bounded `powermetrics` sample after registration and
approval. New artifacts default to `powermetrics --show-initial-usage -n 1 -i
1000 --samplers thermal` so the next run can test whether an initial sample
finishes inside the 1 second provider deadline; set
`CLAWSHELL_TEMPERATURE_PROVIDER_SHOW_INITIAL_USAGE=false` only when comparing
against the earlier timed-out command shape. Mutating registration uses the same
prepared artifact and requires:

```bash
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/<same-smappservice-provider-artifact> \
  --register \
  --i-understand-this-registers-provider
```

After approval, append non-mutating provider output from the same artifact with:

```bash
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/<same-smappservice-provider-artifact> \
  --capture-post-approval
```

The append mode captures helper runtime context, `powermetrics` output/status,
`launchctl`, and unified logs. It does not promote manifest rows automatically;
review the captured output before mapping it to provider proof rows.

After cleanup approval, unregister the same prototype helper with:

```bash
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/<same-smappservice-provider-artifact> \
  --capture-unregister \
  --i-understand-this-registers-provider
```

This records follow-up status, `launchctl`, and unified log output for cleanup.

To start the package layout without inventing rows by hand, generate a
non-mutating scaffold:

```bash
scripts/temperature-provider-proof-scaffold.sh \
  --output-dir .build/temperature-provider-proof/<case-id>
```

The scaffold is not evidence. It intentionally omits `validation-config.txt`
and `manual-result.md`, and writes `TODO` manifest rows so the verifier fails
until real helper/root provider output is captured.

The verifier expects three files at the manifest root:

- `validation-config.txt`
- `manual-result.md`
- `provider-manifest.tsv`

`validation-config.txt` must record the machine-readable proof shape:

```text
evidenceFormat=temperature-provider-proof-v1
metadataRedacted=true
macOSVersion=15.0
cpu=Apple Silicon
hardwareClass=MacBook
providerSource=powermetrics
helperOwned=true
processInfoSupplementalOnly=true
numericCutoffSource=true
noUserVisiblePrompts=true
freshnessMaxAgeSeconds=10
activeCadenceSeconds=5
idleCadenceSeconds=30
timeoutSeconds=1
closedBagCoverage=requires-combined-signals
failClosedContract=covered
result=inconclusive
```

`manual-result.md` must use filled checklist fields:

```markdown
# Temperature Provider Proof Result

## Provider Case
- Case ID: apple-silicon-powermetrics-helper
- Provider source: powermetrics
- Helper-owned provider: yes
- Numeric cutoff source: yes
- No user-visible prompts: yes
- ProcessInfo role: supplemental-only

## Sampling
- Freshest reading age seconds: 4
- Active cadence seconds: 5
- Idle cadence seconds: 30
- Timeout seconds: 1

## Coverage
- Closed-bag coverage: requires-combined-signals
- Fail-closed cases recorded: yes

## Conclusion
- Result: inconclusive
```

The verifier compares `manual-result.md` against `validation-config.txt` for
provider source, freshness, cadence, timeout, closed-bag coverage, and result.

`provider-manifest.tsv` must use this tab-separated header:

```tsv
checkId	status	evidencePath	note
```

Required manifest `checkId` rows:

- `provider-command-or-api`
- `helper-ownership-context`
- `numeric-temperature-output`
- `freshness-samples`
- `active-cadence-samples`
- `idle-cadence-samples`
- `timeout-enforcement`
- `timeout-fail-closed`
- `permission-behavior`
- `no-user-visible-prompts`
- `closed-bag-coverage-analysis`
- `processinfo-supplemental-signal`
- `safety-contract-tests`
- `unavailable-fail-closed`
- `stale-fail-closed`
- `permission-denied-fail-closed`
- `parse-failed-fail-closed`
- `helper-crashed-fail-closed`
- `unsupported-hardware-fail-closed`
- `logs`

Optional manifest rows are:

- `combined-sensor-signal`, required when `closedBagCoverage=requires-combined-signals`
- `provider-update-or-restart`, when the prototype exercises provider restart/update behavior

Required rows must use `status=evidence`. Optional rows may use
`status=evidence` or `status=n/a` with an explicit note, except
`combined-sensor-signal` must be evidence when
`closedBagCoverage=requires-combined-signals`.

Example manifest row:

```tsv
numeric-temperature-output	evidence	evidence/numeric-temperature-output.txt	captured helper output attached
```

Evidence paths must be relative, non-empty, inside the evidence package, and free
of symlink components. Evidence files must contain real captured output rather
than `TODO`, `<paste output>`, or placeholder text. Verifier success is
structural only; it does not prove the provider is reliable or close #25.
