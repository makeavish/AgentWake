# Temperature Provider Check

Check date: May 14, 2026

Original issue: [#7](https://github.com/makeavish/AgentWake/issues/7)

Final E2E follow-up: [#120](https://github.com/makeavish/AgentWake/issues/120)

App-side artifact: `.build/temperature-provider-validation/local-20260512T023358Z`

Helper-equivalent preflight artifact: `.build/temperature-provider-helper-readiness/recheck-20260512T100451Z`

SMAppService provider artifacts:

- `.build/temperature-provider-proof/smappservice-real-20260512T163358Z`
- `.build/temperature-provider-proof/smappservice-unique-20260512T175157Z`
- `.build/temperature-provider-proof/smappservice-all-20260512T181830Z`
- `.build/temperature-provider-proof/smappservice-all-timeout5-20260512T182146Z`
- `.build/temperature-provider-proof/powermetrics-thermal-cpu-power-20260513T172057Z`
- `.build/temperature-provider-proof/ioreg-smc-prepare-20260513T061711Z`
- `.build/temperature-provider-proof/bounded-ioreg-smc-local`
- `.build/temperature-provider-proof/ioreg-smc-bounded-smappservice-20260513T071633Z`
- `.build/temperature-provider-proof/ioreg-pmu-local-20260513T105941Z`
- `.build/temperature-provider-proof/ioreg-pmu-smappservice-20260513T110017Z`
- `.build/temperature-provider-proof/ioreg-smc-dispatcher-prepare-20260514T041342Z`
- `.build/temperature-provider-proof/thermal-levels-smappservice-20260513T173804Z`
- `.build/temperature-provider-proof/ioreport-ans2-smappservice-20260514T052521Z`

Alternate source probe artifacts:

- `.build/temperature-provider-proof/alt-source-classified-20260513T082121Z`
- `.build/temperature-provider-proof/alt-source-hidutil-20260513T131843Z`
- `.build/temperature-provider-proof/alt-source-nvme-20260513T134806Z`
- `.build/temperature-provider-proof/alt-source-hid-dump-20260513T143454Z`
- `.build/temperature-provider-proof/alt-source-iohid-20260513T150045Z`
- `.build/temperature-provider-proof/alt-source-smc-dispatcher-20260513T154345Z`
- `.build/temperature-provider-proof/alt-source-ioreport-20260514T052351Z`
- `.build/temperature-provider-proof/alt-source-ioreport-unit-field-20260514T075756Z`

## Question

Which fresh, permission-compatible temperature source is reliable enough for Closed-Lid Mode cutoff decisions?

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
| SMAppService helper `powermetrics --samplers thermal` | Ad-hoc/no-membership helper launched as root | Timed out after partial output; captured thermal pressure only | No numeric temperature observed | Not validated; no cutoff signal captured | Helper path viable, command not proven |
| SMAppService helper `powermetrics --samplers all` | Same no-membership helper launched as root | 1s run produced only the command header; 5s diagnostic emitted broad task/power output but still timed out | No trustworthy numeric temperature observed after detector correction | Not validated; no cutoff signal captured | Diagnostic only; command not viable as provider |
| SMAppService helper `powermetrics --samplers thermal,cpu_power` | Same no-membership helper launched as root | 5s diagnostic completed in 2s and produced CPU power/frequency plus thermal pressure output | No numeric temperature candidates observed | Thermal pressure only; no scalar CPU/package cutoff signal captured | Diagnostic only; no cutoff provider selected |
| SMAppService helper `ioreg -r -c AppleSMCKeysEndpoint -l` | Same no-membership helper launched as root | Early 1s run timed out after partial I/O Registry output; later bounded run completed before its timeout | Numeric-looking values were visible, but the accepted-provider detector rejects them as AppleSmartBattery context | Not validated; no freshness/cadence/coverage proof | Diagnostic only; no cutoff provider selected |
| SMAppService helper `ioreg -r -c AppleARMPMUTempSensor -l` | Same no-membership helper launched as root after approval | Helper-owned run completed within the 1s timeout and captured the PMU inventory without truncation | No numeric temperature candidates observed | PMU node names such as `PMU tdev*` are metadata, not readings | Candidate rejected until a real PMU reading API is found |
| SMAppService helper `/usr/bin/thermal levels` | Same no-membership helper launched as root after approval | Completed in 1s under the 1s provider deadline with exit code 69 | No numeric temperature candidates observed | Local command reported unsupported hardware | Diagnostic only; no cutoff provider selected |
| SMAppService helper native `libIOReport` ANS2/MSP probe | Same no-membership helper launched as root after approval | Completed in 1s under the 1s provider deadline with exit code 0 | Four non-battery numeric temperature-like samples observed | Scale and closed-bag coverage are still unverified | Best current candidate; not proof-ready yet |
| Native IOHID service property probe | Works without root in the non-mutating alternate-source harness | Completed inside the 2s probe timeout | No common current-value or numeric value properties observed | HID PMU/NVMe service names only; no scalar reading or coverage proof | Discovery only; no cutoff provider selected |

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

Production Closed-Lid Mode must fail closed for:

- provider unavailable
- stale reading
- permission denied
- parse failure
- helper crash or timeout
- unsupported hardware

The harness records these as evidence fields but does not enable production behavior.

The mocked fail-closed contract is now executable in `BagModeSafetyPolicy` and covered by the portable `AgentWakeCoreChecks` gate. Those checks cover warning, cutoff, stale, unavailable, permission-denied, parse-failed, helper-crashed, unsupported-hardware, timeout, coverage-insufficient, missing/invalid battery, battery floor, and hysteresis behavior. They do not select a production provider or prove helper-side sampling.

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

## No-Membership SMAppService Provider Runs

The no-membership `SMAppService` provider artifact
`.build/temperature-provider-proof/smappservice-unique-20260512T175157Z`
reached the approval/enabled path and produced root-owned runtime evidence from
a system LaunchDaemon with a unique ad-hoc bundle/helper identity. Its register
capture still includes the expected `Operation not permitted` transition before
approval, and it did not capture unregister cleanup.

Relevant lifecycle evidence therefore combines the earlier unregister-capable
`smappservice-real` artifact with the newer unique-identity root-runtime
captures:

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

The helper runtime proved root ownership. With the default `thermal` sampler,
the command produced thermal pressure state but no usable numeric provider
sample:

```text
command=/usr/bin/powermetrics --show-initial-usage -n 1 -i 1000 --samplers thermal
timeoutSeconds=1
timedOut=true
durationSeconds=2
helperOwned=true
numericTemperatureObserved=false
```

The later `.build/temperature-provider-proof/smappservice-all-20260512T181830Z`
artifact used the same helper path with `--samplers all`. It confirmed the
LaunchDaemon arguments and root-owned helper execution, but the 1 second run
timed out before a sampler body was captured. This is runtime-capture evidence,
not verifier-accepted final provider proof:

```text
command=/usr/bin/powermetrics --show-initial-usage -n 1 -i 1000 --samplers all
timeoutSeconds=1
timedOut=true
durationSeconds=2
helperOwned=true
numericTemperatureObserved=false
```

The 5 second diagnostic artifact
`.build/temperature-provider-proof/smappservice-all-timeout5-20260512T182146Z`
emitted broad `powermetrics --samplers all` output, but still timed out and did
not contain a trustworthy numeric temperature reading. Its original
`numericTemperatureObserved=true` was a detector false positive from task-table
output. The artifact still stores that old field value, so the corrected result
is an interpretation from the hardened detector and captured output, not a
promoted artifact row.

The follow-up diagnostic artifact
`.build/temperature-provider-proof/powermetrics-thermal-cpu-power-20260513T172057Z`
kept the same no-membership helper path but narrowed `powermetrics` to
`--samplers thermal,cpu_power` and raised the diagnostic timeout to 5 seconds.
After approval and the required wait, the helper ran as root and the command
completed without timing out:

```text
command=/usr/bin/powermetrics --show-initial-usage -n 1 -i 1000 --samplers thermal,cpu_power
providerSource=powermetrics
timeoutSeconds=5
durationSeconds=2
timedOut=false
exitCode=0
helperOwned=true
stdoutBytes=11295
stdoutTruncated=false
numericTemperatureObserved=false
numericTemperatureCandidateCount=0
powermetricsSamplers=thermal,cpu_power
```

The output contains CPU frequency, CPU/GPU/ANE power, combined power, and
thermal pressure, but no scalar temperature candidate. Cleanup succeeded:
`unregister()` moved status back to raw `0`, and `launchctl` could not find the
service after unregister. Treat this as negative `powermetrics` source evidence,
not provider proof: it uses a diagnostic 5 second timeout rather than the 1
second provider deadline, and it still does not provide a numeric cutoff source,
freshness, cadence, closed-bag coverage, or fail-closed proof.

The later `.build/temperature-provider-proof/ioreg-smc-prepare-20260513T061711Z`
artifact used the same no-membership `SMAppService` path with
`AGENTWAKE_TEMPERATURE_PROVIDER_SOURCE=ioreg-smc`. After registration, approval,
and a wait of at least 15 seconds before post-approval capture, the helper ran as root and
captured partial `AppleSMCKeysEndpoint` output:

```text
command=/usr/sbin/ioreg -r -c AppleSMCKeysEndpoint -l
providerSource=ioreg-smc
timeoutSeconds=1
timedOut=true
exitCode=15
helperOwned=true
numericTemperatureObserved=true
```

This is source-candidate evidence only. The command still timed out under the
current 1 second contract, and the artifact does not prove freshness, cadence,
closed-bag coverage, fail-closed behavior, or a bounded production parser.

The follow-up `.build/temperature-provider-proof/bounded-ioreg-smc-local`
artifact updates the generated helper to write provider stdout/stderr to
temporary files instead of pipes, then read back at most 2,000,000 bytes per
stream. A direct local run of the generated helper binary with
`providerSource=ioreg-smc` completed inside the 1 second timeout:

```text
command=/usr/sbin/ioreg -r -c AppleSMCKeysEndpoint -l
providerSource=ioreg-smc
timeoutSeconds=1
durationSeconds=1
timedOut=false
exitCode=0
stdoutBytes=878324
stdoutTruncated=false
helperOwned=false
numericTemperatureObserved=true
```

This narrows the previous timeout to a pipe-drain bug in the prototype helper,
but it is still not provider proof: the direct run was not root/helper-owned, the
numeric candidates are still battery-context values in the I/O Registry output,
and freshness, cadence, coverage, and fail-closed behavior remain unproven.

The bounded SMAppService artifact
`.build/temperature-provider-proof/ioreg-smc-bounded-smappservice-20260513T071633Z`
then ran the same source through the approved no-membership helper after the
required wait of at least 15 seconds:

```text
command=/usr/sbin/ioreg -r -c AppleSMCKeysEndpoint -l
providerSource=ioreg-smc
timeoutSeconds=1
durationSeconds=1
timedOut=false
exitCode=0
stdoutBytes=878309
stdoutTruncated=false
helperOwned=true
numericTemperatureObserved=true
```

That `numericTemperatureObserved=true` field was recorded before the helper
harness rejected `ioreg-smc` battery-context candidates. New `ioreg-smc`
artifacts treat numeric matches under `AppleSmartBattery` or
`AppleSmartBatteryManager` as rejected cutoff candidates and record
`numericTemperatureRejectionReason=ioreg-smc-battery-context-only` when no
non-battery numeric candidate is present.

Cleanup succeeded: `unregister()` moved status back to raw `0`, and `launchctl`
could not find the service after unregister. The verifier still fails as
expected because manifest rows for freshness, cadence, coverage, and fail-closed
behavior remain `TODO`.

The numeric-looking values in this artifact are under `AppleSmartBattery`:

```text
+-o AppleSmartBatteryManager
  +-o AppleSmartBattery
      "BatteryData" = {...}
      "Temperature" = 3044
      "VirtualTemperature" = 3119
```

That makes the source useful as bounded helper/runtime evidence, but not a
production cutoff provider by itself. Battery-context values still do not prove
CPU/package or closed-bag thermal coverage.

These artifacts are useful evidence for the no-membership helper mechanism and
candidate-source discovery, not proof of a production temperature provider. New
`ioreg-smc` proof attempts reject the battery-context candidates for production
cutoff evidence, so #120 should capture freshness, cadence, closed-bag
coverage, and fail-closed evidence for a better source.

The refreshed alternate-source probe
`.build/temperature-provider-proof/alt-source-classified-20260513T082121Z`
applies the same battery-context classification to discovery evidence:

```text
smcEndpointPresent=true
pmuTempSensorPresent=true
ioreportTemperatureLegendPresent=true
numericTemperatureObserved=false
numericTemperatureCandidateCount=0
numericTemperatureRawCandidateCount=2
numericTemperatureRejectedBatteryContextCount=2
numericTemperatureRejectionReason=ioreg-smc-battery-context-only
numericCutoffSource=false
providerProofReady=false
```

The rejected discovery candidates were the same battery-context
`"Temperature"` and `"VirtualTemperature"` lines under `AppleSmartBattery`.
The PMU temperature sensor inventory exposes named surfaces such as `PMU tdie*`
and `PMU tdev*`, but it does not expose a current scalar reading through the
non-mutating `ioreg` inventory. Treat those PMU nodes as future API/research
surfaces, not selected provider output.

The follow-up alternate-source probe
`.build/temperature-provider-proof/alt-source-hidutil-20260513T131843Z` adds
the HID service inventory from `hidutil list`:

```text
evidenceFormat=temperature-alt-source-probe-v2
hidutilAvailable=true
hidPmuTemperatureInventoryPresent=true
numericTemperatureObserved=false
numericTemperatureCandidateCount=0
numericCutoffSource=false
providerProofReady=false
```

The later `.build/temperature-provider-proof/alt-source-nvme-20260513T134806Z`
artifact adds the `AppleEmbeddedNVMeTemperatureSensor` inventory:

```text
evidenceFormat=temperature-alt-source-probe-v2
nvmeTempSensorPresent=true
numericTemperatureObserved=false
numericTemperatureCandidateCount=0
numericTemperatureRawCandidateCount=2
numericTemperatureRejectedBatteryContextCount=2
numericTemperatureRejectionReason=ioreg-smc-battery-context-only
numericCutoffSource=false
providerProofReady=false
```

That evidence shows many `AppleSMCKeysEndpoint` HID service rows with product
names like `PMU tdev*` and `PMU tdie*`. Those rows are useful sensor-inventory
leads, but they are still names and registry metadata rather than current
temperature readings. The NVMe inventory similarly exposes a product name such
as `NAND CH0 temp`, but not a current scalar reading in the non-mutating local
inventory. They do not change the provider conclusion.

Newer alternate-source probe artifacts use
`evidenceFormat=temperature-alt-source-probe-v6` and add bounded HID
temperature-service NDJSON, filtered `hidutil dump services` evidence, the
local `smctempsensor0` / `AppleSMCSensorDispatcher` surface, and a native
`libIOReport` sampler for ANS2/MSP temperature-like channels. The sampler now
prints raw `IOReportChannelInfo.IOReportChannelUnit` plus
`IOReportChannelGetUnit` quantity/scale metadata next to each numeric sample,
and aggregate `temperatureScaleVerified` fields. The additional
fields (`hidPmuTemperatureServiceCount`, `hidNvmeTemperatureInventoryPresent`,
`hidTemperatureServiceDumpPresent`, `smcTempSensorNodePresent`,
`smcSensorDispatcherPresent`, `smcSensorDispatcherUserClientPresent`,
`ioreportProbeAvailable`, `ioreportTemperatureSampleCount`,
`ioreportTemperatureScaleVerified`, and
`ioreportTemperatureScaleVerifiedCount`) make the
PMU/NVMe/HID/SMC-dispatcher/IOReport surfaces easier to audit. The local
`.build/temperature-provider-proof/alt-source-ioreport-unit-field-20260514T075756Z`
artifact captured four ANS2/MSP samples but reported
`ioreportTemperatureScaleVerified=false`, `ioreportTemperatureScaleVerifiedCount=0`,
and undefined IOReport unit metadata (`unitFieldPresent=true`, `unitRaw=0x0`,
`unitQuantity=0`), so the discovery probe still keeps `numericCutoffSource=false`
until helper-owned scale, freshness, cadence, coverage, and fail-closed proof
are captured.

The `.build/temperature-provider-proof/alt-source-iohid-20260513T150045Z`
artifact adds a native `IOHIDEventSystemClient` / `IOHIDServiceClient` property
probe over the same vendor-defined temperature usage. It completed inside the
2 second timeout and saw `iohidTemperatureServiceCount=77`, including PMU and
NVMe-like services, but recorded `iohidValuePropertyCount=0` and
`iohidNumericValuePropertyCount=0`. That makes the HID service surface more
explicitly negative: the services are visible, but common current-value
properties are not exposed to this non-mutating app-side probe.

The `.build/temperature-provider-proof/alt-source-smc-dispatcher-20260513T154345Z`
artifact adds the local SMC sensor-dispatcher surface:

```text
evidenceFormat=temperature-alt-source-probe-v4
smcTempSensorNodePresent=true
smcSensorDispatcherPresent=true
smcSensorDispatcherUserClientPresent=true
smcSensorDispatcherThermalmonitordClientPresent=true
numericTemperatureObserved=false
numericTemperatureCandidateCount=0
numericCutoffSource=false
providerProofReady=false
```

That proves a live `smctempsensor0` node and `AppleSMCSensorDispatcher` user
client are visible locally, with `thermalmonitord` attached, but the inventory
does not expose a current scalar temperature reading or a public provider
contract for Closed-Lid Mode.

The follow-up `.build/temperature-provider-proof/ioreg-pmu-local-20260513T105941Z`
artifact adds `AGENTWAKE_TEMPERATURE_PROVIDER_SOURCE=ioreg-pmu`, which runs
`/usr/sbin/ioreg -r -c AppleARMPMUTempSensor -l`. A direct generated-helper run
completed inside the 1 second timeout and captured 278,760 stdout bytes without
truncation, but found no numeric candidates:

```text
providerSource=ioreg-pmu
command=/usr/sbin/ioreg -r -c AppleARMPMUTempSensor -l
timeoutSeconds=1
durationSeconds=1
timedOut=false
exitCode=0
helperOwned=false
numericTemperatureObserved=false
numericTemperatureCandidateCount=0
numericTemperatureAcceptedCount=0
```

The fresh SMAppService artifact
`.build/temperature-provider-proof/ioreg-pmu-smappservice-20260513T110017Z`
registered the same source, reached status raw `1`, and launched the daemon as
root after approval and a 15 second wait. `launchctl` recorded `runs = 1`, and
the helper-owned sample wrote:

```text
providerSource=ioreg-pmu
command=/usr/sbin/ioreg -r -c AppleARMPMUTempSensor -l
timeoutSeconds=1
durationSeconds=1
timedOut=false
exitCode=0
helperOwned=true
stdoutBytes=278760
stdoutTruncated=false
numericTemperatureObserved=false
numericTemperatureCandidateCount=0
numericTemperatureAcceptedCount=0
```

This is useful negative evidence: PMU `ioreg` support is explicit in the proof
harness and can run helper-owned, but the local visible PMU surface does not
expose a numeric cutoff candidate.

To test the SMC sensor-dispatcher path through the same no-membership helper,
prepare an artifact with:

```sh
AGENTWAKE_TEMPERATURE_PROVIDER_SOURCE=ioreg-smc-dispatcher \
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/ioreg-smc-dispatcher-$(date -u +%Y%m%dT%H%M%SZ)
```

The approved SMAppService artifact
`.build/temperature-provider-proof/ioreg-smc-dispatcher-prepare-20260514T041342Z`
ran that source as root after approval and a 15 second wait:

```text
providerSource=ioreg-smc-dispatcher
command=/usr/sbin/ioreg -r -c AppleSMCSensorDispatcher -l
timeoutSeconds=1
durationSeconds=1
timedOut=false
exitCode=0
helperOwned=true
stdoutBytes=1006
stdoutTruncated=false
numericTemperatureObserved=false
numericTemperatureCandidateCount=0
numericTemperatureAcceptedCount=0
```

The output exposes `AppleSMCSensorDispatcher`, `AppleSMCSensorDispatcherUserClient`,
and `IOUserClientCreator = "pid 552, thermalmonitord"`, but no scalar reading.
Cleanup unregistered the helper and returned status raw `0`. This is useful
negative helper-owned source evidence only; it must not be treated as final proof
until a source produces a non-battery numeric cutoff signal plus freshness,
cadence, timeout, closed-bag coverage, and fail-closed evidence.

The thermal command artifact
`.build/temperature-provider-proof/thermal-levels-smappservice-20260513T173804Z`
adds `AGENTWAKE_TEMPERATURE_PROVIDER_SOURCE=thermal-levels`, which runs
`/usr/bin/thermal levels`. The same no-membership helper path reached status
raw `1`, launched as root after approval and a 15 second wait, then recorded:

```text
providerSource=thermal-levels
command=/usr/bin/thermal levels
timeoutSeconds=1
durationSeconds=1
timedOut=false
exitCode=69
helperOwned=true
stdoutBytes=0
stderrBytes=48
numericTemperatureObserved=false
numericTemperatureCandidateCount=0
```

The command stderr was `Thermal levels are unsupported on this machine.` Cleanup
succeeded: `unregister()` moved status from raw `1` to `0`, and `launchctl`
could not find the service after unregister. This proves the root-gated
`thermal levels` path is now represented in the helper-owned source matrix, but
it is negative local evidence only: the command is unsupported on this machine
and provides no accepted numeric cutoff source, freshness, cadence,
closed-bag coverage, or fail-closed proof.

The `.build/temperature-provider-proof/ioreport-ans2-smappservice-20260514T052521Z`
artifact adds `AGENTWAKE_TEMPERATURE_PROVIDER_SOURCE=ioreport-ans2`, which
bundles a native `libIOReport` probe next to the ad-hoc helper. After
SMAppService approval and the required 15 second wait, the helper launched as
root and recorded:

```text
providerSource=ioreport-ans2
command=.../AgentWakeIOReportTemperatureProbe
timeoutSeconds=1
durationSeconds=1
timedOut=false
exitCode=0
helperOwned=true
stdoutBytes=582
stdoutTruncated=false
numericTemperatureObserved=true
numericTemperatureCandidateCount=4
numericTemperatureAcceptedCount=4
numericTemperatureRejectionReason=none
```

The captured samples were four ANS2/MSP `Temperature(0)` channels with
`temperature=35` and `scale=unverified`. A later direct probe refresh added
unit metadata and observed `unitFieldPresent=true`, `unitRaw=0x0`,
`unitQuantity=0`, `unitScale=0x0`, and empty `unitLabel`, so IOReport does not
currently prove the values are Celsius on this machine. Cleanup succeeded:
`unregister()` moved status from raw `1` to `0`. This is the first helper-owned,
non-battery numeric candidate under the 1 second provider deadline. It still is
not verifier-ready provider proof because freshness, active/idle cadence, scale
validation, closed-bag coverage, and fail-closed rows remain incomplete.

## Conclusion

No production Closed-Lid Mode temperature provider is selected yet. The current best
candidate is the helper-owned native `libIOReport` ANS2/MSP probe because it is
non-battery, numeric, root-owned, and completes under the 1 second deadline.
It still needs scale validation, freshness/cadence evidence, closed-bag
coverage, and fail-closed proof in final app E2E validation.

`ProcessInfo.thermalState` is permission-compatible and useful as a supplemental app-side thermal-pressure/liveness signal, but it is coarse, non-numeric, and does not prove closed-bag coverage. `pmset -g therm` did not provide current numeric temperature evidence. AppleSmartBattery temperature is useful context when present, but it is not enough for CPU/package or closed-bag thermal risk and did not meet the 10 second freshness target in the local run. The no-membership `SMAppService` path can launch a helper as root on this machine. The tested `powermetrics` sampler variants did not provide a trustworthy numeric cutoff source. The bounded `ioreg-smc` diagnostic path now runs as root through SMAppService without timing out, but its observed `AppleSmartBattery` values are rejected as production cutoff candidates and do not prove CPU/package or closed-bag thermal coverage. The `ioreg-pmu` path now also runs as root through SMAppService without timing out, but the visible `AppleARMPMUTempSensor` inventory exposes PMU sensor names without numeric readings. The `thermal-levels` path can also run as root through SMAppService, but `/usr/bin/thermal levels` exits 69 with unsupported-hardware output on this machine. The refreshed alternate-source probe now captures `hidutil list`, HID temperature-service NDJSON/dump metadata, native IOHID service properties, NVMe temperature sensor inventory, and native IOReport samples. On this machine the IOReport ANS2/MSP path is the first accepted non-battery numeric candidate, while the HID/PMU/NVMe inventory remains metadata only. Final app E2E issue [#120](https://github.com/makeavish/AgentWake/issues/120) must still prove scale or feature-gated fail-closed behavior, freshness, cadence, timeout, and coverage before Closed-Lid Mode/release readiness is claimed.

Production Closed-Lid Mode readiness remains gated by [#120](https://github.com/makeavish/AgentWake/issues/120), which carries forward the remaining provider validation rows from #25.

## Helper Provider Proof Verifier

Before attaching or summarizing helper/helper-equivalent provider proof in #120, run:

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

To inventory non-`powermetrics` source candidates for future helper-owned
sampling without sudo, run:

```bash
scripts/temperature-provider-alt-source-probe.sh \
  --output-dir .build/temperature-provider-proof/alt-source-probe-$(date -u +%Y%m%dT%H%M%SZ)
```

This captures local SMC, PMU temperature sensor, NVMe temperature sensor, die
temperature controller, HID service/dump, native IOHID service properties, and
native IOReport samples as discovery evidence. It also writes
`evidence/numeric-temperature-candidates.txt`, a bounded list of captured lines
that look like labeled numeric temperature values and should be reviewed before
the next helper-owned provider attempt, plus
`evidence/rejected-temperature-candidates.txt` for battery-context lines that
look numeric but are not production cutoff candidates. Generic `die-id`,
`die-count`, and `*-temp` table/interface identifiers are intentionally
excluded from the accepted candidate list. PMU `tdev`/`tdie` rows from
`hidutil list`, HID temperature-service NDJSON/dump output, and NVMe
`NAND ... temp` product names are captured as inventory leads only. The native
IOHID probe checks common current-value property keys, but its local run found
zero value properties. The native IOReport probe can expose ANS2/MSP numeric
temperature-like samples locally, but the probe does not select a provider or promote numeric cutoff proof;
`providerProofReady=false` remains expected until helper-owned numeric output,
freshness, cadence, timeout behavior, and closed-bag coverage are proven.

To build the no-membership `SMAppService` provider candidate without changing
helper registration state, run:

```bash
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/smappservice-prepare-$(date -u +%Y%m%dT%H%M%SZ)
```

The default mode builds an ad-hoc signed app/helper bundle whose LaunchDaemon
helper runs one timeout-bounded `powermetrics` sample after registration and
approval. New artifacts still default to `powermetrics --show-initial-usage -n
1 -i 1000 --samplers thermal` for reproducible comparison with existing
evidence, but the current local conclusion is that the tested `powermetrics`
variants are not the primary path to a provider-ready numeric cutoff source.
Use `AGENTWAKE_TEMPERATURE_PROVIDER_SHOW_INITIAL_USAGE=false` or
`AGENTWAKE_TEMPERATURE_PROVIDER_POWERMETRICS_SAMPLERS=<samplers>` only for
comparison runs, for example `all`, `default`, `cpu_power`, or
`thermal,cpu_power`.

To generate the helper-owned I/O Registry SMC diagnostic source, create the
artifact with:

```bash
AGENTWAKE_TEMPERATURE_PROVIDER_SOURCE=ioreg-smc \
  scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/ioreg-smc-$(date -u +%Y%m%dT%H%M%SZ)
```

That source runs `/usr/sbin/ioreg -r -c AppleSMCKeysEndpoint -l` from the
approved helper. The generated helper writes provider stdout/stderr to temporary
files and reads back at most 2,000,000 bytes per stream so large I/O Registry
output does not block on a full pipe. New `ioreg-smc` artifacts reject numeric
matches under `AppleSmartBattery` or `AppleSmartBatteryManager` and report
`numericTemperatureRejectionReason=ioreg-smc-battery-context-only` when those
are the only candidates. The bounded SMAppService run is root-owned and
no-timeout, but it is still candidate-source evidence rather than provider
proof because freshness, cadence, closed-bag coverage, fail-closed evidence,
and a non-battery numeric cutoff source are still missing.

To test the PMU I/O Registry inventory path explicitly, use:

```bash
AGENTWAKE_TEMPERATURE_PROVIDER_SOURCE=ioreg-pmu \
  scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/ioreg-pmu-$(date -u +%Y%m%dT%H%M%SZ)
```

That source runs `/usr/sbin/ioreg -r -c AppleARMPMUTempSensor -l`. On this
machine, the direct generated-helper run finished within the timeout but
reported `numericTemperatureCandidateCount=0`. The SMAppService run for the
same PMU identity reached status raw `1`, launched as root, and also reported
`numericTemperatureCandidateCount=0`.

To test the root-gated thermal levels command explicitly, use:

```bash
AGENTWAKE_TEMPERATURE_PROVIDER_SOURCE=thermal-levels \
  scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/thermal-levels-$(date -u +%Y%m%dT%H%M%SZ)
```

That source runs `/usr/bin/thermal levels` from the approved helper. Treat it
as diagnostic source evidence only until it exposes an accepted numeric cutoff
signal and the freshness, cadence, timeout, coverage, and fail-closed rows are
completed.

To test the native IOReport ANS2/MSP candidate explicitly, use:

```bash
AGENTWAKE_TEMPERATURE_PROVIDER_SOURCE=ioreport-ans2 \
  scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/ioreport-ans2-$(date -u +%Y%m%dT%H%M%SZ)
```

That source bundles `AgentWakeIOReportTemperatureProbe` into the ad-hoc app and
runs it from the approved helper. The May 14 local artifact produced four
helper-owned numeric ANS2/MSP samples under the 1 second deadline, making it the
best current source candidate. Keep it marked proof-incomplete until scale,
freshness, cadence, closed-bag coverage, and fail-closed evidence are captured.

Each new artifact also gets a unique SMAppService bundle/helper identity derived
from its output path. This avoids reusing stale macOS approval/code-signing state
between ad-hoc proof attempts. To force a deterministic suffix for comparison
runs, set `AGENTWAKE_TEMPERATURE_PROVIDER_ID_SUFFIX=<lettersAndDigits>`.
Mutating registration uses the same prepared artifact and requires:

```bash
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/<same-smappservice-provider-artifact> \
  --register \
  --i-understand-this-registers-provider
```

After approval, wait at least 15 seconds, then append non-mutating provider
output from the same artifact with:

```bash
scripts/temperature-provider-smappservice-proof.sh \
  --output-dir .build/temperature-provider-proof/<same-smappservice-provider-artifact> \
  --capture-post-approval
```

The append mode captures helper runtime context, provider output/status,
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

The verifier requires a `scale-validation` evidence row, and compares
`manual-result.md` against `validation-config.txt` for provider source,
freshness, cadence, timeout, closed-bag coverage, and result.

`provider-manifest.tsv` must use this tab-separated header:

```tsv
checkId	status	evidencePath	note
```

Required manifest `checkId` rows:

- `provider-command-or-api`
- `helper-ownership-context`
- `numeric-temperature-output`
- `scale-validation`
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
scale-validation	evidence	evidence/scale-validation.txt	scale validation attached
```

Evidence paths must be relative, non-empty, inside the evidence package, and free
of symlink components. Evidence files must contain real captured output rather
than `TODO`, `<paste output>`, or placeholder text. Verifier success is
structural only; it does not prove the provider is reliable or complete #120.
