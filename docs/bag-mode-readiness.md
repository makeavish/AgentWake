# Bag Mode Readiness

Bag Mode is blocked until the primitive, helper, and safety-provider spikes produce concrete evidence. This page is the operator checklist for issue #7.

## Primitive Validation

`pmset disablesleep` is still only a candidate primitive. Start with a baseline-only capture:

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

Mutating mode requires root so rollback cannot stall on an expired sudo prompt. It records the prior `disablesleep` value, applies `/usr/bin/pmset disablesleep 1`, captures `during-applied/`, waits for the manual lid-close/reopen window, captures `after-lid-window/`, and restores the prior `disablesleep` value.

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

The harness redacts host/user metadata by default. Fill in `manual-result.md` before attaching the directory to issue #7. Every primitive matrix case must include reboot state or an explicit `N/A` reason in `manual-result.md`.

## Required Matrix

| Dimension | Required coverage |
|---|---|
| macOS | 13, 14, 15+ where available |
| CPU | Apple Silicon and Intel if Intel support remains in scope |
| Power | AC and battery |
| Display | Internal only, external display, no external display |
| Lid | Open, closed, reopen recovery |
| Lifecycle | App quit, crash, reboot while held, helper restart |

Each case must record the exact command applied, rollback command, `pmset -g custom`, `pmset -g assertions`, available IORegistry state, lid-close result, and reboot state when relevant.

## Helper Spike

The helper proof must answer whether `SMAppService` LaunchDaemon is viable for signed Homebrew distribution.

Required notes:

- Bundle layout and launchd label
- App/helper signing identities and designated requirements
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

Unsigned public builds must not expose production Bag Mode. Local helper experiments stay behind a development flag.

## Temperature Provider Spike

The provider proof must choose a fresh, permission-compatible temperature source for Bag Mode.

Required notes:

- Source tested: SMC, `powermetrics`, `ProcessInfo.thermalState`, or other
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

The May 12, 2026 source check found upstream Codex hook events before legacy `notify`: `SessionStart`, `UserPromptSubmit`, and tool hooks provide earlier native lifecycle signals, while `Stop` is a native completion signal before legacy `notify`. Current ClawShell behavior still uses legacy `notify` plus process detection; native Codex hook support is tracked in [#23](https://github.com/makeavish/ClawShell/issues/23).

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
