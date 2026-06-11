# Observation Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the observation layer for the coding-agent-orchestrator: a Claude Code PostToolUse hook that records every model dispatch to a journal, an OTel parser that adds token/cost data, two slash commands (`/log-routing` and `/consolidate-routing`), pre-populated catalog and journal files, and a minimal bootstrap script that deploys everything into `~/.claude/`.

**Architecture:** All PowerShell-native (no Python yet — that comes with the dashboard in Plan 2). The hook is a PowerShell script registered in `~/.claude/settings.json`. The OTel parser reads JSONL events emitted by Claude Code's built-in OpenTelemetry exporter and folds them into the same journal. Slash commands are markdown files in `~/.claude/commands/`. The catalog is a single markdown file Claude consults when routing decisions need more nuance than Octopus's auto-router provides. Source of truth is `D:\Dev\coding-agent-orchestrator`; bootstrap deploys.

**Tech Stack:** PowerShell 7+, Claude Code hooks, Claude Code OpenTelemetry exporter (per [monitoring docs](https://code.claude.com/docs/en/monitoring-usage)), markdown.

**Spec reference:** [`docs/superpowers/specs/2026-05-22-coding-agent-orchestrator-design.md`](../specs/2026-05-22-coding-agent-orchestrator-design.md) sections 1–5 and 7 (bootstrap, partial — dashboard parts deferred to Plan 2).

---

## Pre-Plan: Working Directory

All paths in this plan are relative to `D:\Dev\coding-agent-orchestrator` unless otherwise specified. Deployment targets are under `~/.claude/` (i.e. `%USERPROFILE%\.claude\`).

## Task 1: Investigate Claude Code OTel configuration

The OTel exporter env vars and event schema must be verified against current Claude Code docs before we write the parser. This task produces a notes file the rest of the plan references.

**Files:**
- Create: `docs/superpowers/notes/otel-findings.md`

- [ ] **Step 1: Fetch the Claude Code monitoring docs**

Use WebFetch or `Invoke-WebRequest` against `https://code.claude.com/docs/en/monitoring-usage`. Capture:
1. Exact env var names to enable OTel logs export (e.g. `OTEL_LOGS_EXPORTER`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_LOGS_EXPORT_INTERVAL`).
2. Supported exporter values (`console`, `otlp`, `file`?).
3. Event schema: what fields each log event carries — at minimum we need a timestamp, model name, input_tokens, output_tokens, and a cost field if Claude Code provides one.
4. Whether there's a way to write events to a local file directly, or only via an OTLP collector.

- [ ] **Step 2: Run a quick OTel capture experiment**

Set the env vars in a fresh PowerShell session, run a trivial Claude Code command (`claude -p "echo hello"` or whatever exists today), and capture one real event. Save a sanitized sample to `docs/superpowers/notes/otel-findings.md` under a `## Sample event` heading.

If Claude Code only supports OTLP-over-HTTP (not file), set up the simplest possible local collector to capture to file — `otelcol --config` with a `file/json` exporter — and document the collector config in the notes file. This is one-time setup.

- [ ] **Step 3: Write findings to notes file**

```markdown
# OTel Findings — Claude Code

**Date:** 2026-05-22

## Env vars

- `OTEL_LOGS_EXPORTER`: <value, e.g. "otlp" or "console">
- `OTEL_EXPORTER_OTLP_ENDPOINT`: <value>
- <any others>

## Exporter mode chosen

<console | otlp+local-collector | file — and why>

## Sample event (sanitized)

```json
{
  "timestamp": "...",
  "attributes": {
    "gen_ai.system": "anthropic",
    "gen_ai.request.model": "claude-sonnet-4-6",
    "gen_ai.usage.input_tokens": 1234,
    "gen_ai.usage.output_tokens": 567,
    ...
  }
}
```

## Field mapping for parser

| Journal field | OTel field |
|---|---|
| model | `attributes.gen_ai.request.model` |
| input_tokens | `attributes.gen_ai.usage.input_tokens` |
| output_tokens | `attributes.gen_ai.usage.output_tokens` |
| cost_usd | computed locally (no native field — use pricing table) OR `attributes.gen_ai.usage.cost_usd` if present |

## Local collector config (if needed)

<YAML or note "not needed">
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/notes/otel-findings.md
git commit -m "docs: investigate Claude Code OTel configuration and event schema"
```

---

## Task 2: Create the catalog seed (`references/model-routing.md`)

The catalog is the canonical reference Claude consults for nuanced routing decisions and the destination for promoted observations from the journal.

**Files:**
- Create: `references/model-routing.md`

- [ ] **Step 1: Write the catalog file with current inventory**

```markdown
# Model Routing Catalog

> **Purpose:** Reference for routing decisions when Octopus's auto-router isn't enough,
> and the destination for promoted observations from `model-routing-log.md`.
> Last consolidated: never (seeded 2026-05-22).

## How to use this file

- **Claude (orchestrator):** consult this file when:
  - Octopus's `/octo:auto` would pick a generic model but a specialty model fits better (commit messages, OCR, structured extraction).
  - You need to know which Ollama/LM Studio model is currently warm.
  - You need to know whether a cloud provider's quota is tight.
- **Consolidation flow (`/consolidate-routing`):** appends/edits sections here based on journal patterns.

## Specialty models (invoke directly via Bash, bypass Octopus)

### tavernari/git-commit-message (Ollama, 4.4 GB)

- **Use for:** generating commit messages from a diff.
- **Invoke:** `git diff --staged | ollama run tavernari/git-commit-message`
- **Strengths:** purpose-trained on commit message conventions; produces concise, conventional-commit-style output.
- **Weaknesses:** does nothing else; do not use for general text.
- **Cost tier:** free (local).

### nuextract (Ollama, ~2 GB once pulled)

- **Use for:** pulling structured JSON out of unstructured text per a schema.
- **Invoke:** `ollama run nuextract` with the schema and source text.
- **Strengths:** small, fast, deterministic-ish for extraction tasks.
- **Weaknesses:** weak for free-form generation; will refuse non-extraction tasks.
- **Cost tier:** free (local).
- **Status:** not yet pulled (bootstrap will pull).

### deepseek-ocr (Ollama, 6.7 GB)

- **Use for:** OCR of images / scanned documents.
- **Invoke:** `ollama run deepseek-ocr` with image attached.
- **Cost tier:** free (local).

## General coders (Octopus usually routes here automatically)

### Cloud — paid quota

| Model | Backend | Context | Strengths | Watch out for |
|---|---|---|---|---|
| Claude Sonnet 4.6 | via Claude Code itself | 200k | Reasoning, planning, orchestration | Quota cost — orchestrator only, push grunt work elsewhere |
| Codex (GPT-5.x) | `codex` CLI | 256k | General coding | Paid API |
| Gemini (latest) | `gemini` CLI | 1M | Huge-context summarization, cross-file analysis | Free tier, but rate-limited |
| Copilot CLI | `gh copilot` / `copilot` | varies | Covered by Education sub — cheap effective coder | Newer, less battle-tested |

### Local — Ollama (free)

| Model | Size | Strengths | Weaknesses | Status |
|---|---|---|---|---|
| `devstral:24b` | 14 GB | Multi-file refactors, code that needs context | Slow first-token | Pulled |
| `qwen3:30b` | 18 GB | General reasoning, coding | Big VRAM footprint | Pulled |
| `qwen2.5-coder:7b-instruct-q5_K_M` | ~5 GB | Fast cycle, boilerplate, renames | Weaker on multi-file logic | Not yet pulled |
| `deepseek-coder-v2:16b-lite-instruct-q5_K_M` | ~10 GB | Code review, diff explanation, bug spotting | Slower than 7b coders | Not yet pulled |
| `phi4:14b-q8_0` | 15 GB | Fast general reasoning | Less code-specialized | Pulled |
| `gpt-oss:20b` | 13 GB | General | Older | Pulled |
| `hermes3:8b` | ~5 GB | Function-calling / tool-use tuned | Not yet a primary path | Not yet pulled |

### Local — LM Studio (free)

JIT-loaded; first call to a not-yet-loaded model takes 5–30 s.

| Model | Strengths | Notes |
|---|---|---|
| `qwen/qwen3-coder-30b` | Top-tier local coder | Mirror of devstral lane |
| `qwen/qwen3.5-35b-a3b` | Big general | High VRAM |
| `google/gemma-3-27b` | General | Permissive license |
| `zai-org/glm-4.7-flash` | Fast general | |
| `openai_gpt-oss-20b` | General | Mirror of Ollama gpt-oss |
| `nvidia/nemotron-3-nano` | Fast | |
| `qwen2.5-0.5b-instruct` | Tiny — sanity checks only | |
| `llama-3.2-1b-instruct` | Tiny — sanity checks only | |
| Embeddings: `text-embedding-qwen3-embedding-8b`, `text-embedding-nomic-embed-text-v1.5` | RAG | |

### Vision / multimodal

- `llama3.2-vision:11b-instruct-q8_0` (Ollama) — general vision.
- `deepseek-ocr` — see specialty section.

## Routing heuristics (evolves via consolidation)

- **Commit messages:** always `tavernari/git-commit-message`. Never Octopus.
- **Structured JSON extraction:** `nuextract` if schema is clean; Octopus → cloud model if extraction is ambiguous.
- **Single-file refactor in a known language:** `local-coder` lane (devstral or qwen3-coder-30b).
- **Multi-file analysis / huge context:** Gemini via `/octo:auto`.
- **Code review / second opinion:** `deepseek-coder-v2:16b-lite-instruct`.
- **Trivial edits, renames, formatting:** `qwen2.5-coder:7b` (warm if available, otherwise phi4:14b).
- **Anything touching sensitive data:** local only (Ollama or LM Studio).

## Pricing table (for OTel cost computation)

USD per million tokens, input / output. Update when providers change pricing.

| Model | Input | Output |
|---|---|---|
| claude-sonnet-4-6 | $3 | $15 |
| claude-opus-4-7 | $15 | $75 |
| claude-haiku-4-5 | $1 | $5 |
| gpt-5 | $TBD | $TBD |
| gemini-2.5-pro | $TBD | $TBD |
| (local) | $0 | $0 |

Note: TBD entries get filled when first observed in a journal `otel` line — the parser
logs a warning and uses $0 until a price is added here.
```

- [ ] **Step 2: Commit**

```bash
git add references/model-routing.md
git commit -m "feat: seed model routing catalog with current inventory"
```

---

## Task 3: Create the journal seed (`references/model-routing-log.md`)

**Files:**
- Create: `references/model-routing-log.md`

- [ ] **Step 1: Write the journal seed**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add references/model-routing-log.md
git commit -m "feat: seed model routing log with format documentation"
```

---

## Task 4: Write the PostToolUse hook script

**Files:**
- Create: `scripts/hooks/log-tool-call.ps1`

The hook receives a JSON event on stdin (per [Claude Code hooks docs](https://www.morphllm.com/claude-code-hooks)). It extracts tool name, target/command, elapsed time, and exit status, then appends one line to `~/.claude/model-routing-log.md`. Errors go to a sibling error log so a buggy hook never breaks Claude Code.

- [ ] **Step 1: Write the failing test first**

Create `scripts/test-hook.ps1`:

```powershell
#!/usr/bin/env pwsh
# Test harness for scripts/hooks/log-tool-call.ps1
# Feeds canned PostToolUse events on stdin and asserts the journal line shape.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$hook = Join-Path $here 'hooks\log-tool-call.ps1'
$tmpLog = Join-Path $env:TEMP "test-journal-$(Get-Random).md"
$tmpErr = Join-Path $env:TEMP "test-journal-err-$(Get-Random).log"

$failures = 0
function Assert-Match($label, $actual, $pattern) {
    if ($actual -match $pattern) {
        Write-Host "PASS  $label" -ForegroundColor Green
    } else {
        Write-Host "FAIL  $label" -ForegroundColor Red
        Write-Host "      expected match: $pattern"
        Write-Host "      actual:         $actual"
        $script:failures++
    }
}

# Test 1: Bash tool calling ollama → hook records it
$event1 = @{
    tool_name = 'Bash'
    tool_input = @{ command = 'ollama run devstral:24b "refactor session.ts"' }
    tool_response = @{ exit_code = 0; duration_ms = 38000 }
} | ConvertTo-Json -Depth 5 -Compress

$event1 | & pwsh -NoProfile -File $hook -JournalPath $tmpLog -ErrorPath $tmpErr | Out-Null
$line = (Get-Content $tmpLog -Tail 1)
Assert-Match 'bash ollama line shape' $line '\| hook \| bash:ollama run devstral.*\| 38s \| exit:0'

# Test 2: Bash tool with non-zero exit
$event2 = @{
    tool_name = 'Bash'
    tool_input = @{ command = 'gemini -p "summarize foo"' }
    tool_response = @{ exit_code = 1; duration_ms = 4200 }
} | ConvertTo-Json -Depth 5 -Compress

$event2 | & pwsh -NoProfile -File $hook -JournalPath $tmpLog -ErrorPath $tmpErr | Out-Null
$line = (Get-Content $tmpLog -Tail 1)
Assert-Match 'bash gemini non-zero exit' $line '\| hook \| bash:gemini.*\| 4s \| exit:1'

# Test 3: Agent tool dispatch
$event3 = @{
    tool_name = 'Agent'
    tool_input = @{ subagent_type = 'octopus-coder'; description = 'implement TokenStore' }
    tool_response = @{ exit_code = 0; duration_ms = 51000 }
} | ConvertTo-Json -Depth 5 -Compress

$event3 | & pwsh -NoProfile -File $hook -JournalPath $tmpLog -ErrorPath $tmpErr | Out-Null
$line = (Get-Content $tmpLog -Tail 1)
Assert-Match 'agent subagent line shape' $line '\| hook \| agent:octopus-coder \| 51s \| exit:0 \| "implement TokenStore"'

# Test 4: Non-dispatch tool (Read) is skipped
$event4 = @{
    tool_name = 'Read'
    tool_input = @{ file_path = 'C:\foo.txt' }
    tool_response = @{ exit_code = 0; duration_ms = 12 }
} | ConvertTo-Json -Depth 5 -Compress

$before = (Get-Content $tmpLog).Count
$event4 | & pwsh -NoProfile -File $hook -JournalPath $tmpLog -ErrorPath $tmpErr | Out-Null
$after = (Get-Content $tmpLog).Count
if ($after -eq $before) {
    Write-Host "PASS  Read tool is skipped" -ForegroundColor Green
} else {
    Write-Host "FAIL  Read tool was not skipped (line count went $before -> $after)" -ForegroundColor Red
    $failures++
}

# Test 5: Malformed input does not crash; writes to error log
$badEvent = "not-json-at-all"
$badEvent | & pwsh -NoProfile -File $hook -JournalPath $tmpLog -ErrorPath $tmpErr 2>&1 | Out-Null
if (Test-Path $tmpErr) {
    Write-Host "PASS  malformed input handled (error log written)" -ForegroundColor Green
} else {
    Write-Host "FAIL  malformed input did not produce an error log" -ForegroundColor Red
    $failures++
}

Remove-Item $tmpLog, $tmpErr -ErrorAction SilentlyContinue

if ($failures -gt 0) {
    Write-Host "`n$failures test(s) failed" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nAll tests passed" -ForegroundColor Green
    exit 0
}
```

- [ ] **Step 2: Run the test, confirm it fails (hook doesn't exist yet)**

```powershell
pwsh -NoProfile -File scripts\test-hook.ps1
```

Expected: error like `Cannot find path '…\hooks\log-tool-call.ps1'`. This proves the test runs.

- [ ] **Step 3: Implement the hook**

Create `scripts/hooks/log-tool-call.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Claude Code PostToolUse hook: appends a one-line summary of every model dispatch
  to ~/.claude/model-routing-log.md.

.DESCRIPTION
  Reads a JSON event from stdin (Claude Code's hook protocol). Recognizes Bash
  invocations of model CLIs (ollama, gemini, codex, lms, copilot, gh copilot) and
  Agent tool dispatches. Skips everything else.

  Errors are written to ~/.claude/hooks/log-tool-call.err.log so a buggy hook
  never breaks Claude Code itself.

.PARAMETER JournalPath
  Override journal path (used by tests). Defaults to ~/.claude/model-routing-log.md.

.PARAMETER ErrorPath
  Override error log path (used by tests). Defaults to ~/.claude/hooks/log-tool-call.err.log.
#>

param(
    [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md'),
    [string]$ErrorPath   = (Join-Path $HOME '.claude/hooks/log-tool-call.err.log')
)

$ErrorActionPreference = 'Continue'  # never crash Claude Code; log and move on

# Patterns that identify a model-dispatch Bash command.
# Tune this list after first real Octopus run by inspecting ~/.claude-octopus/logs/.
$dispatchPatterns = @(
    '^\s*ollama\s+(run|generate|chat)\b',
    '^\s*gemini\b',
    '^\s*codex\b',
    '^\s*lms\b',
    '^\s*copilot\b',
    '^\s*gh\s+copilot\b',
    '^\s*claude\s+-p\b'   # nested Claude Code call
)

function Log-Error($msg) {
    try {
        $dir = Split-Path -Parent $ErrorPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $ts = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        Add-Content -Path $ErrorPath -Value "$ts | $msg"
    } catch {
        # Last resort: swallow. Never crash the hook.
    }
}

function Get-DispatchTarget($command) {
    foreach ($pattern in $dispatchPatterns) {
        if ($command -match $pattern) {
            # Extract first ~60 chars as the target description
            $snippet = $command.Trim()
            if ($snippet.Length -gt 60) { $snippet = $snippet.Substring(0, 60) + '…' }
            return $snippet
        }
    }
    return $null
}

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) {
        Log-Error "empty stdin"
        exit 0
    }

    $event = $raw | ConvertFrom-Json -ErrorAction Stop

    $toolName = $event.tool_name
    $exit     = if ($event.tool_response.exit_code -ne $null) { $event.tool_response.exit_code } else { 0 }
    $elapsed  = if ($event.tool_response.duration_ms) { [int]($event.tool_response.duration_ms / 1000) } else { 0 }
    $ts       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')

    $target = $null
    $brief  = ''

    switch ($toolName) {
        'Bash' {
            $cmd = $event.tool_input.command
            $target = Get-DispatchTarget $cmd
            if ($target) {
                $target = "bash:$target"
            }
        }
        'Agent' {
            $sub = $event.tool_input.subagent_type
            $desc = $event.tool_input.description
            if ($sub) {
                $target = "agent:$sub"
                $brief = $desc
            }
        }
        default {
            # Read, Write, Edit, Grep, Glob, etc. — not dispatches; skip.
        }
    }

    if (-not $target) {
        exit 0  # not a dispatch, nothing to log
    }

    # Build the journal line. Quote the brief if present.
    $line = "$ts | hook | $target | ${elapsed}s | exit:$exit"
    if ($brief) {
        $line += " | `"$brief`""
    }

    # Ensure journal dir exists
    $journalDir = Split-Path -Parent $JournalPath
    if (-not (Test-Path $journalDir)) {
        New-Item -ItemType Directory -Force -Path $journalDir | Out-Null
    }
    if (-not (Test-Path $JournalPath)) {
        Set-Content -Path $JournalPath -Value "# Model Routing Log`n# --- entries below this line ---"
    }

    Add-Content -Path $JournalPath -Value $line
    exit 0

} catch {
    Log-Error "hook crashed: $($_.Exception.Message); input was: $raw"
    exit 0  # never propagate failure
}
```

- [ ] **Step 4: Run the test, confirm it passes**

```powershell
pwsh -NoProfile -File scripts\test-hook.ps1
```

Expected: `All tests passed`.

If anything fails, fix the hook (not the test), and re-run.

- [ ] **Step 5: Commit**

```bash
git add scripts/hooks/log-tool-call.ps1 scripts/test-hook.ps1
git commit -m "feat: add PostToolUse hook that journals model dispatches"
```

---

## Task 5: Write the OTel JSONL parser

Reads the JSONL file Claude Code (or the local collector) writes, transforms each event into a journal `otel` line, and appends to the journal. Uses the pricing table in `model-routing.md` to compute cost. Idempotent — keeps a marker file of the last-processed byte offset so re-runs only append new entries.

**Files:**
- Create: `scripts/parse-otel.ps1`
- Create: `scripts/test-otel-parser.ps1`
- Create: `scripts/fixtures/otel-sample.jsonl`

- [ ] **Step 1: Write a sample OTel event fixture**

Based on Task 1's findings. If your real captured event differs from this fixture, update both this file and the parser accordingly.

Create `scripts/fixtures/otel-sample.jsonl`:

```jsonl
{"timestamp":"2026-05-22T14:32:15.123Z","severity":"INFO","body":"gen_ai.client.token.usage","attributes":{"gen_ai.system":"anthropic","gen_ai.request.model":"claude-sonnet-4-6","gen_ai.usage.input_tokens":3214,"gen_ai.usage.output_tokens":892,"gen_ai.operation.name":"chat"}}
{"timestamp":"2026-05-22T14:35:01.789Z","severity":"INFO","body":"gen_ai.client.token.usage","attributes":{"gen_ai.system":"anthropic","gen_ai.request.model":"claude-haiku-4-5","gen_ai.usage.input_tokens":512,"gen_ai.usage.output_tokens":128,"gen_ai.operation.name":"chat"}}
```

- [ ] **Step 2: Write the failing test**

Create `scripts/test-otel-parser.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$parser = Join-Path $here 'parse-otel.ps1'
$fixture = Join-Path $here 'fixtures\otel-sample.jsonl'
$tmpEvents = Join-Path $env:TEMP "otel-test-events-$(Get-Random).jsonl"
$tmpJournal = Join-Path $env:TEMP "otel-test-journal-$(Get-Random).md"
$tmpMarker = Join-Path $env:TEMP "otel-test-marker-$(Get-Random).txt"
$catalog = Join-Path (Split-Path $here -Parent) 'references\model-routing.md'

Copy-Item $fixture $tmpEvents
Set-Content $tmpJournal "# Model Routing Log`n# --- entries below this line ---"

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

& pwsh -NoProfile -File $parser `
    -EventsPath $tmpEvents `
    -JournalPath $tmpJournal `
    -MarkerPath $tmpMarker `
    -CatalogPath $catalog | Out-Null

$lines = Get-Content $tmpJournal
$otelLines = $lines | Where-Object { $_ -match '\| otel \|' }
Assert "two otel lines produced" ($otelLines.Count -eq 2)
Assert "first line model" ($otelLines[0] -match 'claude-sonnet-4-6')
Assert "first line tokens" ($otelLines[0] -match 'in:3214 out:892')
Assert "first line cost present" ($otelLines[0] -match '\| \$\d+\.\d+ \|')

# Idempotence: re-run should not duplicate
& pwsh -NoProfile -File $parser `
    -EventsPath $tmpEvents `
    -JournalPath $tmpJournal `
    -MarkerPath $tmpMarker `
    -CatalogPath $catalog | Out-Null

$linesAfter = Get-Content $tmpJournal
$otelLinesAfter = $linesAfter | Where-Object { $_ -match '\| otel \|' }
Assert "idempotent: no duplicates on second run" ($otelLinesAfter.Count -eq 2)

# Append new event: re-run should pick up just the new one
Add-Content $tmpEvents -Value '{"timestamp":"2026-05-22T14:40:00.000Z","attributes":{"gen_ai.request.model":"claude-sonnet-4-6","gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":50}}'

& pwsh -NoProfile -File $parser `
    -EventsPath $tmpEvents `
    -JournalPath $tmpJournal `
    -MarkerPath $tmpMarker `
    -CatalogPath $catalog | Out-Null

$linesFinal = Get-Content $tmpJournal
$otelLinesFinal = $linesFinal | Where-Object { $_ -match '\| otel \|' }
Assert "picks up newly appended event" ($otelLinesFinal.Count -eq 3)

Remove-Item $tmpEvents, $tmpJournal, $tmpMarker -ErrorAction SilentlyContinue

if ($failures -gt 0) {
    Write-Host "`n$failures test(s) failed" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nAll tests passed" -ForegroundColor Green
    exit 0
}
```

- [ ] **Step 3: Run the test, confirm it fails (parser doesn't exist yet)**

```powershell
pwsh -NoProfile -File scripts\test-otel-parser.ps1
```

Expected: error about missing `parse-otel.ps1`.

- [ ] **Step 4: Implement the parser**

Create `scripts/parse-otel.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Reads new OpenTelemetry log events from a JSONL file, transforms each into
  a journal `otel` line, appends to the routing journal.

.DESCRIPTION
  Idempotent via a marker file recording the last-processed byte offset.
  Pricing is read from the catalog's pricing table for cost computation.
  Events without a known model in the pricing table get cost $0 and a warning.
#>

param(
    [string]$EventsPath  = (Join-Path $HOME '.claude/telemetry/events.jsonl'),
    [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md'),
    [string]$MarkerPath  = (Join-Path $HOME '.claude/telemetry/.parse-marker'),
    [string]$CatalogPath = (Join-Path $HOME '.claude/model-routing.md')
)

$ErrorActionPreference = 'Stop'

function Parse-PricingTable($catalogPath) {
    # Reads the catalog's "## Pricing table" markdown table; returns
    # @{ 'model-name' = @{ input = <decimal>; output = <decimal> } } in $/M tokens.
    $prices = @{}
    if (-not (Test-Path $catalogPath)) { return $prices }
    $content = Get-Content $catalogPath -Raw
    if ($content -notmatch '(?ms)## Pricing table.*?\n(\|.*?)(?:\n##|\z)') {
        return $prices
    }
    $tableText = $Matches[1]
    foreach ($line in $tableText -split "`n") {
        if ($line -match '^\|\s*([\w\.-]+)\s*\|\s*\$?([\d\.]+|TBD)\s*\|\s*\$?([\d\.]+|TBD)\s*\|') {
            $model = $Matches[1]
            $in    = if ($Matches[2] -eq 'TBD') { $null } else { [decimal]$Matches[2] }
            $out   = if ($Matches[3] -eq 'TBD') { $null } else { [decimal]$Matches[3] }
            if ($in -ne $null -and $out -ne $null) {
                $prices[$model] = @{ input = $in; output = $out }
            }
        }
    }
    return $prices
}

function Compute-Cost($model, $inTokens, $outTokens, $prices) {
    if (-not $prices.ContainsKey($model)) {
        return @{ cost = 0.0; warning = "no price for model '$model' in catalog" }
    }
    $p = $prices[$model]
    $cost = ($inTokens / 1000000.0) * $p.input + ($outTokens / 1000000.0) * $p.output
    return @{ cost = [math]::Round($cost, 4); warning = $null }
}

if (-not (Test-Path $EventsPath)) {
    # No events file yet — nothing to do
    exit 0
}

# Determine where to start reading (line-count marker, robust across text encodings)
$skipCount = 0
if (Test-Path $MarkerPath) {
    $skipCount = [int]((Get-Content $MarkerPath -Raw).Trim())
}

$allLines = @(Get-Content $EventsPath)
if ($skipCount -ge $allLines.Count) {
    exit 0  # nothing new
}

$prices = Parse-PricingTable $CatalogPath

# Ensure journal exists
$journalDir = Split-Path -Parent $JournalPath
if (-not (Test-Path $journalDir)) { New-Item -ItemType Directory -Force -Path $journalDir | Out-Null }
if (-not (Test-Path $JournalPath)) {
    Set-Content -Path $JournalPath -Value "# Model Routing Log`n# --- entries below this line ---"
}

$newJournalLines = @()
$warnings = @()

for ($i = $skipCount; $i -lt $allLines.Count; $i++) {
    $line = $allLines[$i]
    if (-not $line) { continue }
    try {
        $evt = $line | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $warnings += "skipped malformed JSONL line at index $i"
        continue
    }
    $attrs = $evt.attributes
    if (-not $attrs) { continue }
    $model = $attrs.'gen_ai.request.model'
    $inTok = [int]($attrs.'gen_ai.usage.input_tokens')
    $outTok = [int]($attrs.'gen_ai.usage.output_tokens')
    if (-not $model -or ($inTok -eq 0 -and $outTok -eq 0)) { continue }

    $ts = if ($evt.timestamp) { $evt.timestamp } else { (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz') }
    $costResult = Compute-Cost $model $inTok $outTok $prices
    if ($costResult.warning) { $warnings += $costResult.warning }
    $costStr = "{0:F4}" -f $costResult.cost

    $opName = if ($attrs.'gen_ai.operation.name') { $attrs.'gen_ai.operation.name' } else { 'chat' }
    $newJournalLines += "$ts | otel | $model | in:$inTok out:$outTok | `$$costStr | $opName"
}

if ($newJournalLines.Count -gt 0) {
    Add-Content -Path $JournalPath -Value ($newJournalLines -join "`n")
}

# Update marker — total lines processed so far
$markerDir = Split-Path -Parent $MarkerPath
if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Force -Path $markerDir | Out-Null }
Set-Content -Path $MarkerPath -Value $allLines.Count.ToString()

if ($warnings.Count -gt 0) {
    foreach ($w in ($warnings | Select-Object -Unique)) {
        Write-Warning $w
    }
}

Write-Host "Processed $($newJournalLines.Count) new event(s); marker at line $($allLines.Count)"
```

- [ ] **Step 5: Run the test, confirm it passes**

```powershell
pwsh -NoProfile -File scripts\test-otel-parser.ps1
```

Expected: `All tests passed`.

- [ ] **Step 6: Verify against the real captured event from Task 1**

Take the sample event you captured in `docs/superpowers/notes/otel-findings.md` and run the parser against it directly:

```powershell
# Save your captured event as a one-line JSONL file
$realEvent = '<paste sanitized captured event here>'
$tmp = [System.IO.Path]::GetTempFileName()
Set-Content $tmp $realEvent
pwsh -NoProfile -File scripts\parse-otel.ps1 `
    -EventsPath $tmp `
    -JournalPath "$env:TEMP\real-test.md" `
    -MarkerPath "$env:TEMP\real-test.marker" `
    -CatalogPath references\model-routing.md
Get-Content "$env:TEMP\real-test.md"
Remove-Item $tmp, "$env:TEMP\real-test.md", "$env:TEMP\real-test.marker"
```

If the real event produced an `otel` line with the right model/tokens/cost, you're done. If field names differ from the fixture (e.g. `gen_ai.request.model` vs something else), update both `scripts/fixtures/otel-sample.jsonl` and the parser's field lookups, then re-run Step 5 to confirm tests still pass.

- [ ] **Step 7: Commit**

```bash
git add scripts/parse-otel.ps1 scripts/test-otel-parser.ps1 scripts/fixtures/otel-sample.jsonl
git commit -m "feat: add OTel JSONL parser with idempotent marker tracking"
```

---

## Task 6: Write the `/log-routing` slash command

A slash command is a markdown file in `~/.claude/commands/`. The frontmatter describes the command; the body is the prompt Claude executes when the command is invoked.

**Files:**
- Create: `commands/log-routing.md`

- [ ] **Step 1: Write the slash command**

```markdown
---
description: Append a one-line qualitative note about a model's recent performance to the routing journal. Use after a notable dispatch when the result deserves remembering ("devstral nailed the refactor style", "gemini bailed halfway through").
argument-hint: <model-or-target> <free-text observation>
---

# /log-routing

You are appending a single qualitative note to the model routing journal at
`~/.claude/model-routing-log.md`. The format is:

```
<ISO-timestamp> | note | <model-or-target> | "<observation>"
```

## Steps

1. Parse the arguments. The first whitespace-delimited token is the model or
   target (e.g. `devstral:24b`, `gemini`, `codex`, `octopus-coder`). Everything
   after is the observation text. If arguments are empty, ask the user what they
   want to log and what model/target it applies to.

2. Construct the timestamp in ISO 8601 format with timezone:
   `Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'`

3. Append the line using PowerShell:

   ```powershell
   $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
   $target = '<first-token>'
   $obs = '<observation, with double quotes escaped>'
   $line = "$ts | note | $target | `"$obs`""
   Add-Content -Path "$HOME/.claude/model-routing-log.md" -Value $line
   ```

4. Confirm to the user: show the exact line that was appended.

## Arguments

$ARGUMENTS
```

- [ ] **Step 2: Commit**

```bash
git add commands/log-routing.md
git commit -m "feat: add /log-routing slash command for qualitative model notes"
```

---

## Task 7: Write the `/consolidate-routing` slash command

This command runs the consolidation flow: read recent journal, analyze patterns, propose catalog updates, archive consolidated entries.

**Files:**
- Create: `commands/consolidate-routing.md`

- [ ] **Step 1: Write the slash command**

```markdown
---
description: Review recent model-routing journal entries, propose updates to the catalog (`model-routing.md`), and on approval archive the consolidated entries. Run periodically (weekly to monthly) or when you suspect routing defaults need tuning.
argument-hint: (no arguments)
---

# /consolidate-routing

You are running the routing consolidation flow. Your job is to:

1. Read recent observations.
2. Detect patterns (model X failed N times on Y, model Z costs $W on average).
3. Propose specific catalog edits.
4. Get user approval.
5. Apply the edits, archive the consolidated entries.

## Steps

### 1. Read the inputs

- Read `~/.claude/model-routing-log.md` (the journal).
- Find the most recent archive marker line (a line of the form
  `<!-- archived through: YYYY-MM-DDTHH:MM:SS -->`). Entries below it are
  "since-last-consolidation." If no marker exists, treat all entries as new.
- Read `~/.claude/model-routing.md` (the catalog).
- Read `~/.claude-octopus/results/` (if it exists) — list the most recent run
  directories to cross-reference patterns.

### 2. Analyze

Group journal entries by model. For each model with ≥3 entries since last
consolidation, compute:

- **Success rate** (hook lines: exit:0 vs non-zero).
- **Avg cost** (otel lines: $ amount).
- **Avg elapsed time** (hook lines: Ns).
- **Qualitative tone** (note lines: any words like "nailed", "bailed", "ugly",
  "matched style" — pull verbatim).

Identify:

- Models with notable success or failure patterns (e.g. devstral:24b failed
  4/5 multi-file refactors).
- Models with cost surprises (e.g. claude-opus averaged $0.42/run, 5× others).
- Models with consistent qualitative praise or complaint.

### 3. Propose catalog updates

Present a numbered list of proposed edits to `~/.claude/model-routing.md`.
Each proposal must be specific:

> 1. In `## Routing heuristics`, change "Single-file refactor in a known
>    language: `local-coder` lane (devstral or qwen3-coder-30b)" to
>    "...prefer qwen3-coder-30b; devstral failed 4 of 5 refactors in May
>    (see archive)."

### 4. Get user approval

For each proposed edit, ask: keep, modify, or skip. Apply approved edits using
the Edit tool.

### 5. Archive

After edits are applied, append an archive marker to the journal:

```
<!-- archived through: <ISO-timestamp-of-newest-consolidated-entry> -->
```

Then move all entries above the new marker (since the previous marker) to
`~/.claude/model-routing-log-archive-YYYY-MM.md`, appending if the archive
file exists.

### 6. Summarize

Report to the user: how many entries consolidated, how many catalog edits
applied, where the archive landed.

## Arguments

(none)
```

- [ ] **Step 2: Commit**

```bash
git add commands/consolidate-routing.md
git commit -m "feat: add /consolidate-routing slash command for periodic catalog tuning"
```

---

## Task 8: Write the minimal bootstrap script (Plan 1 scope)

Deploys Plan 1's outputs into `~/.claude/`. Idempotent. Plan 2 will extend this with dashboard setup.

**Files:**
- Create: `scripts/bootstrap.ps1`

- [ ] **Step 1: Write the bootstrap script**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Bootstraps the coding-agent-orchestrator observation layer into ~/.claude/.

.DESCRIPTION
  Idempotent. Re-runnable. Plan 1 scope: deploys hook, OTel env config, slash
  commands, catalog seed, journal seed. Verifies backends. Plan 2 will extend
  with Python venv and dashboard setup.
#>

param(
    [switch]$DryRun,
    [switch]$Force  # overwrite the catalog without prompting
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$claudeDir = Join-Path $HOME '.claude'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    ok: $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "    skip: $msg" -ForegroundColor Yellow }
function Write-Warn($msg) { Write-Host "    warn: $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "    err: $msg" -ForegroundColor Red }

function Copy-IfMissing($src, $dst, $label) {
    if (Test-Path $dst) {
        Write-Skip "$label already exists at $dst"
        return $false
    }
    if ($DryRun) { Write-Ok "[dry-run] would copy $label -> $dst"; return $true }
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    Copy-Item $src $dst
    Write-Ok "$label -> $dst"
    return $true
}

function Copy-WithPrompt($src, $dst, $label) {
    if (Test-Path $dst) {
        if ($Force) {
            if ($DryRun) { Write-Ok "[dry-run] would overwrite $label at $dst (--Force)"; return }
            Copy-Item $src $dst -Force
            Write-Ok "$label overwritten at $dst (--Force)"
            return
        }
        $srcHash = (Get-FileHash $src).Hash
        $dstHash = (Get-FileHash $dst).Hash
        if ($srcHash -eq $dstHash) { Write-Skip "$label already up-to-date at $dst"; return }
        $ans = Read-Host "    $label at $dst differs from repo. Overwrite? [y/N]"
        if ($ans -ne 'y') { Write-Skip "kept existing $label"; return }
    }
    if ($DryRun) { Write-Ok "[dry-run] would copy $label -> $dst"; return }
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    Copy-Item $src $dst -Force
    Write-Ok "$label -> $dst"
}

# --- Step 1: Verify Octopus is installed ---
Write-Step "Verifying claude-octopus is installed"
$octoCheck = & claude plugin list 2>&1 | Out-String
if ($octoCheck -match 'octo@nyldn-plugins') {
    Write-Ok "claude-octopus detected"
} else {
    Write-Warn "claude-octopus not detected. Install with:"
    Write-Host "      claude plugin marketplace add https://github.com/nyldn/plugins.git"
    Write-Host "      claude plugin install octo@nyldn-plugins"
    Write-Host "      Then re-run this bootstrap."
    exit 1
}

# --- Step 2: Deploy the hook ---
Write-Step "Deploying PostToolUse hook"
$hookSrc = Join-Path $repoRoot 'scripts\hooks\log-tool-call.ps1'
$hookDst = Join-Path $claudeDir 'hooks\log-tool-call.ps1'
Copy-WithPrompt $hookSrc $hookDst 'hook script'

# --- Step 3: Merge settings.json PostToolUse entry ---
Write-Step "Registering hook in settings.json"
$settingsPath = Join-Path $claudeDir 'settings.json'
if (-not (Test-Path $settingsPath)) {
    if ($DryRun) { Write-Ok "[dry-run] would create $settingsPath" }
    else { Set-Content $settingsPath '{}'; Write-Ok "created empty settings.json" }
}
$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
if (-not $settings.hooks) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject) -Force }
if (-not $settings.hooks.PostToolUse) { $settings.hooks | Add-Member -NotePropertyName PostToolUse -NotePropertyValue @() -Force }

$hookEntry = @{
    matcher = '*'
    hooks = @(@{
        type = 'command'
        command = "pwsh -NoProfile -File `"$hookDst`""
    })
}

# Check for existing entry pointing to our hook
$exists = $false
foreach ($e in $settings.hooks.PostToolUse) {
    foreach ($h in $e.hooks) {
        if ($h.command -like "*log-tool-call.ps1*") { $exists = $true }
    }
}
if ($exists) {
    Write-Skip "hook already registered in settings.json"
} elseif ($DryRun) {
    Write-Ok "[dry-run] would add PostToolUse entry pointing to $hookDst"
} else {
    $settings.hooks.PostToolUse += $hookEntry
    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath
    Write-Ok "added PostToolUse entry to settings.json"
}

# --- Step 4: Deploy OTel env config helper ---
Write-Step "Deploying OTel env config helper"
$otelEnvSrc = Join-Path $repoRoot 'scripts\otel-env.ps1'
$otelEnvDst = Join-Path $claudeDir 'otel-env.ps1'
# Generate the helper inline if not present in repo
if (-not (Test-Path $otelEnvSrc)) {
    if (-not $DryRun) {
        @'
# Source this file in your PowerShell profile to enable Claude Code OTel export.
# Adjust env var names per docs/superpowers/notes/otel-findings.md if needed.
$env:OTEL_LOGS_EXPORTER = 'otlp'   # or 'console' / 'file' depending on findings
$env:OTEL_EXPORTER_OTLP_ENDPOINT = 'http://localhost:4318'  # local collector
$env:OTEL_SERVICE_NAME = 'claude-code'
# Telemetry write target (where the collector or exporter dumps JSONL):
$env:CCO_TELEMETRY_PATH = (Join-Path $HOME '.claude/telemetry/events.jsonl')
'@ | Set-Content $otelEnvSrc
    }
}
Copy-WithPrompt $otelEnvSrc $otelEnvDst 'OTel env helper'

# Ensure telemetry dir exists
$telDir = Join-Path $claudeDir 'telemetry'
if (-not (Test-Path $telDir)) {
    if ($DryRun) { Write-Ok "[dry-run] would create $telDir" }
    else { New-Item -ItemType Directory -Force -Path $telDir | Out-Null; Write-Ok "created $telDir" }
}

Write-Warn "Manual step: dot-source $otelEnvDst from your PowerShell profile, or run before each Claude Code session."

# --- Step 5: Deploy slash commands ---
Write-Step "Deploying slash commands"
foreach ($cmd in @('log-routing.md', 'consolidate-routing.md')) {
    $src = Join-Path $repoRoot "commands\$cmd"
    $dst = Join-Path $claudeDir "commands\$cmd"
    Copy-WithPrompt $src $dst "command: $cmd"
}

# --- Step 6: Deploy catalog and journal seeds ---
Write-Step "Deploying catalog and journal"
$catSrc = Join-Path $repoRoot 'references\model-routing.md'
$catDst = Join-Path $claudeDir 'model-routing.md'
Copy-WithPrompt $catSrc $catDst 'routing catalog'

$logSrc = Join-Path $repoRoot 'references\model-routing-log.md'
$logDst = Join-Path $claudeDir 'model-routing-log.md'
Copy-IfMissing $logSrc $logDst 'routing journal (never overwritten)'

# --- Step 7: Verify backends ---
Write-Step "Verifying backends reachable"
$backends = @(
    @{ name = 'gemini';    test = { gemini --version 2>&1 | Out-String } },
    @{ name = 'codex';     test = { codex --version 2>&1 | Out-String } },
    @{ name = 'ollama';    test = { ollama --version 2>&1 | Out-String } },
    @{ name = 'lms';       test = { lms version 2>&1 | Out-String } },
    @{ name = 'gh';        test = { gh --version 2>&1 | Out-String } },
    @{ name = 'LM Studio HTTP'; test = {
        try { Invoke-RestMethod 'http://localhost:1234/v1/models' -TimeoutSec 3 | Out-Null; "ok" }
        catch { "unreachable: $($_.Exception.Message)" }
    } }
)
foreach ($b in $backends) {
    try {
        $out = & $b.test 2>&1
        if ($LASTEXITCODE -eq 0 -or $out -match 'ok|version|v\d') { Write-Ok "$($b.name): reachable" }
        else { Write-Warn "$($b.name): $out" }
    } catch { Write-Warn "$($b.name): $($_.Exception.Message)" }
}

# --- Summary ---
Write-Step "Bootstrap complete (Plan 1 scope)"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Source the OTel env helper in your PowerShell profile or before each session:"
Write-Host "       . $otelEnvDst"
Write-Host "  2. Run a real Claude Code task to populate the journal."
Write-Host "  3. Inspect $logDst to see hook + otel lines."
Write-Host "  4. After a week of use, run /consolidate-routing to tune the catalog."
Write-Host ""
Write-Host "Plan 2 (dashboard) will extend this script with Python venv + FastAPI app setup."
```

- [ ] **Step 2: Write a smoke test for the bootstrap**

Create `scripts/test-bootstrap.ps1`:

```powershell
#!/usr/bin/env pwsh
# Smoke test: run bootstrap in dry-run mode against a temp HOME, assert no crash
# and that the dry-run output mentions each expected component.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bootstrap = Join-Path $here 'bootstrap.ps1'

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# Run dry-run; capture stdout
$out = & pwsh -NoProfile -File $bootstrap -DryRun 2>&1 | Out-String

Assert "mentions hook deployment"        ($out -match 'PostToolUse hook')
Assert "mentions OTel env helper"        ($out -match 'OTel env')
Assert "mentions slash commands"         ($out -match 'slash commands')
Assert "mentions catalog deployment"     ($out -match 'catalog')
Assert "mentions backend verification"   ($out -match 'Verifying backends')
Assert "does not exit non-zero"          ($LASTEXITCODE -eq 0 -or $out -match 'Bootstrap complete')

if ($failures -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 3: Run the bootstrap smoke test**

```powershell
pwsh -NoProfile -File scripts\test-bootstrap.ps1
```

Expected: `All tests passed` (or all PASS lines, no FAIL).

If the Octopus check fails because it isn't installed, install it per spec or comment out the Octopus block temporarily to validate the rest. Re-enable before committing.

- [ ] **Step 4: Run the bootstrap for real (against your actual ~/.claude)**

```powershell
pwsh -NoProfile -File scripts\bootstrap.ps1
```

Watch each step. Approve prompts as desired. Verify after:

```powershell
Test-Path "$HOME\.claude\hooks\log-tool-call.ps1"          # True
Test-Path "$HOME\.claude\model-routing.md"                  # True
Test-Path "$HOME\.claude\model-routing-log.md"              # True
Test-Path "$HOME\.claude\commands\log-routing.md"           # True
Test-Path "$HOME\.claude\commands\consolidate-routing.md"   # True
Get-Content "$HOME\.claude\settings.json" | Select-String 'log-tool-call'  # one match
```

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 scripts/otel-env.ps1
git commit -m "feat: add minimal bootstrap script (Plan 1 scope)"
```

---

## Task 9: End-to-end smoke test

Trigger real Claude Code tool calls and verify the journal grows correctly.

- [ ] **Step 1: Restart Claude Code so the hook registers**

Close any active Claude Code session. Open a fresh one in this repo:

```powershell
claude
```

- [ ] **Step 2: Trigger a Bash dispatch through Claude**

In the Claude Code session, ask it to do something that requires `ollama` or `gemini`:

> "Run `ollama list` and tell me which models I have."

Claude will execute a Bash tool call. The hook should fire on completion.

- [ ] **Step 3: Verify the hook line appeared in the journal**

```powershell
Get-Content "$HOME\.claude\model-routing-log.md" -Tail 5
```

Expected: at least one line of the form `<ts> | hook | bash:ollama list | …`.

If no hook line appears:
- Check `~/.claude/hooks/log-tool-call.err.log` for errors.
- Verify the hook is wired up: `Get-Content ~/.claude/settings.json | Select-String 'log-tool-call'`.
- Confirm `pwsh` is on PATH (the hook command in settings.json invokes `pwsh`).

- [ ] **Step 4: Trigger OTel events and run the parser**

Run a Claude Code task that uses tokens (any real interaction does). Then:

```powershell
pwsh -NoProfile -File scripts\parse-otel.ps1
Get-Content "$HOME\.claude\model-routing-log.md" -Tail 10
```

Expected: at least one `| otel |` line.

If no events file appears at `~/.claude/telemetry/events.jsonl`, your OTel exporter isn't writing there. Verify the env vars are set in the Claude Code session (`$env:OTEL_LOGS_EXPORTER`, etc.) and the collector (if used) is running. Adjust the OTel env helper per your findings, re-source it, and re-run a Claude Code task.

- [ ] **Step 5: Try the slash commands**

In Claude Code:

```
/log-routing devstral:24b nailed the test refactor, matched style perfectly
```

Then:

```powershell
Get-Content "$HOME\.claude\model-routing-log.md" -Tail 1
```

Expected: a `| note | devstral:24b | "nailed the test refactor, matched style perfectly"` line.

- [ ] **Step 6: Commit anything that needed adjustment**

If you tuned the OTel env helper, dispatch patterns, or fixture during E2E:

```bash
git add -A
git commit -m "fix: adjust observation layer based on E2E smoke test findings"
```

---

## Task 10: Write the Plan 1 README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the README**

```markdown
# coding-agent-orchestrator

Claude Code as a command-and-control layer for a fleet of coding LLMs.
Adopts [claude-octopus](https://github.com/nyldn/claude-octopus) as the dispatch
layer; builds observation (hooks, OpenTelemetry, slash commands, journal,
catalog) and — in Plan 2 — a live web dashboard on top.

**Status:** Plan 1 (observation foundation) shipped.

## Quick start

```powershell
# 1. Install Octopus (one-time)
claude plugin marketplace add https://github.com/nyldn/plugins.git
claude plugin install octo@nyldn-plugins

# 2. Bootstrap this repo's observation layer
git clone <this repo> D:\Dev\coding-agent-orchestrator
cd D:\Dev\coding-agent-orchestrator
pwsh -NoProfile -File scripts\bootstrap.ps1

# 3. Enable OTel export in your PowerShell profile
notepad $PROFILE
# add: . $HOME\.claude\otel-env.ps1

# 4. Restart Claude Code and use it normally.
```

## What you get (Plan 1)

- `~/.claude/hooks/log-tool-call.ps1` — PostToolUse hook that journals every
  model dispatch.
- `~/.claude/model-routing-log.md` — append-only journal with three line types
  (`hook`, `otel`, `note`).
- `~/.claude/model-routing.md` — catalog of every model you can route to, with
  strengths/weaknesses and pricing.
- `~/.claude/commands/log-routing.md` — `/log-routing <model> <obs>` for
  qualitative notes.
- `~/.claude/commands/consolidate-routing.md` — `/consolidate-routing` to
  periodically promote journal observations into the catalog.
- `scripts/parse-otel.ps1` — converts Claude Code's OTel JSONL events into
  journal `otel` lines with cost computation.

## Coming in Plan 2

Local web dashboard at `http://localhost:8765` with live activity, today's
spend, recent journal, model leaderboard, and controls
(load/unload LM Studio models, stop Ollama models, kill stuck PIDs).

## Architecture

See [`docs/superpowers/specs/2026-05-22-coding-agent-orchestrator-design.md`](docs/superpowers/specs/2026-05-22-coding-agent-orchestrator-design.md).

## Tests

```powershell
pwsh -NoProfile -File scripts\test-hook.ps1
pwsh -NoProfile -File scripts\test-otel-parser.ps1
pwsh -NoProfile -File scripts\test-bootstrap.ps1
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add Plan 1 README"
```

---

## Self-Review (post-write)

Spec sections covered by Plan 1:

| Spec § | Component | Plan task |
|---|---|---|
| §1 | Octopus (adopted) | Task 8 verifies install |
| §2 | PostToolUse hook | Task 4 |
| §3 | OTel exporter + parser | Tasks 1, 5 |
| §4 | `/log-routing` | Task 6 |
| §5 | Catalog + journal + consolidation | Tasks 2, 3, 7 |
| §7 (partial) | Bootstrap (Plan 1 subset) | Task 8 |
| §6 (Dashboard) | — | **Deferred to Plan 2** |

Type consistency: journal line shapes are defined in Task 3 (seed) and produced by Tasks 4 (hook), 5 (otel parser), 6 (slash command). Format is consistent across all four: `<ISO-ts> | <source> | <target> | <details>`.

Placeholder scan: the OTel field names in Task 5 are best-effort based on OTel semantic conventions; Task 1 explicitly verifies them against real captured events and Task 5 Step 6 reconciles. Pricing table has `TBD` entries — these are intentional (filled when first observed), and the parser handles them gracefully with a warning. No other placeholders.

Spec requirement gaps: none in Plan 1's scope. Dashboard (§6) is intentionally deferred — that's a separate plan.

---

## Plan Complete

Plan 1 is comprehensive: 10 tasks, each broken into 2–6 short steps with full code, exact paths, and verification commands. Working software at the end: journal grows automatically, slash commands work, catalog is populated.

**Plan 2 (Dashboard) will be written next** — only after Plan 1 ships and we know the journal format and OTel parser behave as designed in real use. Writing Plan 2 prematurely risks designing the dashboard against assumptions the foundation invalidates.
