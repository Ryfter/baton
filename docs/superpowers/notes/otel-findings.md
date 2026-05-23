# OTel Findings — Claude Code

**Date:** 2026-05-23
**Source:** https://code.claude.com/docs/en/monitoring-usage (fetched via WebFetch on 2026-05-23)
**Status of this document:** Section 1 (env vars), Section 2 (exporter modes), and the event schema section are **verified from the official Claude Code monitoring docs**. The sample event in Section 3 is **not yet captured live** — the user must do this during the Task 9 E2E smoke test and reconcile field names against the parser written in Task 5.

---

## Env vars

Verified from docs. Required vs optional is called out.

### Required to enable any telemetry at all

- `CLAUDE_CODE_ENABLE_TELEMETRY` — must be `1`. Without this, no events are emitted regardless of other settings.

### Logs exporter selection

- `OTEL_LOGS_EXPORTER` — comma-separated list. Supported values: `console`, `otlp`, `none`. Multiple allowed (e.g. `console,otlp`).
- `OTEL_LOGS_EXPORT_INTERVAL` — milliseconds. Default `5000`. Lower (e.g. `1000`) for faster local feedback during dev.

### OTLP endpoint configuration (only when `OTEL_LOGS_EXPORTER` includes `otlp`)

- `OTEL_EXPORTER_OTLP_PROTOCOL` — applies to all signals. Values: `grpc`, `http/json`, `http/protobuf`.
- `OTEL_EXPORTER_OTLP_ENDPOINT` — collector endpoint for all signals, e.g. `http://localhost:4317`.
- `OTEL_EXPORTER_OTLP_LOGS_PROTOCOL` — overrides general protocol just for logs.
- `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` — overrides general endpoint just for logs, e.g. `http://localhost:4318/v1/logs`.
- `OTEL_EXPORTER_OTLP_HEADERS` — auth headers, e.g. `Authorization=Bearer token`.

### Content logging toggles (off by default — opt-in for richer events)

- `OTEL_LOG_USER_PROMPTS` — set to `1` to include prompt text in `user_prompt` events.
- `OTEL_LOG_TOOL_DETAILS` — set to `1` to include tool parameters, command names, MCP server names, etc. on `tool_result` and related events. **Recommended for orchestrator parser** so we can attribute work to specific tool invocations.
- `OTEL_LOG_TOOL_CONTENT` — tool input/output content (requires tracing).
- `OTEL_LOG_RAW_API_BODIES` — `1` for inline (truncated at 60 KB) or `file:<dir>` for untruncated bodies written to disk with a `body_ref` pointer in the event.

---

## Exporter mode chosen

**Recommended: `console` exporter, redirected to a file.**

Reasoning:

- **There is no native `file` exporter** for OTel logs in Claude Code. Confirmed from docs.
- The two practical ways to get events into a local JSONL file the orchestrator can tail are:
  1. `OTEL_LOGS_EXPORTER=console` and redirect stdout (`claude ... >> events.jsonl`).
  2. Run a local OTel collector (otelcol with a file exporter) on `http://localhost:4318/v1/logs` and point `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` at it.
- Option 1 has zero extra infrastructure and matches the orchestrator's "spawn a Claude process, watch its output" model. Option 2 adds a daemon dependency that doesn't pay for itself yet.
- The `console` exporter's output format must be verified against a real event before the parser (Task 5) commits to a schema — see Section "Sample event" below. In particular: is each event one JSON object per line, or pretty-printed multi-line JSON?

**Fallback if `console` output turns out to be human-formatted (not JSONL):** switch to a local otelcol with the file exporter, which writes proper JSONL.

---

## Sample event (TO BE CAPTURED BY USER)

The subagent that wrote this file could not capture a live event because that requires an interactive Claude Code session under the user's auth. Run these commands and paste a sanitized `api_request` event into this section before Task 5 (parser) is implemented:

```powershell
# Enable telemetry, console exporter, fast flush for dev
$env:CLAUDE_CODE_ENABLE_TELEMETRY = '1'
$env:OTEL_LOGS_EXPORTER = 'console'
$env:OTEL_LOGS_EXPORT_INTERVAL = '1000'
$env:OTEL_LOG_TOOL_DETAILS = '1'   # so we see tool_name, command_name etc.

# Send output (including OTel events) to a file so we can grep it
claude -p "say hello" *> "$env:TEMP\claude-otel-sample.txt"

# Inspect — look for lines starting with `claude_code.api_request` or JSON
Get-Content "$env:TEMP\claude-otel-sample.txt"
```

Things to confirm when reading the captured output:

