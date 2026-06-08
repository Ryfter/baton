---
title: Capability-routing optimizer — Slice 1: selector + data model
date: 2026-06-07
status: design
decisions: [d024, d025, d026]
slice: 1 of 3
---

# Capability selector + data model (routing Slice 1)

## Why

`d026` set the routing north star: an **auto-router with a learning loop** that picks the
*optimal* (not best) capability for a need — a free/local tool-or-model that is as-good-or-close
beats the most powerful paid one — so the orchestrator offloads grunt work off Claude and cuts
cost. It ships in three slices (see d026). **This is Slice 1: the brain that picks.** No
dispatch (Slice 2), no learning (Slice 3) — just an explainable, testable, cheapest-tier-first
*selector* over the two registries, surfaced via `/route`.

Today routing is advisory prose in `knowledge/universal/routing.md`; there is no programmatic
selector. `fleet.yaml` (models) has `cost_tier` but no capability tags; `tools.yaml` (tools)
has `cost_tier` + `capability`. The capability-specific *models* in `routing.md`
(commit-message, OCR, struct-extract) behave like tools, so they migrate into `tools.yaml`.

## Decisions carried in

- **d026:** auto-router + learning loop; 3-slice decomposition; this is Slice 1.
- **Data model (d026 / brainstorm):** capability-specific callables live in `tools.yaml`
  (`kind:cli` for ollama-run models); general models stay in `fleet.yaml`; broad capabilities
  they serve are declared once via a top-level `general_capabilities` list (no per-model tags).
- **Language:** the selector is **PowerShell** (`routing-lib.ps1`), because Slice 2 dispatch is
  PowerShell (`Invoke-Fleet` + CLIs) and `/route` mirrors `/fleet`. `tools.yaml` keeps its
  Python reader (KB/Docling); the YAML is the shared contract, per-consumer readers are fine
  (fleet.yaml is already PS-only).

## Non-goals (out of scope for Slice 1)

- Dispatch, output grading, escalation — **Slice 2**.
- Ratings capture, calibration, learned quality signal, shareable dataset — **Slice 3**.
- Real per-(capability,candidate) quality scoring. Slice 1 has a `quality` **slot** only,
  unrated; ranking is by capability match → cost tier → name.
- A Python reader for `fleet.yaml`. Not needed; the selector is PowerShell.
- The fully-autonomous folder+repo run-loop (a future epic built on the router).

## Architecture

Seven units.

### 1. `references/tools.yaml` — migrate specialty models in

Add `kind:cli` entries migrated from the `routing.md` "Specialty models" prose. Each is a
capability-specific callable invoked via `ollama run`:

```yaml
  - name: git-commit-message
    kind: cli
    enabled: true
    cost_tier: local
    capability: commit-msg
    command_template: 'ollama run tavernari/git-commit-message'
    stdin: true            # the staged diff is piped in
  - name: nuextract
    kind: cli
    enabled: true
    cost_tier: local
    capability: struct-extract
    command_template: 'ollama run nuextract'
  - name: deepseek-ocr
    kind: cli
    enabled: true
    cost_tier: local
    capability: ocr
    command_template: 'ollama run deepseek-ocr'
```

(`docling`/`pdf-extract` already present.) A `quality:` field MAY appear on any entry; it is
optional and unset here (Slice 3 populates it). The Python `tools/registry.py` reader already
ignores unknown fields and reads `command_template`/`base_url`, so these entries are inert to
the KB (different capability than `pdf-extract`).

### 2. `references/fleet.yaml` — declare general capabilities

Add a top-level key (sibling of the existing `research_default`):

```yaml
# Broad capabilities served by the general (conversational) models below.
# The router treats every ENABLED provider as a candidate for these.
general_capabilities: [code-gen, reasoning, summarize]
```

No per-provider capability tags (per the data-model decision).

### 3. `scripts/routing-lib.ps1` (new) — the selector

Dot-sourced by `/route`, the tests, and (later) Slice 2. Reuses `fleet-lib.ps1`'s `Read-Fleet`.

- **`Read-Tools [-Path <p>]` → `[hashtable[]]`** — parse `tools.yaml` into tool hashtables
  (`name, kind, enabled, cost_tier, capability, command_template, base_url, stdin, quality`),
  mirroring `Read-Fleet`'s hand-rolled line parser and `ConvertFrom-FleetValue`. Path default
  `~/.claude/tools.yaml`; missing file → `throw` with the deploy hint (same as `Read-Fleet`).
- **`Get-GeneralCapabilities [-FleetPath <p>]` → `[string[]]`** — read the
  `general_capabilities:` inline list from `fleet.yaml` (empty array if absent).
- **`Select-Capability`** — the selector:

  ```
  Select-Capability
    -Capability <string>          # e.g. commit-msg | code-gen | pdf-extract
    [-MaxCostTier <local|free|paid>]   # exclude tiers more expensive than this
    [-RequireLocal]               # only cost_tier=local candidates
    [-ToolsPath <p>] [-FleetPath <p>]  # test overrides
  -> [pscustomobject[]]  # ranked; each: name, kind, source, cost_tier, quality, score, why
  ```

  Logic:
  1. **Specialized candidates:** every enabled `tools.yaml` entry whose `capability` ==
     `$Capability` → `source = 'tools'`.
  2. **General candidates:** if `$Capability` is in `Get-GeneralCapabilities`, every enabled
     `fleet.yaml` provider → `source = 'fleet'` (cost_tier from the provider).
  3. **Filter** by `-MaxCostTier` / `-RequireLocal`.
  4. **Rank** by a numeric `score`: cost tier ascending (`local`=0, `free`=1, `paid`=2) —
     "optimal, not best" prefers the cheapest capable candidate — then `quality` descending
     (unrated treated as a neutral middle so it never outranks a known-good), then `name`.
  5. **`why`** is a short string per candidate (e.g. `"cheapest capable (local tool)"`,
     `"general model, free tier"`).
  6. Unknown/served-by-nothing capability → **empty array** (the caller reports it with the
     known-capability list).
