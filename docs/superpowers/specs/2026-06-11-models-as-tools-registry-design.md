# Models-as-Tools — capability claims, model inventory, scorecard import (design)

**Status:** spec'd 2026-06-11; awaiting Kevin's review.
**Parent:** the models-as-tools design spurt (memory `project_models_as_tools_vision`, 15 requirements, 2026-06-11) and the cost-optimization engine line (Slices A–C shipped). Sibling app: **Gauntlet** (`Ryfter/bench-gauntlet`, spec'd, build deferred) — this slice builds Baton's half of that seam.

## Purpose

Treat local models as **specialized tools with explicit claims**, not interchangeable generalists. Today every enabled provider is a candidate for every general capability (`general_capabilities: [code-gen, reasoning, summarize]`), and the judge is picked by **file order** (`Get-CheapestLocalModel` = first enabled local). Both broke in production on 2026-06-11: the judge auto-pick dialed the offline laptop, then a reasoning-model pin broke strict-JSON parsing. This slice replaces position-and-luck with declared, data-backed capability claims.

## What this slice ships (and what it doesn't)

**In:** per-provider capability claims, explicit judge claim, capability context floors, tight/broad usage classes (recorded, surfaced — not yet enforced), keep-list, `/baton:models` inventory command, Gauntlet scorecard import into the existing ratings store, economy/champion selection modes.

**Deferred (named, not built):** idle detection + broad-class enforcement, VRAM-saturation scheduling, overnight battery orchestration (needs Gauntlet built), automated culling/pareto advisor (inventory ships heuristic recommendations only), BoB+large-context slots (need scorecard data first).

## Decisions made

1. **Claims override the blanket grant; absence keeps it.** A provider with a `capabilities:` list is a candidate for ONLY those capabilities. A provider without the field keeps today's `general_capabilities` behavior. Frontier CLIs (claude-cli, codex, gemini, gh-copilot) stay field-less — "good at pretty much all jobs" (Kevin). Local/small models get explicit lists. Additive, zero migration.
2. **`judge` becomes a claimed capability.** `Get-JudgeModel` (new) resolves the judge via claims: first enabled provider claiming `judge`, ranked by `Select-Capability` (local tier first). Falls back to `Get-CheapestLocalModel` when nobody claims it (back-compat for bare registries). The live registry pins `lm-studio-small` (`phi-4`) as the sole `judge` claimant — the file-order comment hack dies.
3. **Taxonomy is data-driven, documented in one place.** No hardcoded enum. The canonical name list (matching Gauntlet's battery names) lives in `references/fleet.yaml` header docs: `code-gen`, `code-transform`, `commit-msg`, `extract-json`, `summarize-short`, `summarize-long`, `synthesize`, `write-personal`, `write-scientific`, `write-formal`, `ocr`, `embed`, `judge`, `reasoning`, `vision`. `Get-KnownCapabilities` already unions live sources; claims simply widen that union.
4. **Context floors are a top-level map, not per-claim syntax.** `capability_floors: { summarize-long: 65536, judge: 4096, ... }` in fleet.yaml plus optional per-provider `context:` (the loaded context of the pinned profile, from d043 load-profile thinking). A claim is filtered out when `provider.context < floor`. Providers without `context:` are never filtered (unknown ≠ disqualified). Keeps YAML flat and the parser line-oriented, matching the existing reader.
5. **Usage classes are recorded this slice, enforced next.** `usage_class: tight | broad` on local providers (tight = small specialists, safe while Kevin is active; broad = 15GB+ generalists, idle-gated *later*). Surfaced by `/baton:models` and fleet doctor; NOT yet gated at dispatch — real idle detection belongs to the idle-saturation slice, and Kevin actively uses the 30B drafter today, so premature enforcement would block live workflows.
6. **Keep-list is registry-level, glob-based, inventory-scoped.** `keep_list: ['*heretic*', '*swahili*']` in fleet.yaml (same shape as Gauntlet's targets.yaml). Inventory tags matching installed models `keep`; recommendations never propose culling them; they are not registry entries so the router can never claim them anyway.
7. **Inventory is a command, snapshot, and recommend-only report.** `/baton:models` → `scripts/fleet-models.ps1`. Queries each enabled http local provider's box (LM Studio native `/api/v1/models` — params/quant/context/capabilities incl. the reasoning flag; ollama `/api/tags`), joins with registry pins/claims/keep-list, writes `~/.baton/model-inventory.json`, prints a table plus a recommendations section (pinned-but-missing models, installed specialists with no registry entry, near-duplicate candidates by family+size heuristic, reasoning-flagged models pinned to judge duty). Never installs or deletes — Kevin acts.
8. **Scorecards import into the EXISTING ratings store.** `Import-GauntletScorecard -Path <scorecard.json>` maps cells (model × capability × quality) to `routing-ratings.jsonl` rows tagged `source: gauntlet` — the learned-quality machinery (`Get-CapabilityQualityDetail`) consumes them with zero new plumbing. Hand-made scorecards work until Gauntlet exists (its JSON contract is already spec'd). Champion/culling analytics read the same store later.
9. **Selection grows an economy/champion switch.** `Select-Capability -SelectionMode economy|champion` — economy (default) keeps today's ranking (cost tier asc, quality desc): "smallest that clears the bar." Champion ranks quality desc with cost as tiebreak: "just the best" — the BoB slot per capability, and a future free escalation rung before paid finishers. Footprint-aware economy (VRAM-weighted) waits for scorecard footprint data.

## Architecture

### M.1 Registry schema (fleet.yaml — additive fields)

```yaml
capability_floors:            # top-level; claim invalid below the floor
  summarize-long: 65536
  judge: 4096
keep_list: ['*heretic*', '*swahili*']

providers:
  - name: lm-studio
    # ...existing fields...
    capabilities: [code-gen, code-transform, summarize-short, synthesize]
    context: 32768            # loaded context of the pinned profile
    usage_class: broad
  - name: lm-studio-small
    capabilities: [judge, commit-msg, extract-json, summarize-short]
    context: 16384
    usage_class: tight
```

Reader: `Read-Fleet` gains the three per-provider fields (same line-oriented parse as `role`/`platform` in Slice B); new `Get-CapabilityFloors` / `Get-FleetKeepList` mirror `Get-GeneralCapabilities`.

### M.2 Selector (routing-lib.ps1)

In `Select-Capability` step 2, the general-candidates loop becomes claims-aware:

- provider has `capabilities:` → candidate iff list contains the capability (regardless of whether the capability is "general"),
- provider lacks the field → candidate iff capability ∈ `general_capabilities` (unchanged),
- either way, drop the candidate when `capability_floors[$Capability]` exists, provider `context` is known, and `context < floor` (with a `why` note),
- `-SelectionMode champion` re-ranks quality desc, cost-tier asc as tiebreak.

### M.3 Judge resolution (routing-learn.ps1)

`Get-JudgeModel -FleetPath` → `Select-Capability -Capability judge -RequireLocal` first hit; `$null` falls through to `Get-CheapestLocalModel`. `Get-LlmJudgeGrader` calls it; everything downstream (cascade, backlog drivers) inherits the fix untouched.

### M.4 Inventory (`scripts/fleet-models.ps1`, command `commands/models.md`)

```
/baton:models [--json] [--box <name>]
```

Per enabled local http provider (deduped by base_url): probe the enrichment endpoint by kind (`lm-studio*` → native API, `ollama*` → /api/tags), normalize to `{ id, size_bytes, quant, max_context, capabilities_flags, loaded }`, tag `pinned` / `claimed` / `keep` / `unregistered`, write snapshot, print table + recommendations. Unreachable box → section marked offline, run continues (wraith2 is often off).

### M.5 Scorecard import (routing-learn.ps1)

`Import-GauntletScorecard -Path -RatingsPath` — validates the Gauntlet contract shape (`run`, `cells[]`), maps each cell to a ratings row `{ capability, candidate, quality, n, source: 'gauntlet', run_id, date }`, appends idempotently (skip rows whose `run_id` already imported). Surfaced as `/baton:models --import <path>`.

### M.6 Seed + live registry updates

`references/fleet.yaml`: taxonomy doc block, example claims, floors, keep_list. Live `~/.baton/fleet.yaml` (hand-edit at deploy): claims for lm-studio (broad drafter), lm-studio-small (judge + tight utilities), ollama-box2 (tight overflow); the file-order comment replaced by the judge claim.

## Error handling

- Claims naming unknown capabilities: allowed (they widen `Get-KnownCapabilities`); doctor may warn on obvious typos later.
- No provider claims `judge` → fall back to `Get-CheapestLocalModel` → heuristic grader (existing fail-open chain, unchanged).
- Inventory probe failures are per-box, never fatal; snapshot records `reachable: false`.
- Import rejects files missing `run.id` or `cells` with a named error; partial cell defects skip the cell and count it.

## Testing

Extend the existing suites in place: `test-routing-lib.ps1` (claims filtering, floors, champion mode), `test-routing-learn.ps1` (Get-JudgeModel resolution + fallback, import idempotency), new `test-fleet-models.ps1` (normalization from canned API JSON fixtures, tagging, recommendations; probes injected — tests never hit live servers). All temp registries under `$env:TEMP`; never touch `~/.baton`.

## Requirements traceability (spurt → spec)

Req 1 taxonomy/claims → M.1/M.2/decision 3. Req 2 inventory + recommendations → M.4. Req 5 redundancy culling → M.4 near-duplicate heuristics now, scorecard-driven pareto later. Req 6 quality-per-resource bars → decision 9 economy mode (footprint-aware deferred). Req 7 champion protection → champion mode + recommend-only culling. Req 8 context axis → decision 4 floors. Req 9 keep-list → decision 6. Req 10 BoB slots → champion mode (large-context slots deferred). Req 11 load-profile VRAM → per-provider `context:` field (budget math deferred with saturation). Req 12 writing registers → taxonomy names (batteries live in Gauntlet). Req 13 Gauntlet seam → M.5 import. Req 14 tight/broad → decision 5 (recorded). Reqs 3/4/15 (idle saturation, overnight runs, wraith2 host policy) → deferred slices. Judge incidents → M.3.
