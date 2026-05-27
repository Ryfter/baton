# Plan 4 — Fleet Config + Multi-Machine Local + Dispatch Primitive — Design

**Date:** 2026-05-26
**Status:** Draft, awaiting user review
**Author:** Kevin Rank (with Claude)
**Predecessors:** Plan 1 (observation), Plan 2 (dashboard), Plan 3 (job scaffold + KB), Plan 3.5 (cleanup)
**Successors:** Plans 5 (research ensemble), 6 (code farm-out), 7 (review + cockpit)

---

## Umbrella context (where Plan 4 fits)

Plan 3 made *jobs* a persistent thing on disk with phase tracking, KB capture, and dashboard visibility — but the orchestrator still cannot actually invoke any LLM other than this Claude Code session itself. Plan 4 turns "knows there are models out there" into "can actually invoke them." It is the foundation that Plans 5-7 will dispatch through.

```
Plan 1 ─────────────────────────────────────────── ✓ shipped
  observation: hook + OTel + journal + catalog

Plan 2 ─────────────────────────────────────────── ✓ shipped
  dashboard: FastAPI + htmx at localhost:8765

Plan 3 ─────────────────────────────────────────── ✓ shipped
  job scaffold + KB: slash commands, phase tagging, knowledge base

Plan 3.5 ───────────────────────────────────────── ✓ shipped
  cleanup: KB paths, htmx polling, test fidelity

Plan 4 (this) ──────────────────────────────────── ← we are here
  fleet config + multi-machine + dispatch primitive

Plan 5 ──────────────────────────────────────────── not started
  research phase: ensemble across fleet, 6-Hats + LLM Council primitives

Plan 6 ──────────────────────────────────────────── not started
  code phase: decompose + parallel worktrees + farm-out

Plan 7 ──────────────────────────────────────────── not started
  review phase + analytics cockpit
```

**Approach C** (chosen during Plan 3 brainstorming) carries forward: Claude Code is the orchestrator; persistent on-disk config (`fleet.yaml`) is the contract; CLI-first invocation; designed to be shareable to other users.

## Purpose

Three concrete deliverables:

1. **Fleet registry** — `~/.claude/fleet.yaml` enumerates every callable provider with the minimum metadata needed to invoke it. Lean schema; qualitative "which model for what" data continues to live in `~/.claude/knowledge/universal/routing.md`.
2. **Dispatch primitive** — invoking any fleet member from PowerShell or a slash command returns a captured response, with the invocation journaled.
3. **Health-check** — `fleet doctor` reports which providers are reachable / configured / disabled, so the user (and Plans 5+) can rely on a known-good fleet.

The smallest useful slice. Plans 5-7 build on top.

## Non-goals (deferred to later plans)

- **Ensemble dispatch** (fan a prompt to N providers simultaneously, collect responses). Plan 5.
- **Vote / sanity-check primitives** (6 Hats, LLM Council). Plan 5.
- **Decompose + parallel-worktree farm-out for coding.** Plan 6.
- **Pair review** (Claude + Codex on the diff). Plan 7.
- **Dashboard Fleet panel** (visual fleet state alongside Jobs panel). Plan 7 cockpit.
- **Direct API providers** (raw OpenAI/Anthropic API, OpenRouter). Future fleet expansion. The schema must NOT preclude adding these later, but Plan 4 ships CLI-first + LM Studio HTTP only.
- **Streaming responses.** Plan 7.
- **Per-call cost tracking for non-Claude providers.** Plan 7 analytics. (Claude's own cost continues to flow through Plan 1's OTel exporter.)
- **Concurrent multi-provider invocation in one call.** Plan 4 dispatches one provider per `/fleet test`. Concurrency is Plan 5.

## Architecture overview

