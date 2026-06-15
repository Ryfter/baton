# Triage Agent — Sprint 1 design

**Status:** spec'd 2026-06-15; awaiting plan.
**Parent:** Baton v2 Architecture Brief (2026-06-15) — Sprint 1 of 7.
**Sprint goal:** `baton triage` classifies any issue or task text into a structured triage object (type, priority, estimate, risk, research_needed, recommended pipeline, recommended platform/model, confidence) by routing through the existing fleet + usage_class system. Sprint 1 dogfoods Baton's own economic routing from its first command.

## Purpose

Today, when Kevin starts work on an issue, routing is manual — he decides which model, which pipeline, what priority. The Triage Agent automates that first step: given a GitHub issue URL, a local file, or pasted text, it produces a machine-readable classification that drives labels, GitHub Project fields, and pipeline selection. The output is cheap (Haiku preferred), fast, and flows through the same routing infrastructure every subsequent Baton command will use.

## What this sprint ships (and what it defers)

**In:** `triage-lib.ps1` (Invoke-TriageAgent), `/baton:triage` command, `claude-haiku` provider entry in fleet.yaml seed, `triage` capability taxonomy entry, confidence-based escalation to Sonnet, GitHub issue input (URL → body via `gh issue view`), local file input, text input. Test suite.

**Out (named, deferred):** GitHub Project field updates (Sprint 3), label application (Sprint 3), batch triage of a full project (Sprint 3), memory precheck integration (Sprint 5), Usage Governor lockout enforcement (Sprint 2 — today's routing checks availability but doesn't track exhaustion).

## Decisions made

1. **Triage routes through Select-Capability, not direct Haiku hardcode.** Sprint 1 dogfoods Baton's economic routing from the start. The triage command calls `Select-Capability -Capability triage` to get the cheapest capable model, with Haiku as the registered preferred. This exercises the fleet/usage_class path, not a direct `claude --model haiku` bypass. (d045)

2. **`triage` is a new claimed capability.** Added to the `claude-haiku` provider's `capabilities:` list in fleet.yaml. The existing `claude-cli` provider (unmodeled, frontier) remains unconstrained — it doesn't claim `triage` because triage needs the explicit model control that only the `claude-haiku` entry provides. Sonnet escalation uses `claude-sonnet` (new entry) or the existing `claude-cli` as fallback.

3. **Haiku needs its own fleet.yaml entry.** `claude-cli` has no model flag in its command template (`claude -p "{{prompt}}"`). To route to Haiku specifically, a `claude-haiku` provider entry is required with `command_template: 'claude -p "{{prompt}}" --model claude-haiku-4-5-20251001'`. This is the cleanest path: the routing system picks it by capability, cost tier is `paid` (same tier as `claude-cli`), and quality starts at prior 0.5.

4. **Escalation is confidence-threshold based, not hard-coded.** The triage prompt requests a `confidence` float (0.0–1.0). If confidence < 0.70 OR the task is flagged `risk: high` OR `ambiguity: high`, Invoke-TriageAgent re-runs the triage request against the Sonnet escalation target. The escalation result is the authoritative output; a `escalated: true` field records that it happened.

5. **Deterministic fallback when all models are unavailable.** If `Select-Capability -Capability triage` returns no candidates (all paid models usage-limited, local models unavailable), a deterministic rule pass assigns `type: unknown`, `confidence: 0.40`, and `escalation_needed: true`. The command emits the object and exits clean; the caller decides whether to retry.

6. **Output is YAML-formatted to stdout; JSON available via --json.** Keeps the command human-readable by default (consistent with `/baton:route`, `/baton:models`). `--json` flag for programmatic consumers (Sprint 3 GitHub field updater). The output object schema is fixed for Sprint 1 (see § Output contract).

7. **Input priority: --url > --file > positional text.** `baton triage --url <gh-url>` fetches via `gh issue view`. `baton triage --file <path>` reads local markdown. `baton triage <text>` accepts inline description. Exactly one input source per invocation.

## Architecture