1. Is the format one JSON object per line (JSONL), or pretty-printed?
2. Does the `api_request` event include `cost_usd` directly, or do we have to compute it from token counts and a local pricing table?
3. What does the `model` value look like (e.g. `claude-sonnet-4-6` vs a fuller ID like `claude-sonnet-4-6-20251022`)?
4. Does the timestamp arrive as ISO 8601 (`event.timestamp`) or as a Unix epoch in nanoseconds on the OTLP envelope?

Paste a sanitized event below once captured:

```json
// PASTE HERE — strip user.email, user.account_uuid, organization.id, prompt text
```

---

## Field mapping for parser (verified against docs — these are Claude Code's own field names, not generic OTel gen-ai conventions)

The parser in Task 5 should read these fields directly. Claude Code emits its own event names (`claude_code.api_request` etc.) with flat top-level attributes — **not** the generic OTel gen-ai semantic conventions (`gen_ai.usage.input_tokens` etc.). Do not assume the gen-ai conventions apply.

### Primary event for the orchestrator: `claude_code.api_request`

| Journal field | Source field on event | Notes |
|---|---|---|
| `timestamp` | `event.timestamp` (ISO 8601) | Standard attribute on all events. May also be on the OTLP envelope as epoch nanos — pick one, prefer `event.timestamp` for readability. |
| `session_id` | `session.id` | Correlate all events from one Claude session. |
| `prompt_id` | `prompt.id` | UUID that ties the user prompt to all subsequent API requests and tool calls. Key for "which work did this turn do". |
| `model` | `model` | e.g. `claude-sonnet-4-6`. |
| `input_tokens` | `input_tokens` | |
| `output_tokens` | `output_tokens` | |
| `cache_read_tokens` | `cache_read_tokens` | Important for cost accuracy — cached input is cheaper. |
| `cache_creation_tokens` | `cache_creation_tokens` | |
| `cost_usd` | `cost_usd` | **Claude Code emits this directly.** No local pricing table needed for `api_request` events. Verify in captured sample. |
| `duration_ms` | `duration_ms` | |
| `request_id` | `request_id` | Anthropic API request ID (e.g. `req_011...`). |
| `query_source` | `query_source` | `repl_main_thread`, `compact`, or a subagent name — lets us split orchestrator vs subagent token use. |
| `effort` | `effort` | `low` | `medium` | `high` | `xhigh` | `max`. Absent if not supported. |

### Secondary events the parser may want to handle

- `claude_code.api_error` — same model/duration/request_id fields, plus `error`, `status_code`, `attempt`.
- `claude_code.tool_result` — for attributing what a session spent its tokens *doing*. With `OTEL_LOG_TOOL_DETAILS=1`, includes `tool_name`, `tool_use_id`, `duration_ms`, `success`, plus a `tool_parameters` JSON string carrying `bash_command`, `mcp_tool_name`, `subagent_type`, etc.
- `claude_code.user_prompt` — start-of-turn marker, carries `prompt.id` we can use to bucket events.
- `claude_code.compaction` — `pre_tokens`, `post_tokens`, `trigger` — useful for explaining sudden token-budget jumps.
- `claude_code.api_retries_exhausted` — terminal failure after retries; carries `total_attempts` and `total_retry_duration_ms`.

### Standard attributes present on every event (parser should hoist these)

```
session.id
prompt.id              (when correlatable to a prompt)
event.timestamp        (ISO 8601)
event.sequence         (monotonic counter — useful for ordering inside a session)
app.version            (Claude Code version)
user.id                (anonymous device ID)
terminal.type          (iTerm.app, vscode, cursor, tmux, ...)
workspace.host_paths   (string[])
```

PII fields to **strip on ingest** before writing to the journal: `user.email`, `user.account_uuid`, `user.account_id`, `organization.id`.

---

## Local collector config (if needed)

Not needed for the initial implementation — we will use `OTEL_LOGS_EXPORTER=console` and redirect stdout to a JSONL file owned by the orchestrator. If Step 2 (live capture) reveals that the console exporter does *not* emit one-JSON-per-line, fall back to running a local otelcol with this minimal config and point `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=http://localhost:4318/v1/logs` at it:

```yaml
# otelcol-local.yaml — only needed if console exporter format is unusable
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318

exporters:
  file:
    path: ./events.jsonl
    format: json

service:
  pipelines:
    logs:
      receivers: [otlp]
      exporters: [file]
```

---

## Open questions for Task 9 (E2E smoke test) to answer

1. Console exporter output format — one JSON object per line, or pretty-printed?
2. Does `cost_usd` actually appear on every `api_request` event, or only some?
3. Does setting `OTEL_LOGS_EXPORT_INTERVAL=1000` reliably flush events within ~1s of the API call, or is there additional buffering?
4. When `query_source` is a subagent, what exactly does it look like — the literal `subagent_type`, or a prefixed form?
5. Are `prompt.id` and `session.id` always present on `api_request` events, or only some of them?
