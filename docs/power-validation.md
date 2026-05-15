# Power Validation

## Normal Assertions

AgentWake normal mode uses non-privileged IOPM assertions through `IOPMAssertionCreateWithName`.

Default assertion set:

- `PreventUserIdleSystemSleep`

The default set intentionally does not include `PreventSystemSleep` because the local macOS SDK marks that assertion as unsupported. It also does not include display sleep prevention. Disk idle prevention remains a validation candidate: `PreventDiskIdle` must prove useful in `pmset` artifacts before becoming part of the default normal hold.

Run the repeatable normal assertion harness:

```sh
scripts/normal-assertion-validation.sh
```

The harness writes `before`, `during`, and `after` snapshots under `.build/power-validation/`. Each phase includes `pmset -g assertions`, `pmset -g custom`, battery state, live power settings, and optional IORegistry power-source state.

Run the timed idle harness when the machine is on the target power source and the current `pmset -g custom` sleep interval is short enough to observe:

```sh
bash scripts/timed-idle-validation.sh
```

By default, this holds the normal assertion for 90 seconds and captures `before`, `during-early`, `during-late`, and `after` snapshots. The harness does not change `pmset` settings. It records the active power source, the active profile's `sleep` threshold, whether the late snapshot exceeded that threshold, any non-AgentWake sleep-preventing assertions in `validation-config.txt` and `non-agentwake-late-sleep-blockers.txt`, and cleanup hints in `non-agentwake-late-sleep-blocker-guidance.txt`. Treat a run as conclusive only when `validation-config.txt` contains `conclusive=true`.

Before attempting a clean timed-idle run, use the preflight helper from a normal terminal to check whether the active power profile can exceed the sleep threshold and whether unrelated sleep blockers are already present:

```sh
scripts/timed-idle-preflight.sh
```

Preflight is advisory and does not hold assertions or create validation evidence. It exits successfully only when the active `sleep` threshold is lower than the configured late snapshot offset and no non-AgentWake sleep blockers are visible in `pmset -g assertions`. When blockers are present, it prints suggested cleanup for common cases such as WindowServer `UserIsActive`, powerd display-on, sharingd Handoff, Slack/WebRTC, coreaudiod audio activity, Codex/Electron, and generic app assertions. Treat system daemons as symptoms: clear the owning activity instead of killing WindowServer, powerd, sharingd, or coreaudiod.

## Manual Result Matrix

Do not claim clamshell-on-AC support from normal assertions until a real MacBook validation pass proves it. Normal assertion artifacts should fill this matrix as hardware checks are run.

| Scenario | Required artifact | Current status |
|---|---|---|
| Idle sleep on AC | Timed idle harness output while on AC | Non-conclusive blocker-accounted run captured; assertion lifecycle observed, but clean idle validation remains open until `conclusive=true` or explicit owner sign-off accepting non-conclusive lifecycle evidence |
| Idle sleep on battery | Timed idle harness output while on battery | Legacy confounded timed snapshot captured; assertion lifecycle observed, but clean idle validation remains open until a current-harness `conclusive=true` run or explicit owner sign-off accepting non-conclusive lifecycle evidence |
| AC clamshell, internal display only | Manual lid-close result plus `pmset` snapshots | Not claimed |
| AC clamshell with external display | Manual lid-close result plus `pmset` snapshots | Not claimed |
| Battery clamshell | Bag Mode spike only; normal assertions are not proof | Not claimed |

Attach generated harness directories to the relevant issue or PR when validating hardware behavior. Generated `.build/power-validation/` artifacts are local evidence and are not committed by default.

## Bag Mode Primitive Spike

Bag Mode uses a separate readiness workflow because it may require privileged power-setting changes and real lid-close hardware checks. Use the issue #7 checklist in `docs/bag-mode-readiness.md`.

Baseline-only capture is non-mutating:

```sh
scripts/bag-mode-primitive-validation.sh --case-id apple-silicon-battery-internal
```

Mutating validation requires explicit acknowledgement:

```sh
sudo scripts/bag-mode-primitive-validation.sh \
  --case-id apple-silicon-battery-internal \
  --apply \
  --i-understand-this-changes-power-settings
```

Mutating runs record and restore the pre-run `disablesleep` value rather than assuming rollback is always `disablesleep 0`. If `pmset -g custom` omits the `disablesleep` row, the harness records the effective default/off value as `0` so rollback can still be explicit.
When a baseline-only evidence directory is reused, pass that exact directory
back with `--output-dir <baseline-dir> --apply --continue`. The harness keeps
the original `before/` snapshot and refreshes `validation-config.txt` to
apply-mode metadata before capturing the mutating snapshots.

Latest local normal assertion smoke: `scripts/normal-assertion-validation.sh` was run for a short hold while the machine was on battery. The sanitized `during` snapshot showed an AgentWake-owned `PreventUserIdleSystemSleep` assertion, and the `after` snapshot no longer contained AgentWake-owned assertions.

Sanitized excerpt:

```text
during/pmset-assertions.txt:
pid <redacted>(AgentWakePowerValidation): PreventUserIdleSystemSleep named: "AgentWake is protecting agent work from sleep"

after/pmset-assertions.txt:
<no AgentWakePowerValidation assertions present>
```

Latest battery timed snapshot: `.build/power-validation/battery-timed-idle-20260510T165231Z` was captured while the machine was on battery with `sleep = 1` minute and a 90 second AgentWake hold. This is a legacy/confounded snapshot from before the timed harness wrote `validation-config.txt` and `non-agentwake-late-sleep-blockers.txt`, so treat it as lifecycle evidence only, not a clean/conclusive idle-sleep result.

Sanitized battery evidence:

```text
before/pmset-battery.txt: Now drawing from 'Battery Power'
during-late/pmset-battery.txt: Now drawing from 'Battery Power'
after/pmset-battery.txt: Now drawing from 'Battery Power'
hold.log: Holding normal assertions for 90 seconds
hold.log: Assertions: PreventUserIdleSystemSleep
during-late/pmset-assertions.txt: AgentWakePowerValidation PreventUserIdleSystemSleep present
after/pmset-assertions.txt: no AgentWake assertion present
during-late blockers: WindowServer UserIsActive, Comet/audio, Codex/Electron, powerd, sharingd, coreaudiod
```

Latest AC timed run: `.build/power-validation/battery-accounted-20260510T1709Z` was captured while the machine was on AC with `sleep = 1` minute and a 90 second AgentWake hold. The directory name is misleading; the run's `validation-config.txt` recorded `activePowerSource=AC Power`:

```text
activePowerSource=AC Power
activeSleepThresholdSeconds=60
idleSleepThresholdExceeded=true
lateAgentWakeAssertion=present
afterAgentWakeAssertion=missing
nonAgentWakeLateSleepBlockerCount=3
conclusive=false
```

The run confirms the normal assertion lifecycle under the AC profile, but it is not a clean/conclusive AC idle-sleep result because Codex/Electron, powerd, and WindowServer still held unrelated late blockers. A future clean hardware run should replace these blocker-accounted notes with `conclusive=true` artifacts.
