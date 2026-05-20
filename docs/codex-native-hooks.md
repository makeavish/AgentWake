# Codex Native Hooks

Issue: [#23](https://github.com/makeavish/AgentWake/issues/23)

Source basis: [Codex Early Signal Check](codex-early-signal-check.md)

## Installed Config

AgentWake patches `~/.codex/config.toml` with one owned block marked by `com.agentwake.integration.codex-cli.v1`.

The owned block installs:

- Native Codex command hooks for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, and `Stop`
- A top-level legacy `notify` fallback
- A base64 copy of the previous top-level `notify` assignment when one existed

Existing user hooks are not rewritten. They remain outside the owned block. Removing the integration deletes only the owned block and restores the previous top-level `notify` assignment.

## Privacy Contract

Native Codex hook stdin is reduced before it reaches the control server. The adapter keeps only:

- Agent identity
- Resolved process id and process start time when available
- Event kind
- `session_id` or `turn_id` as the integration session id
- HMAC-SHA256 of `cwd` using the local AgentWake salt
- A stable namespaced replay id derived from native occurrence ids when possible

The adapter must not send prompt text, raw cwd, transcript paths, model names, permission mode, tool names, tool input, tool output, or assistant message text.

## Confidence Transitions

Process detection remains the liveness backup. A detected `codex` process creates or refreshes a process-scanned session with process-level confidence.

Native hooks provide integrated confidence:

- `SessionStart` is treated as a non-protecting startup/resume signal. It must not keep the Mac awake by itself because a long-lived app session is not proof of active agent work.
- `UserPromptSubmit` creates or refreshes an integrated active turn keyed by `turn_id`. If no tool activity or `Stop` follows, AgentWake expires the stale turn-start hold and falls back to process-only detection.
- `PreToolUse` keeps the matching turn active.
- `PostToolUse` keeps the matching turn active briefly after tool completion because the agent may continue the turn. If no `Stop` or further activity arrives, AgentWake expires this stale post-tool hold and falls back to process-only detection while the Codex desktop process remains open.
- `Stop` finishes the matching Codex turn and releases protection. The still-open Codex desktop process remains visible as process-only detection until new activity arrives.

Legacy Codex `notify` remains completion-only fallback evidence. It can finish a matching active turn, but it must not be treated as an early activity signal.

If the Codex process disappears, process reconciliation finishes the matching integrated session. If a native hook cannot be parsed or AgentWake is unavailable, the adapter exits successfully without blocking Codex.
