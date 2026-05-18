# Changelog

## v0.2.2 - 2026-05-18

Settings and safety polish release:

- Adds configurable Lid-Closed Awake safety thresholds in Settings.
- Enforces release-only battery floor and macOS critical thermal pressure
  cutoffs while Lid-Closed Awake is active.
- Replaces the Settings pause dropdown with an explicit duration sheet.
- Fixes safety controls so they are clickable and use one-step increments.
- Clarifies launch-at-login status copy and hides misleading off-state text.
- Makes uninstall remove hooks, restore AgentWake-owned Lid-Closed Awake state,
  move the app bundle to Trash, and quit.
- Aligns local build bundle versions with the latest release tag for better
  diagnostics.

## v0.2.1 - 2026-05-17

Menu bar and first-run UX polish release:

- Replaces the static menu bar wordmark with glanceable state icons.
- Keeps menu actions enabled in the menu bar app.
- Uses adaptive menu bar icon tint so the icon remains visible across menu bar
  appearances.
- Clarifies session copy, including detected sessions that can also be kept
  awake.
- Adds first-run onboarding, integration details, per-agent enable toggles, and
  pause/resume controls.
- Explains Lid-Closed Awake administrator permission before macOS asks for it.
- Shows Lid-Closed Awake safety warnings while battery and thermal cutoffs are
  still pending.
- Keeps onboarding and permission prompts frontmost when other apps are active.

## v0.2.0 - 2026-05-15

Session and UX polish release:

- Adds concise menu/settings copy: `found`, `keeping awake`, `Keep Awake`,
  and `Stop Keeping Awake`.
- Detects the primary Codex Desktop app-server after AgentWake starts, while
  still treating it as found-only until trusted activity or manual action.
- Reuses Codex process-backed sessions across new turn IDs to avoid duplicate
  session rows.
- Releases Codex protection on `Stop`/completion, and expires stale
  `PostToolUse` holds when Codex does not send a completion hook.
- Adds `Stop Keeping Awake` to release current sleep protection from the menu.
- Hides installed integration rows from the short menu and shows repair only
  when an integration needs attention.
- Refreshes the Settings window while it is visible.
- Removes success popups for routine menu/settings actions.

## v0.1.0 - 2026-05-15

First public release scope:

- Keeps the Mac awake through validated normal sleep-prevention paths while
  Claude Code or Codex CLI sessions are active.
- Can manually protect already-running detected sessions until those processes
  exit.
- Shows current hold state from the menu bar app and CLI.
- Installs and reports first-class Claude Code and Codex CLI integrations where
  their local configuration surfaces are available.
- Releases sleep prevention when watched agent sessions finish, expire their
  grace window, or the user pauses/releases AgentWake.
- Includes local-only logs and status surfaces for integration setup, helper
  fallback outcomes, and release decisions.

Closed-Lid Mode status:

- Closed-Lid Mode can be enabled or disabled for local testing with macOS
  administrator approval.
- The implementation toggles `pmset disablesleep`, records the prior value, and
  restores that value when disabled.
- Live temperature-provider cutoff automation remains deferred; users should
  treat this as an explicit local/admin-approved mode.
- The CLI accepts the product-facing `agentwake closed-lid status|enable|disable`
  path.

Release notes:

- No Apple Developer Program membership is required for the v1 normal
  sleep-prevention scope.
- Normal runtime/use does not require admin privileges.
- The product rename uses fresh AgentWake local state under
  `~/Library/Application Support/AgentWake/`; old pre-release ClawShell state is
  not migrated. AgentWake does clean up legacy ClawShell-owned Claude Code and
  Codex CLI integration hooks during integration install/remove.
- Any future Closed-Lid Mode helper/admin approval flow is outside this release
  and is tracked separately in the post-v1 readiness issue.