```
       ┌────────────────────────────────────────────────────────────┐
       │   CLAUDE CODE (this session) = THE ORCHESTRATOR            │
       │                                                             │
       │   New slash command:                                       │
       │     /fleet doctor                                          │
       │     /fleet test <name> "<prompt>" [--model <m>]            │
       │     /fleet list                                            │
       └─────────────────────┬───────────────────────────────────────┘
                             │
              ┌──────────────┴──────────────┐
              ▼                              ▼
       scripts/fleet-doctor.ps1     scripts/fleet-lib.ps1
       (health probe walks fleet)   (shared library)
              │                              │
              │   reads                      │   reads + dispatches
              ▼                              ▼
              ~/.claude/fleet.yaml ─────────────────────►  Invoke-Fleet
                    (registry)                                  │
                                                                │
              For kind: cli    ──── command_template substitution
                                    pwsh -NoProfile -Command "..."
                                    (env vars applied + restored)

              For kind: http   ──── dot-source scripts/fleet/<name>.ps1
                                    call Invoke-<Name> function
                                    (HTTP request via Invoke-RestMethod)
                                                                │
                                                                ▼
              Every invocation, regardless of kind:
                  → writes "ts | fleet | <name> | <Ns>s | exit:N | "<prompt-summary>""
                    to ~/.claude/model-routing-log.md
                  → picks up Plan 3 state-file tags: " | job:... | phase:..."
```

**Source of truth:** repo at `D:\Dev\coding-agent-orchestrator`. Bootstrap script deploys `fleet.yaml` seed, `fleet-lib.ps1`, `fleet-doctor.ps1`, escape-hatch scripts, and the new slash command into `~/.claude/`.

## Components

### 1. `fleet.yaml` schema

Lean. Carries only what's needed to invoke. Qualitative capabilities live in `~/.claude/knowledge/universal/routing.md`.

```yaml
providers:
  - name: claude-cli
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'claude -p "{{prompt}}"'

  - name: codex
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'codex exec "{{prompt}}"'

  - name: gemini-antigravity
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'antigravity --prompt "{{prompt}}"'

  - name: gh-copilot
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'gh copilot suggest "{{prompt}}"'

  - name: opencode
    kind: cli
    enabled: false                          # not installed by default
    cost_tier: free
    command_template: 'opencode -p "{{prompt}}"'

  - name: ollama-local
    kind: cli
    enabled: true
    cost_tier: local
    model_default: 'devstral:24b'
    command_template: 'ollama run {{model}} "{{prompt}}"'

  - name: ollama-box2                       # example second-machine entry
    kind: cli
    enabled: false                          # user enables when ready
    cost_tier: local
    model_default: 'qwen3:30b'
    env:
      OLLAMA_HOST: 'http://CHANGE-ME-HOSTNAME:11434'
    command_template: 'ollama run {{model}} "{{prompt}}"'

  - name: lm-studio
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    model_default: 'auto'                   # script picks the loaded model
```

**Field rules:**

| Field | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | Unique key. `[a-z0-9-]+`. Used as `<provider>` arg to `/fleet test`. |
| `kind` | enum | yes | `cli` or `http`. Determines dispatch path. |
| `enabled` | bool | yes | Soft toggle. Doctor warns if a disabled provider is referenced; dispatcher refuses to invoke. |
| `cost_tier` | enum | yes | `paid` \| `free` \| `local`. Plans 5+ filter on this. `local` distinct from `free` because VRAM/latency. |
| `command_template` | string | required for `kind: cli` | Mustache-style. `{{prompt}}` mandatory; `{{model}}` optional. |
| `model_default` | string | optional | Fallback when `--model` not specified at call site. |
| `env` | map[string]string | optional | Env vars to set in current scope before invoking, restored after. The Tailscale / SSH-tunnel story rides on this — change `OLLAMA_HOST` value, no code change. |
| `base_url` | string | required for `kind: http` | Per-provider script reads it. |

**Sharable-design check:** the seed has `CHANGE-ME-HOSTNAME` placeholders for any user-specific paths; all multi-machine entries default to `enabled: false`. No personal hostnames in the repo.

