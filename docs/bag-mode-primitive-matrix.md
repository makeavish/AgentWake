# Bag Mode Primitive Matrix

Check date: May 12, 2026

Issue: [#7](https://github.com/makeavish/ClawShell/issues/7)

Follow-up: [#29](https://github.com/makeavish/ClawShell/issues/29)

Harness artifact: [PR #22](https://github.com/makeavish/ClawShell/pull/22)

Latest local baseline-only artifact: `.build/power-validation/bag-mode-baseline-20260512T104304Z`

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

The latest local baseline-only artifact records `mode=baseline-only`,
`testOnly=false`, `candidateCommand=/usr/bin/pmset disablesleep 1`, and
redacted metadata. It is a starting point for a later mutating run with
`--apply --continue`; it is not pass/fail matrix evidence for #29.

## Missing Evidence

No pass/fail matrix is recorded yet for the primitive-only cases available before the signed helper prototype:

- macOS 13, 14, and 15+ where available
- Apple Silicon, and Intel if Intel support remains in scope
- AC and battery
- internal-only, external display, and no-external-display cases where physically available
- open, closed, and reopen recovery behavior
- app quit, app crash, and reboot while held lifecycle cases

Helper-dependent cases, such as helper restart and helper upgrade mid-hold, are deferred until #27 produces a signed helper prototype. Until then, each helper-only lifecycle row must be marked `N/A` or `deferred until #27` in `manual-result.md`.

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

The primitive remains unproven. Production Bag Mode must stay blocked until [#29](https://github.com/makeavish/ClawShell/issues/29) records the real hardware matrix or the TDD switches to a different proven primitive.
