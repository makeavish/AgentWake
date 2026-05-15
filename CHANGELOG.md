# Changelog

## v1.0.0 - pending

First public release scope:

- Keeps the Mac awake through validated normal sleep-prevention paths while
  Claude Code or Codex CLI sessions are active.
- Shows current hold state from the menu bar app and CLI.
- Installs and reports first-class Claude Code and Codex CLI integrations where
  their local configuration surfaces are available.
- Releases sleep prevention when watched agent sessions finish, expire their
  grace window, or the user pauses/releases ClawShell.
- Includes local-only logs and status surfaces for integration setup, helper
  fallback outcomes, and release decisions.

Bag Mode status:

- Bag Mode is unavailable in this release.
- Closed-lid/clamshell support remains deferred until helper lifecycle, live
  temperature-provider, hardware matrix, and packaging validation gates are
  complete.
- The app, UI smoke harness, readiness docs, and README intentionally present
  Bag Mode as unavailable rather than partially supported.

Release notes:

- No Apple Developer Program membership is required for the v1 normal
  sleep-prevention scope.
- Normal runtime/use does not require admin privileges.
- Any future Bag Mode helper/admin approval flow is outside this release and is
  tracked separately in the post-v1 Bag Mode readiness issue.