### 2. `scripts/fleet-lib.ps1` — shared library

Dot-sourced by dispatcher + doctor + tests + the slash command.

```
Read-Fleet                            → parses fleet.yaml into [hashtable[]]
Get-FleetProvider <name>              → returns one provider hashtable or $null
Resolve-FleetCommand <provider> <prompt> [<model>]
                                      → substitutes {{prompt}} + {{model}}
Invoke-Fleet <provider-name> <prompt> [<model>]
                                      → main entry. Dispatches cli vs http.
                                        Returns @{ stdout; stderr; exit_code; duration_s }.
                                        Writes the journal line on completion.
Write-FleetJournalLine <provider> <duration_s> <exit_code> <prompt>
                                      → appends to ~/.claude/model-routing-log.md.
                                        Picks up Plan 3 state-file tags via
                                        Read-CurrentJob (from job-lib.ps1).
```

YAML parsing uses a minimal hand-rolled parser (no external module — matches Plan 3's `Read-Manifest` style). The schema is shallow enough to parse with a few regexes; if it ever grows, switch to a real YAML module.

### 3. Generic CLI dispatcher (`kind: cli` path)

Inside `Invoke-Fleet`:

```powershell
function Invoke-Fleet-Cli {
    param($provider, $prompt, $model)
    $cmd = Resolve-FleetCommand -Provider $provider -Prompt $prompt -Model $model

    # Set provider's env vars in current scope, restore after
    $saved = @{}
    if ($provider.env) {
        foreach ($k in $provider.env.Keys) {
            $saved[$k] = [System.Environment]::GetEnvironmentVariable($k)
            [System.Environment]::SetEnvironmentVariable($k, $provider.env[$k])
        }
    }
    try {
        $start = Get-Date
        $stdout = & pwsh -NoProfile -Command $cmd 2>&1
        $exit = $LASTEXITCODE
        $duration = [int]((Get-Date) - $start).TotalSeconds
        return @{ stdout = $stdout; exit_code = $exit; duration_s = $duration }
    } finally {
        foreach ($k in $saved.Keys) {
            [System.Environment]::SetEnvironmentVariable($k, $saved[$k])
        }
    }
}
```

Default timeout 120 s, configurable per-provider with `timeout_s` field (not in initial seed; documented in schema reference).

### 4. Per-provider HTTP escape hatches (`kind: http` path)

One PowerShell script per HTTP provider, under `scripts/fleet/<name>.ps1`. Convention: define a function `Invoke-<PascalName>` that takes `($provider, $prompt, $model)` and returns `@{ stdout; exit_code; duration_s; stderr? }`.

Name → function conversion is mechanical: split the fleet entry's `name` on hyphens, capitalise each segment, concatenate, prepend `Invoke-`. So `lm-studio` → `Invoke-LmStudio`, `openai-api` → `Invoke-OpenaiApi`, `gh-copilot` (if it were HTTP) → `Invoke-GhCopilot`. The dispatcher computes this name and resolves it via `Get-Command` after dot-sourcing the script.

`scripts/fleet/lm-studio.ps1`:

```powershell
# LM Studio OpenAI-compatible API at $provider.base_url
function Invoke-LmStudio {
    param($provider, $prompt, $model)
    $endpoint = "$($provider.base_url)/v1/chat/completions"
    $modelName = if ($model) { $model } else {
        # auto: query /v1/models, take the first loaded one
        $models = Invoke-RestMethod "$($provider.base_url)/v1/models"
        $models.data[0].id
    }
    $body = @{
        model    = $modelName
        messages = @(@{ role = 'user'; content = $prompt })
        stream   = $false
    } | ConvertTo-Json -Depth 10

    $start = Get-Date
    try {
        $resp = Invoke-RestMethod -Uri $endpoint -Method Post -Body $body `
                                  -ContentType 'application/json' -TimeoutSec 120
        $text = $resp.choices[0].message.content
        $duration = [int]((Get-Date) - $start).TotalSeconds
        return @{ stdout = $text; exit_code = 0; duration_s = $duration }
    } catch {
        $duration = [int]((Get-Date) - $start).TotalSeconds
        return @{ stdout = ''; exit_code = 1; duration_s = $duration;
                  stderr = $_.Exception.Message }
    }
}
```

**Adding a new HTTP provider later:** drop `scripts/fleet/<new-name>.ps1` defining `Invoke-<NewName>`, add the fleet.yaml entry with `kind: http` + `base_url`. The dispatcher dot-sources the script and calls the conventional function name.

### 5. `scripts/fleet-doctor.ps1` — health-check probe

Walks `fleet.yaml`, reports status of each provider.

| Provider kind | Check |
|---|---|
| `cli` enabled | (1) Resolve first token of `command_template` via `Get-Command` — is the binary on PATH? (2) Run a lightweight version probe (`--version` or per-provider override via `health_check` field — not in initial seed). (3) For providers with `env: { OLLAMA_HOST: ... }`, also `Invoke-WebRequest -Method Head $env_value` to confirm the remote host responds. |
| `http` enabled | `Invoke-WebRequest -Method Head $base_url` — does it respond? Optionally hit `/v1/models` to confirm the API is up (LM Studio convention). |
| `enabled: false` | Print `skip` row. No probes. |

Output:

```
NAME                STATUS    DETAIL
claude-cli          ok        v1.x.x detected
codex               ok        v0.y.z detected
gemini-antigravity  ok        v…
gh-copilot          ok        gh 2.x + copilot extension
opencode            skip      disabled in fleet.yaml
ollama-local        ok        v0.6.x; 14 models loaded
ollama-box2         skip      disabled in fleet.yaml
lm-studio           ok        http://localhost:1234 alive; 2 models loaded
```

Exit code: 0 if every enabled provider is `ok`; 1 if any is `warn` or `err`. Useful as a precondition for Plan 5+ ensemble dispatch.

### 6. `commands/fleet.md` — single subcommand-dispatched slash command

```
/fleet doctor                           → runs fleet-doctor.ps1, prints the table
/fleet test <name> "<prompt>" [--model <m>]
                                        → runs Invoke-Fleet, prints the response inline
