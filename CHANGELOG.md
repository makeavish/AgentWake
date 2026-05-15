# Changelog

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
