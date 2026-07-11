# Usage-aware failover routing — design

**Date:** 2026-07-11 · **Status:** SPEC — authored async (Kevin away); build gated on his
review + priority-slot + the batched decisions in §8 · **Origin:** Kevin 2026-07-11 ("check
the usage limits left of the various models… swap in a model (grok for codex) if codex is
about out of usage"). · **Fleet input:** design critiqued by **Codex** (297s) + **Grok**
(42s) 2026-07-11 — both cited below; strong convergence.

## 1. What this is

When a fleet model is exhausted or near its cap, route the task to a same-capability peer
instead of failing. Kevin's framing was "know how much each model has left, then swap." The
fleet critique sharpened the honest version of that:

> **"Remaining usage" is heterogeneous and mostly untrusted. Copilot is the only provider
> with a real billing surface; Codex has a supported app-server rate-limit query; Claude
> exposes status-line %; Grok subscription is opaque. A uniform proactive "% left per
> model" is a fiction.** — synthesized from both critiques.

So this is **reactive-first with opportunistic proactive probes**, not a universal quota
oracle. Reactive failover is the correctness layer; proactive signals are advisory inputs
only where a real surface exists.

## 2. What each provider actually surfaces (fleet-verified — §A of both critiques)

| Provider | Proactive remaining? | Real surface | Baton posture |
|---|---|---|---|
| **Codex** (ChatGPT sub) | **Yes — best CLI case** | Codex **app-server** `account/rateLimits/read` → `usedPercent`, window, reset, primary/secondary buckets (supported JSON-RPC — *not* terminal scraping). *(Codex's claim; Grok rated this "fragile" — §8 fork U-A: verify it's headless-accessible.)* | Proactive probe candidate #1 |
| **Claude** (Pro/Max sub) | Partial | Status-line JSON: 5h/7d `used_percentage` + `resets_at` (after first response); limit errors name session/weekly/Opus + reset. No headless `claude -p` quota query. | Status-line integration (later) |
| **Grok** (xAI sub) | **No** | Interactive `/usage` only; no machine-readable headless schema. Expires **2026-07-15**. | **Reactive only** — never scrape a TUI |
| **Copilot** | Yes (consumed, not allowance) | Billing REST gives *consumed* credits; must be combined with a verified/configured **allowance** to infer remaining (d079). May lag. | Proactive forecast (d079 panel) |
| **Local** (ollama/LM-Studio) | N/A | Hardware/latency, not quota. | Never failover *away* for "quota" |
| **Token telemetry** (spec'd) | Consumption only | Measures *burn*, not *headroom*. | Feeds run-rate, **never** drives "near cap" alone |

**Consequence:** token telemetry alone cannot drive failover (it measures burn, not
headroom). Only Copilot billing + the Codex app-server + Claude status-line are real
proactive signals; everything else is reactive.

## 3. Architecture — hybrid, reactive-primary (§B of both critiques)

**Do not build a parallel router.** Extend the existing **Usage Governor** (lockout /
cooldown / waiting_for_reset states, Sprint 2.5 auto-detect) and route through the existing
**`Select-Capability`** chokepoint. Proactive adapters are *event producers* into the same
journal.

```
dispatch → (optional fresh proactive check) → invoke
         → on hard failure: classify → mark provider LOCKED (before retry) → Select-Capability route-around → one substitute retry
         → on soft signal (Copilot %, codex app-server %): 'limited'/conserve, not hard-exclude
```

### 3.1 Observation model (normalized — both critiques independently proposed this)

Every usage datum: `{ worker, scope, used_pct, reset_at, source, observed_at, ttl,
confidence }`.
- **scope** ∈ `{ five_hour, weekly, model, subscription, api_rate, paid_credit }` — a 429
  burst is NOT a weekly exhaustion; misclassifying it kills a healthy peer for hours.
- **source** ∈ `{ billing_api, app_server_probe, status_line, error_classify, local_budget }`.
  `local_budget` = an operator policy cap (existing `fleet.yaml budget` + journal ticks),
  **labeled as policy, never presented as vendor truth.**

### 3.2 Layer 1 — reactive failover (ships first, the correctness layer)

- **Classify** every dispatch's exit code + stdout/stderr: `quota_exhausted` →
  `waiting_for_reset` (+ parsed `reset_at` from Retry-After / "resets at…"); `rate_limit_burst`
  (short 429) → `cooldown`; `auth`/`config` → **no failover loop**; ambiguous → short cooldown,
  not exhaustion.
- **Mark the provider locked BEFORE the retry** so a parallel fleet (V3) doesn't pile onto a
  dead worker.
- **One** substitute retry via `Select-Capability` route-around (never an unbounded cascade).
- Journal `original_worker`, `substitute`, `reason`, `reset_at`, `had_partial_diff`.

### 3.3 Layer 2 — proactive, only where the signal is real (incremental, later)

Order (both critiques agree): **Codex app-server first**, Claude status-line second, Copilot
billing reconciliation third (the d079 panel: usage + configured allowance → remaining).
Each is soft, TTL'd, fail-open. **No Grok TUI scraper. No ML forecast. No unified
"%-remaining" in v1.**

### 3.4 Substitute selection (§B)

Same **capability class** (not same brand) via `Select-Capability`, additionally requiring:
`agentic` class match, context floor, tool/permission profile, **quality floor**, **cost
ceiling**. Preference order: same-tier peer → cheaper paid → local. **Refuse to silently
drop a `hard`/orchestrator task to a weak local model** — surface "no peer available"
instead. **Never silently replace subscription-included work with metered API work** without
an explicit policy flag (the cost-blindspot trap).

### 3.5 Coding-agent specific (Baton's Verified-Labor context — Codex §B)

A substitute retry runs from a **clean worktree** — never over another model's partial
edits. This composes directly with Verified Labor V2's one-retry-in-worktree model: a
quota-driven failover and a verification-driven retry share the same "one clean retry"
discipline.

## 4. Risks & mitigations (§C — both critiques converged)

| Risk | Mitigation |
|---|---|
| **Flapping** | Sticky provider per run; hysteresis (enter soft at ~90%, restore only below ~70% after TTL); min cooldown 15–60m; restore only after reset **+ a successful canary**; max 1 failover hop/task; don't re-probe every dispatch. |
| **Silent quality drop** | Capability-match is insufficient — add a learned quality floor + the acceptance gate; journal + visibly report every swap; optional `failover_policy: sticky\|quality_first\|never`; never auto-swap the orchestrator role without policy. |
| **Cost blindspot** | Failover to a metered API can *raise* $ while saving sub-minutes. Track substitute cost-tier; enforce `max_cost_tier`/run budget; paid fallback needs an explicit flag; reason over effective-cost, not token count. |
| **Stale data** | Every figure carries `source`/`observed_at`/`ttl`/`confidence`; expired → ignore for hard-exclude, reactive path wins; probes fail-open. |
| **Misclassification** | The scope taxonomy (§3.1): `burst_rpm`→short cooldown; `plan_window`→waiting_for_reset; `monthly_credits`→exhausted-until-cycle. |
| **Retry storms / double-spend** | Max 1 automatic failover/task; keep an attempted-provider set; lock the primary *before* retry; stop with collected errors when the ladder is exhausted. |

## 5. Smallest first slice ("Sprint 2.5 done right" — §D, both critiques identical)

1. **Classify** quota/rate-limit failures from every fleet dispatch's exit + stdout/stderr
   (a regex library over known Codex/Claude/Grok/gh-models strings; fail-open if ambiguous).
2. **Append** `lockout`/`cooldown`/`limited` to the Usage Governor journal with parsed
   `reset_at`.
3. **Auto route-around:** wire the lockout events so `Select-Capability` skips the dead
   worker on the next pick *and* the same-task substitute retry.
4. **One** substitute retry (same capability, clean state); journal the hop; one operator line.
5. **Hermetic fixtures** for Codex, Claude, Grok, generic 429, server-overload, ambiguous.

**Done when:** codex dies mid-run → the next pick is a grok/claude peer without a manual
`/baton:usage lockout`, no thrash, quality + cost policy honored.

**Explicit non-goals for slice 1:** proactive multi-provider headroom map; "always know
remaining"; token-estimate-driven swaps; any status-TUI scraping.

## 6. Relationship to the adjacent tracks

- **Token telemetry** (direct-model spec §4): supplies burn-rate, not headroom — an input, not
  a trigger.
- **Copilot budget d079:** the one honest proactive forecast; becomes Layer-2 adapter #3
  (observe-only first, soft `limited` at 90% later — no hard failover until classification is
  trusted).
- **Availability probe** (`project_grok_availability`): the start-of-run reachability sweep
  is the *pre-dispatch* cousin of the reactive classifier — same lockout journal.
- **Model tiers** (direct-model spec §3.3): a failover may also *downshift a tier* (Luna→Sol)
  rather than swap providers — a later refinement.

## 7. Scope

**In (slice 1):** reactive classification lib + Usage-Governor lockout events + Select-
Capability route-around wiring + one substitute retry + journaling + hermetic fixtures;
bootstrap manifest + deploy-assert for the new lib; plugin minor bump.

**Out:** proactive adapters (Codex app-server / Claude status-line / Copilot) — incremental
follow-ups; ML/forecast headroom; Grok scraping; cross-machine aggregation; any silent
routing-weight change (the d059 firewall holds).

## 8. Open decisions — batched for Kevin

- **Fork U-A — is the Codex app-server `account/rateLimits/read` actually headless-queryable?**
  Codex asserts yes (a real proactive surface); Grok rated Codex "fragile, interactive-only."
  *Action before building Layer 2:* verify the app-server query works from a script without a
  TUI. If yes, Codex becomes proactive adapter #1; if no, Codex stays reactive. **Slice 1 does
  not depend on this** (it's reactive-only).
- **Fork U-B — priority slot.** This wasn't in Kevin's 2026-07-11 list (#1 merge → #2 direct-
  model → #3 d079 → #4 V3 → #5 V4). It clusters naturally with #2/#3 (the usage-awareness
  family) and slice 1 is small. *Default suggestion:* slot slice 1 right after d079 (#3), since
  d079's Copilot panel is its Layer-2 adapter #3 and the two share the Usage Governor journal.
- **Fork U-C — failover default posture.** *Default:* `failover_policy: quality_first` (swap
  only to an equal-or-better peer; refuse silent downgrade of hard tasks). Kevin may prefer
  `sticky` (minimize swaps) or opt-in-only for a first release.

## 9. House rules

965-byte args; `[Console]::Error.WriteLine` + exit 2; hooks exit 0; utf8NoBOM; ConvertFrom-
Json ISO re-stringify; `ConvertTo-Json -InputObject @(...)`; never `$args`/`$input`/`$event`;
unary-comma only on direct-assignment returns; guard every divide; **box-private: real
rosters/quotas/reset windows live only in `~/.baton`; the seed carries placeholders**; observe-
first discipline (measure + surface before auto-routing — the d078/Verified-Labor pattern).
Ladder: subagent-driven, Sonnet for the classifier + Select-Capability wiring, Haiku for the
fixture transcription, Opus final review; streamlined ceremony.