### T.1 fleet.yaml additions (seed + live)

New provider entries (appended to `providers:` block):

```yaml
  - name: claude-haiku
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [triage, classify, summarize-short]
    model_default: 'claude-haiku-4-5-20251001'
    command_template: 'claude -p "{{prompt}}" --model claude-haiku-4-5-20251001'

  - name: claude-sonnet
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [triage, code-gen, reasoning, summarize]
    model_default: 'claude-sonnet-4-6'
    command_template: 'claude -p "{{prompt}}" --model claude-sonnet-4-6'
```

The existing `claude-cli` entry is unchanged (no `capabilities:` field = frontier/blanket grant for general capabilities, not triage).

Also add `triage` to the canonical capability list comment in fleet.yaml's header doc block.

### T.2 triage-lib.ps1

New file: `scripts/triage-lib.ps1`

Key functions:

```
Read-TriageInput -Url <string> -File <string> -Text <string>
  Returns: string (the task description, normalized)

Invoke-TriageAgent [-Input <string>] [-MaxCostTier <string>] [-FleetPath <string>]
  Returns: hashtable (the triage object — see § Output contract)

Build-TriagePrompt [-TaskText <string>]
  Returns: string (the structured prompt sent to the model)

Test-TriageEscalationNeeded [-Triage <hashtable>]
  Returns: bool
```

**Invoke-TriageAgent logic:**

```
1. candidates = Select-Capability -Capability triage -MaxCostTier paid
2. if no candidates: return deterministic-fallback object (confidence=0.40, escalation_needed=true)
3. pick = candidates[0]  (cheapest-capable = Haiku if available)
4. prompt = Build-TriagePrompt -TaskText $input
5. result = dispatch pick with prompt  (reuse Invoke-Tool / Invoke-FleetHttp pattern)
6. triage = parse JSON from result.stdout (strict; error → deterministic fallback)
7. if Test-TriageEscalationNeeded $triage:
     escalate_candidates = Select-Capability -Capability triage -SelectionMode champion
     escalation_pick = escalate_candidates | Where-Object { $_.name -ne $pick.name } | Select-Object -First 1
     if escalation_pick:
       result2 = dispatch escalation_pick with prompt
       triage2 = parse JSON from result2.stdout
       triage2['escalated'] = $true
       triage2['escalated_from'] = $pick.name
       return triage2
8. return triage
```

Dispatching reuses the existing `Invoke-Tool` (cli kind) and `Invoke-Fleet-Http` (http kind) functions from routing-dispatch.ps1 via dot-source.

### T.3 Triage prompt (Build-TriagePrompt)

The prompt is embedded in triage-lib.ps1 (not a separate file — small enough). Key contract:

- System message: "You are a software task triage agent. Classify the task and respond with ONLY valid JSON matching the schema below. No prose."
- Schema included inline in the prompt (the output contract JSON schema).
- Task text appended as user content.
- Temperature: 0 (classification, not creative).

The Claude CLI invocation uses `claude -p "{{prompt}}" --model claude-haiku-4-5-20251001`. The combined prompt is the system + schema + task, passed as a single `-p` argument.

### T.4 Output contract

```json
{
  "type":                 "bug | plan | spec | coding | test | review | polish | chore | docs | research",
  "priority":             "P0 | P1 | P2 | P3 | P4",
  "estimate":             "XS | S | M | L | XL",
  "risk":                 "low | medium | high",
  "research_required":    true | false,
  "recommended_platform": "Claude | Codex | Copilot | Gemini | Local | Human",
  "recommended_model":    "Haiku | Sonnet | Opus | Codex | Copilot | local/<name>",
  "agent_type":           "Triage | Planning | Implementation | Review | Research | Polish",
  "pipeline": [
    "<stage-1>", "<stage-2>", "..."
  ],
  "area":                 "<optional repo/component area, or null>",
  "next_action":          "<one sentence: the next concrete step>",
  "confidence":           0.0–1.0,
  "escalation_needed":    true | false,
  "escalated":            true | false,
  "escalated_from":       "<provider name or null>"
}
```

