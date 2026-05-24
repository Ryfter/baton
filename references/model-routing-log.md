# Model Routing Log

> **Append-only journal.** Three line types share the format:
> `ISO-timestamp | source | target | metric-or-detail | …`
>
> - `hook` — written by `~/.claude/hooks/log-tool-call.ps1` on every PostToolUse.
>   Format: `<ts> | hook | <tool>:<target> | <elapsed>s | exit:<n> | "<brief>"`
> - `otel` — written by `parse-otel.ps1` from Claude Code telemetry events.
>   Format: `<ts> | otel | <model> | in:<n> out:<n> | $<cost> | <event-type>`
> - `note` — written by `/log-routing` slash command (user/Claude qualitative).
>   Format: `<ts> | note | <model-or-target> | "<observation>"`
> - `dashboard` — written by the dashboard when a control action runs.
>   Format: `<ts> | dashboard | <action> | <target>` (Plan 2 only.)
>
> Consolidation (`/consolidate-routing`) reads everything since the last archive
> marker and proposes catalog updates, then archives consolidated entries to
> `~/.claude/model-routing-log-archive-YYYY-MM.md`.

# --- entries below this line ---
