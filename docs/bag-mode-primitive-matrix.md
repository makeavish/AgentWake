# Bag Mode Primitive Matrix

Check date: May 13, 2026

Issue: [#7](https://github.com/makeavish/ClawShell/issues/7)

Follow-up: [#29](https://github.com/makeavish/ClawShell/issues/29)

Harness artifact: [PR #22](https://github.com/makeavish/ClawShell/pull/22)

Latest local apply artifact: `.build/power-validation/bag-mode-matrix/apple-silicon-ac-internal-20260513T115058Z`

## Question

Is `pmset disablesleep` reliable enough across ClawShell's required Bag Mode matrix?

## Current Evidence

PR #22 added `scripts/bag-mode-primitive-validation.sh`, a dedicated harness for the candidate primitive. The harness can:

- run a non-mutating baseline capture
- require root plus explicit acknowledgement for mutating runs
- record the previous `disablesleep` value before applying the candidate primitive
- capture `pmset -g custom`, `pmset -g assertions`, IORegistry state, and redacted metadata
- write rollback instructions before reboot-held validation
- restore and verify the pre-run `disablesleep` value in non-reboot mutating runs
- preserve the baseline `before/` snapshot when continuing into apply mode
- refresh apply-mode metadata so baseline captures are not mistaken for #29 evidence

This proves the evidence workflow exists. It does not prove the primitive is reliable.

The latest local apply artifact records an Apple Silicon, AC, internal-display,
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

## Missing Evidence

Only one primitive-only case has verified evidence so far, and that case is
inconclusive. Missing matrix coverage still includes:

- macOS 13, 14, and 15+ where available
- Apple Silicon, and Intel if Intel support remains in scope
- battery
- external display and no-external-display cases where physically available
- open and closed lid paths beyond the current inconclusive reopen-recovery run
- app quit, app crash, and reboot while held lifecycle cases

Helper-dependent cases, such as helper restart and helper upgrade mid-hold, are deferred until #27 produces a validated no-membership helper prototype. Until then, each helper-only lifecycle row must be marked `N/A` or `deferred until #27` in `manual-result.md`.

Each case still needs the exact command applied, rollback command, `pmset -g custom`, `pmset -g assertions`, relevant IORegistry state, lid-close result, reboot state or explicit `N/A`, and a pass/fail/inconclusive conclusion in `manual-result.md`. Attach evidence directories to #29 and summarize or cross-link the result on #7.

Before attaching evidence, run:

```sh
scripts/bag-mode-primitive-matrix-verify.sh --manifest <matrix-evidence-root>/matrix-manifest.tsv
```

To start a local matrix directory without inventing rows by hand, generate a
non-mutating scaffold:

```sh
scripts/bag-mode-primitive-matrix-scaffold.sh \
  --output-dir .build/power-validation/bag-mode-matrix-$(date -u +%Y%m%dT%H%M%SZ)
```

The scaffold is not evidence. It intentionally writes `TODO` manifest statuses
so the verifier fails until each row is replaced with real evidence, a concrete
`n/a` reason, or a concrete `deferred` reason.

The manifest is a tab-separated file with this header:

```tsv
caseId	status	evidenceDir	naReason
```

Use `status=evidence` for rows with a completed evidence directory, `status=n/a` for physically unavailable rows, and `status=deferred` for helper-dependent rows blocked on #27. `n/a` and `deferred` rows must include a concrete reason in `naReason`.

The verifier fails missing files, baseline-only captures, test-only fake-`pmset` captures, placeholder manual fields, placeholder snapshot output, unredacted snapshot metadata, missing reboot state, missing IORegistry snapshots, incomplete snapshot directories, placeholder N/A/deferred reasons, and manifests with no evidence rows. Passing the verifier only means the manifest and evidence package are structurally complete; it does not mean the primitive passed the hardware matrix.

## Conclusion

The primitive remains unproven. The first real Apple Silicon AC/internal apply
case is structurally verified but inconclusive. Production Bag Mode must stay
blocked until [#29](https://github.com/makeavish/ClawShell/issues/29) records a
reliable hardware matrix or the TDD switches to a different proven primitive.
