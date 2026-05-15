# Closed-Lid Mode Primitive Matrix

Check date: May 13, 2026

Original issue: [#7](https://github.com/makeavish/AgentWake/issues/7)

Final E2E follow-up: [#120](https://github.com/makeavish/AgentWake/issues/120)

Harness artifact: [PR #22](https://github.com/makeavish/AgentWake/pull/22)

Latest local apply artifacts:

- `.build/power-validation/bag-mode-matrix/apple-silicon-ac-internal-20260513T115058Z`
- `.build/power-validation/bag-mode-matrix/apple-silicon-battery-internal-20260513T162945Z`

## Question

Is `pmset disablesleep` reliable enough across AgentWake's required Closed-Lid Mode matrix?

## Current Evidence

PR #22 added `scripts/closed-lid-primitive-validation.sh`, a dedicated harness for the candidate primitive. The harness can:

- run a non-mutating baseline capture
- require root plus explicit acknowledgement for mutating runs
- record the previous `disablesleep` value before applying the candidate primitive
- capture `pmset -g custom`, `pmset -g assertions`, IORegistry state, and redacted metadata
- write rollback instructions before reboot-held validation
- restore and verify the pre-run `disablesleep` value in non-reboot mutating runs
- preserve the baseline `before/` snapshot when continuing into apply mode
- refresh apply-mode metadata so baseline captures are not mistaken for final E2E evidence

This proves the evidence workflow exists. It does not prove the primitive is reliable.

The first local apply artifact records an Apple Silicon, AC, internal-display,
normal lifecycle run on macOS 26.5:

```text
artifact=.build/power-validation/bag-mode-matrix/apple-silicon-ac-internal-20260513T115058Z
mode=apply
testOnly=false
rebootHeld=0
candidateCommand=/usr/bin/pmset disablesleep 1
previousDisablesleep=0
rollbackCommand=/usr/bin/pmset disablesleep 0
```

The artifact contains `before/`, `during-applied/`, `after-lid-window/`, and
`after-rollback/` snapshots. The `during-applied` and `after-lid-window`
`pmset -g live` snapshots both showed `SleepDisabled 1`, and rollback restored
the prior value `0`. The operator reported the physical lid-close sleep-block
result as `inconclusive` and reopen recovery as `yes`; the verifier passed for
this single case. Treat this as verified inconclusive matrix evidence for the
AC/internal/reopen-recovery case, not as a primitive pass.

The follow-up battery/internal artifact records an Apple Silicon, battery,
internal-display, normal lifecycle run on macOS 26.5:

```text
artifact=.build/power-validation/bag-mode-matrix/apple-silicon-battery-internal-20260513T162945Z
mode=apply
testOnly=false
rebootHeld=0
candidateCommand=/usr/bin/pmset disablesleep 1
previousDisablesleep=0
rollbackCommand=/usr/bin/pmset disablesleep 0
```

This artifact also contains `before/`, `during-applied/`,
`after-lid-window/`, and `after-rollback/` snapshots. The `before` snapshot
shows `Battery Power`; the `during-applied` and `after-lid-window`
`pmset -g live` snapshots both showed `SleepDisabled 1`; rollback restored
the prior value `0`. The operator reported that the initial closed-lid battery
window stayed blocked, reopening during the applied window recovered cleanly,
and the laptop later slept after the script completed. Treat the later sleep as
expected post-rollback behavior because the harness restored `SleepDisabled=0`.
The verifier passed for this single battery/internal case, so this is verified
pass evidence for the battery/internal/reopen-recovery normal lifecycle case.

## Missing Evidence

Two primitive-only cases have verified evidence so far: AC/internal is
inconclusive, and battery/internal reopen-recovery passed for the normal
lifecycle. Missing matrix coverage still includes:

- macOS 13, 14, and 15+ where available
- Apple Silicon, and Intel if Intel support remains in scope
- external display and no-external-display cases where physically available
- open and closed lid paths beyond the current reopen-recovery runs
- app quit, app crash, and reboot while held lifecycle cases

Helper-dependent cases, such as helper restart and helper upgrade mid-hold, are
carried forward to final app E2E issue
[#120](https://github.com/makeavish/AgentWake/issues/120). Until then, each
helper-only lifecycle row must be marked `N/A` or `deferred to #120` in
`manual-result.md`.

Each case still needs the exact command applied, rollback command, `pmset -g custom`, `pmset -g assertions`, relevant IORegistry state, lid-close result, reboot state or explicit `N/A`, and a pass/fail/inconclusive conclusion in `manual-result.md`. Attach or summarize new evidence in #120.

Before attaching evidence, run:

```sh
scripts/closed-lid-primitive-matrix-verify.sh --manifest <matrix-evidence-root>/matrix-manifest.tsv
```

To review current case directories before editing the manifest, run:

```sh
scripts/closed-lid-primitive-matrix-review.sh \
  --evidence-root .build/power-validation/bag-mode-matrix \
  --output .build/power-validation/bag-mode-matrix-review-candidates.tsv
```

The review report is advisory and does not edit `matrix-manifest.tsv`. It calls
the strict case verifier first, maps verified artifacts onto known matrix rows,
and leaves missing physical/lifecycle rows as `keep-todo`. Inconclusive cases
can still be evidence candidates, but they are not primitive passes.

To start a local matrix directory without inventing rows by hand, generate a
non-mutating scaffold:

```sh
scripts/closed-lid-primitive-matrix-scaffold.sh \
  --output-dir .build/power-validation/bag-mode-matrix-$(date -u +%Y%m%dT%H%M%SZ)
```

The scaffold is not evidence. It intentionally writes `TODO` manifest statuses
so the verifier fails until each row is replaced with real evidence, a concrete
`n/a` reason, or a concrete `deferred` reason.

The manifest is a tab-separated file with this header:

```tsv
caseId	status	evidenceDir	naReason
```

Use `status=evidence` for rows with a completed evidence directory, `status=n/a` for physically unavailable rows, and `status=deferred` for helper-dependent rows carried forward to final app E2E issue [#120](https://github.com/makeavish/AgentWake/issues/120). `n/a` and `deferred` rows must include a concrete reason in `naReason`.

The verifier fails missing files, baseline-only captures, test-only fake-`pmset` captures, placeholder manual fields, placeholder snapshot output, unredacted snapshot metadata, missing reboot state, missing IORegistry snapshots, incomplete snapshot directories, placeholder N/A/deferred reasons, and manifests with no evidence rows. Passing the verifier only means the manifest and evidence package are structurally complete; it does not mean the primitive passed the hardware matrix.

## Conclusion

The primitive remains unproven across the full app matrix. The Apple Silicon
battery/internal normal reopen-recovery case now has verified pass evidence,
but the AC/internal case is still inconclusive and broader display/lifecycle
coverage is missing. Remaining hardware/app lifecycle validation is tracked in
final app E2E issue [#120](https://github.com/makeavish/AgentWake/issues/120).
