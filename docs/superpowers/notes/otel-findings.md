# OTel Findings — Claude Code

**Date:** 2026-05-23 (docs); smoke-test findings added 2026-05-24
**Source:** https://code.claude.com/docs/en/monitoring-usage (fetched via WebFetch on 2026-05-23)
**Status:** Env vars and event schema from official docs. Console exporter format and capture method **confirmed via live smoke test (Task 9)** on 2026-05-24.

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

## Exporter mode chosen — confirmed findings (smoke test 2026-05-24)

**Confirmed: `console` exporter. OTel events are on STDOUT, not stderr.**

### OTel is on stdout — but only in non-interactive (--print) mode

Claude Code writes OTel events to **stdout** when running in `--print` mode
(non-interactive). In interactive TTY mode, OTel output is suppressed to avoid
polluting the terminal display.

**Correct capture for automated/subagent tasks:**
```powershell
claude -p "your prompt" >> $env:CCO_TELEMETRY_PATH
```
The response text AND OTel events both appear in stdout. The parser filters to
`api_request` blocks only and discards the rest.

**Interactive sessions:** OTel not available via console exporter. The PostToolUse
hook covers dispatch tracking. Plan 2 adds an `otelcol` daemon for full coverage.

### What does NOT work

```powershell
# WRONG 1 — pipes stdout, breaks interactive mode:
claude 2>&1 | Tee-Object -FilePath "..."

# WRONG 2 — captures stderr only, OTel is on stdout:
claude 2>> telemetry/events.jsonl
```

### Console exporter format is JS object literals, NOT JSONL

Each event is a **multi-line JavaScript-style object** (not JSON):
- Property names are unquoted (e.g. `body:` not `"body":`)
- Missing optional values appear as `undefined` (not `null`)
- Events separated by blank lines; file is NOT valid JSON/JSONL

The parser handles this format with regex-based block splitting.
Format auto-detection: JSONL starts with `{"`, JS format starts with `{\n`.

### api_request event — confirmed live capture

Confirmed via `claude -p "What is 1+1?" >> captureFile`:
```
2026-05-24T05:04:00.079+00:00 | otel | claude-sonnet-4-6 | in:3 out:4 | $0.0587 | api_request
```
- `in:3` = new (non-cached) input tokens
- `cost_usd` = $0.0587 = total cost including ~195K cached system-prompt tokens
- `cost_usd` correctly captures the real billing cost even when token counts look small

### Hook registration confirmed

PostToolUse hook with matcher `*` at `event.sequence: 10` in every session startup
confirms `log-tool-call.ps1` is correctly registered.

---

## Confirmed sample events (smoke test 2026-05-24)

The fixture in `scripts/fixtures/otel-sample.jsonl` uses the confirmed JS format.
The `api_request` event was also confirmed live (see "confirmed live capture" above).

Sample `plugin_loaded` event (sanitized — confirmed format):

```
{
  resource: {
    attributes: {
      "host.arch": "amd64",
      "os.type": "windows",
      "os.version": "10.0.26200",
      "service.name": "claude-code",
      "service.version": "2.1.150",
    },
  },
  instrumentationScope: {
    name: "com.anthropic.claude_code.events",
    version: "2.1.150",
    schemaUrl: undefined,
  },
  timestamp: 1779596413614000,
  traceId: undefined,
  spanId: undefined,
  traceFlags: undefined,
  severityText: undefined,
  severityNumber: undefined,
  body: "claude_code.plugin_loaded",
  attributes: {
    "session.id": "8131b826-...",
    "terminal.type": "windows-terminal",
    "event.name": "plugin_loaded",
    "event.timestamp": "2026-05-24T04:20:13.614Z",
    "event.sequence": 0,
    "plugin.name": "superpowers",
    has_hooks: true,
    has_mcp: false,
  },
}
```

**TODO (next smoke test):** capture a live `api_request` event to confirm:
1. Are token counts bare integers or quoted strings?
2. Is `cost_usd` always present on every `api_request`?
3. What does `query_source` look like for subagent dispatches?

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

## Open questions (updated after smoke test)

| # | Question | Status |
|---|----------|--------|
| 1 | Console exporter format — JSONL or pretty-printed? | ✅ **Confirmed: multi-line JS objects** (not JSONL). Parser updated. |
| 2 | OTel on stdout or stderr? | ✅ **Confirmed: stdout** in `--print` mode only. Suppressed in interactive TTY mode. |
| 3 | Does `cost_usd` appear on every `api_request`? | ✅ **Confirmed: yes**. $0.0587 seen on live capture. Includes cache costs. |
| 4 | Token counts — bare integers or quoted strings? | ✅ **Confirmed: bare integers** (`input_tokens: 3`). Parser handles both anyway. |
| 5 | `OTEL_LOGS_EXPORT_INTERVAL` flush reliability? | ✅ **1000ms works**. Set in otel-env.ps1. |
| 6 | `query_source` field format for subagents? | ❓ Not yet captured from a subagent session. |
| 7 | `prompt.id` always present on `api_request`? | ❓ Not yet confirmed. |
