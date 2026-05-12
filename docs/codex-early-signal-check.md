# Codex Early Signal Check

Check date: May 12, 2026

Issue: [#7](https://github.com/makeavish/ClawShell/issues/7)

Follow-up: [#23](https://github.com/makeavish/ClawShell/issues/23)

Upstream source snapshot: [openai/codex `17ed5ad0b0abf78af1ed0044e2e63f593ad5f089`](https://github.com/openai/codex/tree/17ed5ad0b0abf78af1ed0044e2e63f593ad5f089)

## Question

Does Codex expose any source-backed lifecycle signal before legacy `notify` turn completion?

## Method

Checked the upstream `main` branch at commit `17ed5ad0b0abf78af1ed0044e2e63f593ad5f089`.

Search terms:

- `notify`
- `hooks`
- `HookEventName`
- `UserPromptSubmit`
- `SessionStart`
- `PreToolUse`
- `PostToolUse`
- `Stop`

Files inspected:

- [`codex-rs/core/src/config/mod.rs`](https://github.com/openai/codex/blob/17ed5ad0b0abf78af1ed0044e2e63f593ad5f089/codex-rs/core/src/config/mod.rs)
- [`codex-rs/config/src/config_toml.rs`](https://github.com/openai/codex/blob/17ed5ad0b0abf78af1ed0044e2e63f593ad5f089/codex-rs/config/src/config_toml.rs)
- [`codex-rs/config/src/hook_config.rs`](https://github.com/openai/codex/blob/17ed5ad0b0abf78af1ed0044e2e63f593ad5f089/codex-rs/config/src/hook_config.rs)
- [`codex-rs/protocol/src/protocol.rs`](https://github.com/openai/codex/blob/17ed5ad0b0abf78af1ed0044e2e63f593ad5f089/codex-rs/protocol/src/protocol.rs)
- [`codex-rs/hooks/src/legacy_notify.rs`](https://github.com/openai/codex/blob/17ed5ad0b0abf78af1ed0044e2e63f593ad5f089/codex-rs/hooks/src/legacy_notify.rs)
- [`codex-rs/hooks/src/events/`](https://github.com/openai/codex/tree/17ed5ad0b0abf78af1ed0044e2e63f593ad5f089/codex-rs/hooks/src/events)
- [`codex-rs/hooks/schema/generated/`](https://github.com/openai/codex/tree/17ed5ad0b0abf78af1ed0044e2e63f593ad5f089/codex-rs/hooks/schema/generated)
- [`codex-rs/config.md`](https://github.com/openai/codex/blob/17ed5ad0b0abf78af1ed0044e2e63f593ad5f089/codex-rs/config.md)
- [`docs/config.md`](https://github.com/openai/codex/blob/17ed5ad0b0abf78af1ed0044e2e63f593ad5f089/docs/config.md)

## Findings

Legacy `notify` is still completion-only. `codex-rs/core/src/config/mod.rs` describes `notify` as a command Codex spawns after each completed turn, with one appended JSON argument. `codex-rs/hooks/src/legacy_notify.rs` maps that compatibility payload from an `AfterAgent` hook event and includes user input messages, cwd, and assistant-message fields in the historical payload shape. ClawShell must keep treating `notify` as turn-complete evidence only and must keep redacting through its adapter.

Codex source now contains a broader hook surface. `codex-rs/config/src/config_toml.rs` has a top-level `hooks` field. `codex-rs/config/src/hook_config.rs` accepts hook events named `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`, `SessionStart`, `UserPromptSubmit`, and `Stop`, with command, prompt, and agent handler types. `codex-rs/protocol/src/protocol.rs` defines the same `HookEventName` variants.

The source-backed event set contains multiple candidates before or at turn completion. This table lists selected privacy-sensitive fields; every native Codex hook adapter must also drop transcript paths and avoid forwarding raw native payloads.

| Event | Selected privacy-sensitive fields | ClawShell implication |
|---|---|---|
| `SessionStart` | `session_id`, `cwd`, `transcript_path`, `model`, `permission_mode`, `source` | Candidate session start/resume signal. Must hash/redact cwd and avoid transcript paths. |
| `UserPromptSubmit` | `session_id`, `turn_id`, `cwd`, `transcript_path`, `model`, `permission_mode`, `prompt` | Candidate turn/activity start signal. Must never send prompt text to ClawShell. |
| `PreToolUse` | `session_id`, `turn_id`, `cwd`, `transcript_path`, `model`, `permission_mode`, `tool_name`, `tool_input`, `tool_use_id` | Candidate activity signal. Must not send raw tool input. |
| `PostToolUse` | `session_id`, `turn_id`, `cwd`, `transcript_path`, `model`, `permission_mode`, `tool_name`, `tool_input`, `tool_response`, `tool_use_id` | Candidate activity signal. Must not send raw tool input or output. |
| `Stop` | `session_id`, `turn_id`, `cwd`, `transcript_path`, `model`, `permission_mode`, `last_assistant_message`, `stop_hook_active` | Candidate completion signal richer than legacy `notify`. Must not send assistant text. |

The generated schemas under `codex-rs/hooks/schema/generated/` confirm command stdin shapes for these events. The two public config docs checked did not contain `hook`, `notify`, or the hook event names, so this is source-backed evidence rather than a docs-backed public-contract claim.

## Conclusion

The old TDD assumption that Codex has no earlier lifecycle signal before `notify` is false for the checked upstream source snapshot.

ClawShell should not change runtime behavior in this spike. The current implementation still patches only top-level `notify` and uses process detection as liveness backup. Native Codex hook support needs a dedicated implementation slice because the hook payloads include sensitive prompt, cwd, transcript, tool input, tool output, and assistant-message fields that must be reduced before reaching ClawShell.

Follow-up issue [#23](https://github.com/makeavish/ClawShell/issues/23) tracks upgrading the Codex integration from legacy `notify` to native hooks while preserving the existing `notify` fallback.