/fleet list                             → Read-Fleet | Format-Table — quick summary,
                                          no network probes (cheaper than doctor)
```

Dispatch: the slash command parses `$ARGUMENTS`'s first whitespace-delimited token as the subcommand (`doctor` / `test` / `list`). If the first token is none of those, treat as an error and print the usage. If `test`, the next token is `<name>`, then a quoted string is `<prompt>`, and `--model <m>` is optional.

`/fleet test` output:

```
> /fleet test ollama-local "Write a one-line Python function that returns the nth Fibonacci."

▶ ollama-local (ollama run devstral:24b ...)
  
def fib(n): return n if n<2 else fib(n-1)+fib(n-2)

✓ 3s exit:0
```

Journal line gets written automatically by the dispatcher.

### 7. Journal integration

New `fleet` source type, joins the `hook` / `otel` / `note` / `lesson` / `dashboard` family from Plan 3:

```
2026-05-26T16:00:00-06:00 | fleet | lm-studio | 4s | exit:0 | "Refactor session.ts to use TokenStore" | job:j-... | phase:research
```

Dispatcher writes this line regardless of `cli` or `http` kind — HTTP invocations (which the Plan 1 hook can't see) still land in the journal. CLI invocations get journaled twice (once by `Write-FleetJournalLine`, once by the Plan 1 hook's `bash:<command>` line). Intentional redundancy: the `fleet` line carries the provider name explicitly while the hook line carries the raw shell command; both are useful for different analyses.

Format: `timestamp | fleet | <name> | <Ns> | exit:N | "<prompt-summary>"`. Prompt summary is truncated to 100 chars, pipes sanitized to `¦` (matches Plan 2 rule).

The dashboard's existing journal parser already handles trailing `job:` / `phase:` tags universally (Plan 3 `_extract_trailing_tags`). It needs a small extension to recognize the `fleet` source type so the drill-in journal stream can render it — but that extension is **deferred to Plan 7's cockpit work**. For Plan 4, the fleet lines exist in the journal raw; the dashboard simply skips them in display (the parser returns `None` for unknown source types).

## End-to-end example

Outside any job:

```
> /fleet doctor