- **`Get-KnownCapabilities [-ToolsPath -FleetPath]` → `[string[]]`** — union of every
  `tools.yaml` `capability` + `general_capabilities`; used for the "no candidates" message.

`return ,([object[]]$ranked)` to avoid 0/1-element unrolling (standing PS idiom).

### 4. `commands/route.md` (new) — `/route`

```
/route <capability> [--max-tier local|free|paid] [--local]
```

Steps: parse args; dot-source `routing-lib.ps1`; call `Select-Capability`; if empty, tell the
user no candidate serves `<capability>` and list `Get-KnownCapabilities`; else print the ranked
table (`name, source, kind, cost_tier, quality, why`) and state the **top pick** as the
recommendation — "Slice 1 recommends; dispatch is manual until Slice 2." No invocation.

### 5. `knowledge/universal/routing.md` — repoint

Replace the "Specialty models (invoke directly via Bash…)" section with a short pointer:
specialty models are now `tools.yaml` entries (`commit-msg`, `struct-extract`, `ocr`,
`pdf-extract`); query the optimal capability with `/route <capability>`. Keep the
general-coders catalog (still a useful human reference and the future home of quality notes).

### 6. `scripts/bootstrap.ps1` (+ `scripts/test-bootstrap.ps1`)

- Add `'routing-lib.ps1'` to the libs deploy array; `'route.md'` to the commands array.
- `test-bootstrap.ps1`: two dry-run-stdout assertions (`routing-lib.ps1`, `route.md`).

### 7. `scripts/test-routing-lib.ps1` (new) — tests

Project PS harness: `Check($name,$cond)` → `$script:fail`; temp `tools.yaml`/`fleet.yaml`
fixtures under `[System.IO.Path]::GetTempPath()`; try/finally cleanup; `exit 1`/`0`.

## Data flow

```
/route commit-msg
   → Select-Capability -Capability commit-msg
        → Read-Tools: git-commit-message (capability=commit-msg, local) → candidate
        → not a general capability → no fleet candidates
        → rank → [git-commit-message]  why="cheapest capable (local tool)"
   → /route prints the table + "top pick: git-commit-message"

/route code-gen --local
   → code-gen ∈ general_capabilities → fleet candidates (enabled)
   → -RequireLocal keeps only cost_tier=local (ollama-local, ollama-box2)
   → rank cheapest-first → top pick: ollama-local
```

The conductor (Claude) reads the recommendation and decides — manual routing until Slice 2
pulls the trigger.

## Error handling

| Condition | Behavior |
|---|---|
| Unknown capability (no candidate) | `Select-Capability` → empty; `/route` reports it + lists `Get-KnownCapabilities`. |
| `-RequireLocal` / `-MaxCostTier` filters everything out | empty + a reason naming the constraint. |
| `tools.yaml` or `fleet.yaml` missing | `Read-Tools`/`Read-Fleet` `throw` the deploy hint (`run bootstrap.ps1`). |
| Disabled candidate | excluded (never ranked). |
| Malformed line in a yaml | parser skips it (same tolerance as `Read-Fleet`); never crashes the selector. |

## Testing

`scripts/test-routing-lib.ps1`:
- `Read-Tools` parses a fixture: counts entries; reads `capability`, `cost_tier`, `kind`,
  `command_template`, `stdin`; tolerates an optional `quality`.
- `Select-Capability` specialized: `commit-msg` → `[git-commit-message]`, `source=tools`.
- `Select-Capability` general: `code-gen` → enabled fleet providers, `source=fleet`.
- **Cheapest-first ordering:** with a local + a paid candidate for the same capability, the
  local one ranks first (lower `score`).
- `-RequireLocal` excludes non-local; `-MaxCostTier free` excludes `paid`.
- Disabled tool/provider excluded.
- Unknown capability → empty; `Get-KnownCapabilities` includes the seeded capabilities +
  `general_capabilities`.
- Quality tiebreak: when two candidates share a tier, a higher `quality` ranks first; unrated
  is treated as neutral (does not outrank a known-good).

Bootstrap smoke (`test-bootstrap.ps1`): dry-run stdout shows `routing-lib.ps1` + `route.md`.

## Build order (TDD)

1. `routing-lib.ps1` `Read-Tools` + tests.
2. `references/tools.yaml` specialty entries; `references/fleet.yaml` `general_capabilities`.
3. `Get-GeneralCapabilities` + `Get-KnownCapabilities` + tests.
4. `Select-Capability` (candidates + filter + rank + why) + tests.
5. `commands/route.md`.
6. `routing.md` repoint.
7. bootstrap deploy + `test-bootstrap.ps1` assertions.

## Success criteria

- `/route commit-msg` recommends the local `git-commit-message` tool with a clear "why".
- `/route code-gen` ranks enabled fleet models cheapest-tier-first; `--local` restricts to
  local; `--max-tier free` excludes paid.
- An unknown capability returns a helpful "no candidate; known: …" message.
- Specialty models are gone from `routing.md` prose and present in `tools.yaml`; `/tools list`
  shows them; the KB `pdf-extract` path is unaffected.
- `routing-lib.ps1` + `route.md` deploy via bootstrap.
- Gate green: `test-routing-lib.ps1` + the existing Python + PowerShell suites + bootstrap smoke.