YAML stdout default (human-readable); `--json` flag emits raw JSON.

### T.5 /baton:triage command (commands/triage.md)

Slash command that calls `scripts/fleet-triage.ps1` (thin wrapper, analogous to fleet-models.ps1 calling triage-lib functions).

Signature:
```
/baton:triage [--url <github-issue-url>] [--file <path>] [--json] [<text>]
```

Examples:
```
/baton:triage --url https://github.com/Ryfter/canvas-toolchain/issues/41
/baton:triage --file D:\scratch\task.md
/baton:triage "Add retry logic to the routing dispatch escalation path"
/baton:triage --url ... --json
```

### T.6 Fleet-triage.ps1 (command runner)

New file: `scripts/fleet-triage.ps1` — thin CLI wrapper. Parses args, calls `Read-TriageInput` + `Invoke-TriageAgent`, formats output as YAML or JSON.

### T.7 Bootstrap additions

- `fleet-triage.ps1` added to manifest (deployed to `$BATON_HOME/scripts/`).
- `fleet.yaml` seed gains the two new provider entries.
- `scripts/bootstrap.ps1` gains smoke assertion: `triage-lib.ps1` deployed.

## Test plan (test-triage.ps1)

```
T1  Read-TriageInput --text: returns the text as-is
T2  Read-TriageInput --file: reads file content
T3  Build-TriagePrompt: prompt contains the task text and the JSON schema
T4  Test-TriageEscalationNeeded: true when confidence=0.65
T5  Test-TriageEscalationNeeded: false when confidence=0.85, risk=medium
T6  Test-TriageEscalationNeeded: true when risk=high regardless of confidence
T7  Invoke-TriageAgent with stub provider: parses clean JSON → returns triage hashtable
T8  Invoke-TriageAgent with stub provider: malformed JSON → returns deterministic fallback
T9  Invoke-TriageAgent with no candidates: returns deterministic fallback (confidence=0.40)
T10 Invoke-TriageAgent with low-confidence result: escalates to second candidate
T11 fleet.yaml has claude-haiku entry with triage in capabilities
T12 Select-Capability -Capability triage returns claude-haiku as first candidate (stub fleet)
T13 fleet-triage.ps1 --text: exits 0, stdout contains 'type:' and 'confidence:'
T14 fleet-triage.ps1 --json: stdout is valid JSON with required fields
T15 fleet-triage.ps1 --url: calls 'gh issue view' (mock gh, verify invocation)
```

## Files created / modified

| File | Change |
|------|--------|
| `scripts/triage-lib.ps1` | NEW — Invoke-TriageAgent, Build-TriagePrompt, Read-TriageInput, Test-TriageEscalationNeeded |
| `scripts/fleet-triage.ps1` | NEW — CLI wrapper / command runner |
| `scripts/test-triage.ps1` | NEW — 15 tests |
| `commands/triage.md` | NEW — /baton:triage slash command |
| `fleet.yaml` (seed in repo) | MODIFY — add claude-haiku + claude-sonnet provider entries |
| `scripts/bootstrap.ps1` | MODIFY — add fleet-triage.ps1 to manifest, smoke assertion |
| `~/.baton/fleet.yaml` (live) | MODIFY (live) — same two provider entries applied on bootstrap |

## v1 → v2 naming map (this sprint)

| v1 concept | v2 name (emerging) |
|---|---|
| `Select-Capability` | Worker Router core |
| `fleet.yaml providers:` | Worker Registry |
| `claude-haiku` provider | Cheap Triage Worker |
| `claude-sonnet` provider | Escalation Worker |
| `triage` capability | Triage role |
| `confidence` field | Routing quality signal |

## Open questions (none blocking Sprint 1)

- GitHub Project field update schema (Sprint 3 will define; triage output is the feed).
- Serf worker adapter (Sprint 6; triage just sets `recommended_platform`, doesn't dispatch to Serf).
- Projectmem event logging after triage runs (Sprint 5; today triage is stateless).