NAME                STATUS    DETAIL
claude-cli          ok        v1.x.x
codex               ok        v0.y.z
gemini-antigravity  ok        v0.z.x
gh-copilot          ok        gh 2.62 + copilot extension
opencode            skip      disabled
ollama-local        ok        v0.6.0; 14 models loaded
ollama-box2         skip      disabled
lm-studio           ok        http://localhost:1234 alive; 2 models loaded

7 enabled providers, all ok.
```

Inside an active job:

```
> /job-start "test fleet plumbing"
Job started: j-2026-05-26-test-fleet-plumbing  phase: research

> /fleet test ollama-local "What's 2+2?"

▶ ollama-local (ollama run devstral:24b ...)

The answer is 4.

✓ 2s exit:0

> /fleet test lm-studio "Same question."

▶ lm-studio (http POST http://localhost:1234/v1/chat/completions)

2 + 2 = 4.

✓ 3s exit:0
```

The journal (`~/.claude/model-routing-log.md`) now contains:

```
2026-05-26T16:00:00-06:00 | fleet | ollama-local | 2s | exit:0 | "What's 2+2?" | job:j-2026-05-26-test-fleet-plumbing | phase:research
2026-05-26T16:00:03-06:00 | fleet | lm-studio   | 3s | exit:0 | "Same question." | job:j-2026-05-26-test-fleet-plumbing | phase:research
```

Plus, for the `ollama-local` call, the Plan 1 hook also wrote:
```
2026-05-26T16:00:00-06:00 | hook | bash:ollama run devstral:24b ... | 2s | exit:0 | job:j-2026-05-26-test-fleet-plumbing | phase:research
```

That intentional duplication carries both the provider abstraction (`fleet | ollama-local`) and the raw command (`hook | bash:ollama run ...`).

## Error handling

| Failure | Behavior |
|---|---|
| `~/.claude/fleet.yaml` missing | Friendly error pointing at bootstrap: *"Run `scripts/bootstrap.ps1` to deploy fleet.yaml seed."* |
| `fleet.yaml` malformed | Print parse error + offending line; do not proceed. |
| `/fleet test <unknown-name>` | Error + list of valid provider names. |
| `/fleet test <disabled-name>` | *"Provider X is disabled in fleet.yaml. Edit and set `enabled: true` to use."* |
| CLI binary not on PATH | Dispatcher returns `exit_code = -1`, `stderr = 'command not found'`. Journal still records the attempt. |
| HTTP provider unreachable | Per-provider script catches, returns `exit_code = 1` + stderr in result. Journal records. |
| Long-running invocation | Default timeout 120 s. If exceeded, kill process, return `exit_code = -2`, `stderr = 'timeout after 120s'`. |
| Env-var setting fails (e.g., permission) | Logged warning; dispatcher proceeds without that env var; CLI may fail downstream which is captured normally. |
| `scripts/fleet/<name>.ps1` missing for `kind: http` provider | Error: *"Provider X requires scripts/fleet/X.ps1 (with Invoke-X function)."* |

## Testing strategy

All PowerShell, matching project pattern. No new Python tests in Plan 4 (the dashboard integration is deferred to Plan 7).

- **`scripts/test-fleet-lib.ps1`** — unit tests for:
  - `Read-Fleet` parses sample fleet.yaml fixtures (valid, malformed, empty)
  - `Get-FleetProvider` returns expected provider or `$null`
  - `Resolve-FleetCommand` substitutes `{{prompt}}` and `{{model}}` correctly; handles missing-model fallback to `model_default`; rejects templates lacking `{{prompt}}`
  - Env-var apply-and-restore behavior (set a var, run a no-op, verify var is back to original)
  - `Write-FleetJournalLine` produces the expected line format; picks up active-job state file when present

- **`scripts/test-fleet-doctor.ps1`** — fixture fleet.yaml with mix of `ok` / `skip` / `err` providers (using a fake unreachable host for one, a disabled entry for another, a valid `cli` entry for the third — `pwsh` as the "binary" since it's always available). Verifies the tabular output structure and the exit code (0 for all-ok, 1 for any-err).

- **`scripts/test-fleet-dispatch.ps1`** — end-to-end with a STUB provider:
  ```yaml
  - name: stub-cli
    kind: cli
    enabled: true
    cost_tier: free
    command_template: 'pwsh -NoProfile -Command "Write-Output hello-{{prompt}}"'
  ```
  Verifies: response is captured (`hello-foo` for prompt `foo`), journal line is written, env vars are restored, duration is measured. Plus an HTTP stub using a fake `scripts/fleet/stub-http.ps1` that returns a canned response (no actual network call).

- **No real-CLI integration tests in automated suite.** Those depend on the user's installed tools (claude, codex, antigravity, etc.). Manual smoke tested via bootstrap's verify step.

## File layout (repo)

```
D:\Dev\coding-agent-orchestrator\
├── docs/superpowers/specs/
│   └── 2026-05-26-plan4-fleet-design.md   ← this file
├── references/
│   └── fleet.yaml                         ← seed config (NEW)
├── commands/
│   └── fleet.md                           ← /fleet slash command (NEW)
└── scripts/
    ├── fleet-lib.ps1                      ← shared library (NEW)
    ├── fleet-doctor.ps1                   ← health probe (NEW)
    ├── fleet/                             ← per-provider escape hatches (NEW)
    │   └── lm-studio.ps1                  ← HTTP wrapper for LM Studio
    ├── test-fleet-lib.ps1                 ← unit tests (NEW)
    ├── test-fleet-doctor.ps1              ← doctor tests (NEW)
    ├── test-fleet-dispatch.ps1            ← end-to-end dispatch tests (NEW)
    └── bootstrap.ps1                      ← extended for Plan 4
```

After bootstrap runs, deployed layout under `~/.claude/`:

```
~/.claude/
├── settings.json                          (unchanged)
├── hooks/                                 (Plan 1, unchanged)
├── commands/
│   ├── …                                  (existing Plan 1/3 commands)
│   └── fleet.md                           (NEW)
├── scripts/
│   ├── job-lib.ps1                        (Plan 3, unchanged)
│   ├── consolidate-lessons.ps1            (Plan 3, unchanged)
│   ├── parse-otel.ps1                     (Plan 3, unchanged)
│   ├── fleet-lib.ps1                      (NEW)
│   ├── fleet-doctor.ps1                   (NEW)
│   └── fleet/
│       └── lm-studio.ps1                  (NEW)
├── jobs/                                  (Plan 3, unchanged)
├── knowledge/                             (Plan 3, unchanged)
├── telemetry/                             (Plan 1, unchanged)
├── model-routing-log.md                   (existing journal; gains new `fleet` source lines)
└── fleet.yaml                             (NEW)
```

## Bootstrap changes

`scripts/bootstrap.ps1` gains three idempotent steps inserted after Plan 3's blocks:

1. **Step 5e: Deploy Plan 4 library scripts.** Extend Step 5b's foreach to add `fleet-lib.ps1` + `fleet-doctor.ps1`. Also create `~/.claude/scripts/fleet/` and copy escape-hatch scripts.
2. **Step 5f: Deploy `/fleet` slash command.** Add `fleet.md` to Step 5's command foreach.
3. **Step 5g: Deploy `fleet.yaml` seed.** `Copy-WithPrompt` from `references/fleet.yaml` to `~/.claude/fleet.yaml`. If user edits exist, prompt before overwriting (same idiom as the catalog).
4. **Step 7 update: add `fleet doctor` to backend verification.** After the existing backend probes (gemini, codex, ollama, lms, gh, LM Studio HTTP), invoke `pwsh -NoProfile -File scripts/fleet-doctor.ps1` and surface the result.

Idempotent. Safe to re-run.

## Success criteria

- After bootstrap, `~/.claude/fleet.yaml` exists with the seeded providers; user can edit without breaking anything.
- `/fleet doctor` correctly reports status of every enabled provider on the user's machine.
- `/fleet test claude-cli "say hello"` returns a real response from Claude, journaled with `fleet | claude-cli | …`.
- `/fleet test lm-studio "say hello"` returns a real response over HTTP, also journaled.
- Same `/fleet test` invocations inside an active Plan 3 job carry trailing `job:` + `phase:` tags on the journal line.
- Adding a new "standard" CLI provider is a 5-line `fleet.yaml` edit, no PowerShell code changes.
- Adding a new HTTP provider is one new `scripts/fleet/<name>.ps1` + one `fleet.yaml` entry.
- `fleet doctor` exit code is 0 when all enabled providers report `ok`, 1 otherwise — usable as a Plan 5+ precondition check.
- Multi-machine: changing the value of `env.OLLAMA_HOST` on a fleet entry (from LAN IP to Tailscale name to SSH-tunnel localhost) works without any code change.

## Decisions made / open

- **Lean fleet.yaml + rich routing.md.** Operational data in fleet.yaml; capabilities/recommendations in `~/.claude/knowledge/universal/routing.md`. Decided.
- **Hybrid dispatcher: generic for `kind: cli`, per-provider escape hatches for `kind: http` (and any quirky CLI).** Decided.
- **`cost_tier` enum: paid / free / local.** `local` distinct from `free` to capture VRAM/latency cost. Decided.
- **`env` field as the Tailscale / SSH-tunnel / future-network abstraction.** No richer "network profile" concept — keep it dumb. Decided.
- **CLI-first; direct APIs / OpenRouter deferred.** Schema must NOT preclude adding `kind: api` later, but Plan 4 does not ship it. Decided.
- **`/fleet test` writes its own journal line** (in addition to the Plan 1 hook's line for CLI invocations). Intentional redundancy. Decided.
- **Dashboard Fleet panel deferred to Plan 7 cockpit work.** Plan 4 ships no Python changes. Decided.
- **Sharable design: no personal hostnames in repo seed; multi-machine entries default to `enabled: false`.** Decided.
- **Default timeout 120 s.** Configurable per-provider via `timeout_s` field (not in initial seed; documented as supported). Decided.
- **YAML parsing:** hand-rolled minimal parser, matching Plan 3's `Read-Manifest` style. Switch to a real YAML module if schema grows. Decided.

## Decision history

- **Plan 3 brainstorming (earlier 2026-05-26)** established the umbrella vision and CLI-first fleet philosophy. Plan 4 was decomposed out as "fleet config + multi-machine local" — slot 2 of the post-Plan 3 work.
- **2026-05-26 (this brainstorm):** scope confirmed as registry + doctor + dispatch primitive (smallest end-to-end useful slice). Wrapper philosophy: hybrid. Schema depth: lean + catalog. Network setup acknowledged: currently LAN/0.0.0.0, with Tailscale already installed for future cross-machine work and possible SSH-tunnel paths — addressed via the per-entry `env` map. LM Studio added to the fleet alongside Ollama. Designed for eventual third-party usability (no personal hostnames in repo).
