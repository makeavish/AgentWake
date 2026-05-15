# Changelog

## v0.1.0 - 2026-05-15

First public release scope:

- Keeps the Mac awake through validated normal sleep-prevention paths while
  Claude Code or Codex CLI sessions are active.
- Shows current hold state from the menu bar app and CLI.
- Installs and reports first-class Claude Code and Codex CLI integrations where
  their local configuration surfaces are available.
- Releases sleep prevention when watched agent sessions finish, expire their
  grace window, or the user pauses/releases AgentWake.
- Includes local-only logs and status surfaces for integration setup, helper
  fallback outcomes, and release decisions.

Closed-Lid Mode status:

- Closed-Lid Mode is unavailable in this release.
- Closed-lid/clamshell support remains deferred until helper lifecycle, live
  temperature-provider, hardware matrix, and packaging validation gates are
  complete.
- The app, UI smoke harness, readiness docs, and README intentionally present
  Closed-Lid Mode as unavailable rather than partially supported.

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
