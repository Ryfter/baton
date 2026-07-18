# Roadmap

**Last updated:** 2026-07-18
**Status:** `v1.20.0` shipped — *per-PR ship report (`/baton:ship-report`, #106): pipeline-level
cost/quality/choreography cards from fleet journals + git + GitHub; and `--execute` now
hard-requires task stakes (#101, d089 flip): fail-loud, no normalize+warn shim. v1.19.0
shipped the instrument ABI (d091); v1.18.0/v1.17.0 shipped usage-aware failover (d083+d090)
and authoritative `--execute` governance (d086 node #1).* Plans 1–11 + the Fleet Conductor
release (v1.2.0) + fourteen minor releases since (v1.3 → v1.15) are all live: governed fleet,
learning router, front porch, GEPA optimizer, the coach, the project command center, agentic
executor, quality gates, usage governor, direct-model commands, and per-model token telemetry.
This document parks remaining ideas so they have a recorded home and aren't carried in
conversation memory.

Tracked as GitHub issues on **[Project #5: baton](https://github.com/users/Ryfter/projects/5)**.
Per-release detail lives in [`releases/`](releases/).

---

## Next up (priority order — updated 2026-07-13, d086)

**The spine: one authoritative golden "ship" path (d086).** Baton is *"half-working"* — the control
plane (routing, gates, cost/usage governance, verification, compound store, instrument registry,
worktree isolation) is best-in-class among peers but **opt-in and fail-open**, so it isn't on the
default path. Independent Grok + Codex + Claude assessments (2026-07-13) converged: best-*designed*,
least-*proven* (~8/10 architecture, ~5/10 shipping). Illustrated (with the honest caveat Kevin flagged):
the dispatch let Codex spend 102,305 tokens — thorough: it source-verified, cited exact lines, and caught
the CLI-only ABI gap (now node #4) — vs Grok's 1,964 (lighter, higher-altitude). NOT a "50x waste": the
answers weren't comparable, and grounding was arguably the right call for an audit you act on. The real
gap is that the depth/cost/stakes tradeoff was never a *deliberate, legible* choice — each instrument
defaulted. Governance should MATCH spend to stakes ("optimal, not best"), not force cheap; today Baton
makes neither the choice nor the tradeoff visible. **The golden path already EXISTS — it's `/baton:go`**
(the maestro/Conductor front door; `/baton:start` → `/baton:go`). The gap (per `go.md`, Kevin 2026-07-13):
its quality nodes are **opt-IN flags** (`--plan-gate`, `--gate-artifact`, `-Verify`, `--execute`) and
**fail open** (understaffed plan gate accepts, `go.md:79`; acceptance advisory-only, `go.md:52`). **Fix =
flip its defaults on `--execute`, don't rebuild it:**

> `/baton:go` → research gate → plan gate → cheapest-capable **verified labor** → **named review
> panel** → **compound artifact** → human merge

**SOON — the spine and its nodes (Kevin 2026-07-13):**

1. ~~**`/baton:go --execute`: quality nodes opt-in -> opt-out, fail-loud, depth matched to stakes**~~ —
   **SHIPPED v1.17.0 (2026-07-16, PRs #99+#100, issues #89+#98).** Gates default-on under
   `--execute` with `--no-*` escapes; degraded gates halt loudly; planner `stakes` +
   `--stakes` override → depth policy → journaled in `decisions.jsonl`. Missing-stakes
   hard-require deferred as #101 (d089). See [`releases/2026-07-16-v1.17.0.md`](releases/2026-07-16-v1.17.0.md).
2. ~~**Review named panel**~~ — **SHIPPED v1.16.0 (2026-07-14, PR #88).** The acceptance node: a
   config-driven roster of specialized review-role personas per diff/artifact (correctness,
   security/adversarial, architecture, spec-compliance, simplicity, framework/style), each **routed to
   the cheapest capable model**, findings tagged with role provenance, **fail-loud** on degraded panels
   (d086). Generic path byte-for-byte unchanged. See [`releases/2026-07-14-v1.16.0.md`](releases/2026-07-14-v1.16.0.md).
   *Its wiring into `/baton:go --execute` is node #1 below.*
3. **Compound default + measured** — the compound node: default closeout that leaves a findable
   artifact **and** answers "what concrete change prevents this class of failure next time?"; plus a
   **compound-rate** metric (% of runs producing a decision/lesson/guidance update — from the journal). *Needs a spec.*
4. ~~**Finish the instrument ABI**~~ — **SHIPPED v1.19.0 (2026-07-17, PRs #109+#110, issues
   #92+#104, d091).** One return contract, three transports (generic HTTP w/ exact tokens +
   hatch override, python/http tools routable, stdio-json for any language), `max_prompt_bytes`
   enforced pre-flight, `context_overflow` reactive class. See
   [`releases/2026-07-17-v1.19.0.md`](releases/2026-07-17-v1.19.0.md).
5. **Real-project bakeoff** — **IN PROGRESS (#93, spec committed 2026-07-18, slices ratified):**
   Baton vs. the manager/engineer baseline on 4 real MyDashboard slices (security fix, feature,
   refactor, + induced quota failure); measured via `/baton:ship-report` cards: completion / human
   intervention / gate catches / regressions / time / **effective-cost**. The missing end-to-end proof.

**Then (prior committed order):**

6. ~~**Usage-aware failover routing** (d083)~~ — **SHIPPED v1.18.0 (2026-07-16, PRs #103+#107,
   issue #94).** Reactive classifier + one substitute retry (slice 1) AND the d090 pre-flight
   buffer policy (probe, soft caps 75/85, operator escalation, surplus spend). Follow-up:
   #104 `context_overflow` class. See [`releases/2026-07-16-v1.18.0.md`](releases/2026-07-16-v1.18.0.md).
7. **Verified Labor V3** — artifact-batch parallelism. Spec'd.
8. **Verified Labor V4** — verification telemetry + require-verify graduation. Spec'd. (The
   ship-report spec, #106, feeds it.)

**New since 2026-07-16 (from live incidents + thinking session — pre-briefs in Grimdex `projects/baton/notes/`):**
- ~~**#101**~~ — shipped v1.20.0 (PR #113): `--execute` hard-requires task stakes, fail-loud.
- ~~**#104**~~ — shipped with v1.19.0 (see above).
- ~~**#106**~~ — shipped v1.20.0 (PR #112): `/baton:ship-report` per-PR cost/quality cards.
- **Unnumbered candidates:** durable scheduling (highest-leverage; Task-Scheduler steps + mailbox),
  SDLC loop (`--from-issue` intake + evidence write-back), reproducer panel role + shared
  verdict enum, effort-as-routing-dimension.

*Done 2026-07-12: docs currency + visual overview (four SVG infographics) → v1.15.1.*

---

## Shipped (no further work planned)

| # | Plan | What it ships | Tag |
|---|---|---|---|
| 1 | Observation foundation | hook + OTel + journal + catalog + `/log-routing`, `/consolidate-routing` | — |
| 2 | Dashboard | FastAPI + Jinja2 live web view at `http://localhost:8765` | — |
| 3 | Jobs + KB | `$BATON_HOME/jobs/`, `~/.claude/knowledge/`, eight `/job-*` and `/consolidate-lessons` commands | `plan3-complete` |
| 4 | Fleet | `fleet.yaml`, `/fleet doctor|test|list`, multi-provider dispatch | `plan4-complete` |
| 5 | Research ensemble | `/ensemble`, `/research`, concurrent fan-out + Claude-synthesized output | `plan5-complete` |
| 5b | Six Thinking Hats | `/six-hats`, role-prefixed preset on the ensemble primitive | `plan5b-shipped` |
| 5c | LLM Council | `/council`, two-round deliberate-and-refine preset | `plan5c-shipped` |
| 6 | Code phase | `/code-decompose`, `/code-parallel`, `/code-merge` with Agent worktree isolation | `plan6-shipped` |
| 7 | Command center | multi-project portfolio + per-project drill-in (`/projects`, `/projects/{id}`) | `plan7-shipped` |
| 8 | KB embeddings | `kb/` Python package, `/kb-index`, `/kb-search`, `/research` RAG pre-fetch, dashboard search panel | `plan8-shipped` |
| 8.1 | KB auto-index hook | `kb.index --file` + `kb-autoindex.ps1` PostToolUse hook (re-indexes only touched files) | — |
| 8.2 | KB pre-fetch everywhere | top-3 RAG pre-fanout added to `/ensemble` + `/six-hats` | — |
| 8.3 | Decisions filter + click-through | `/kb-search --decisions-only` + dashboard source render | — |
| 9 | Cross-machine fleet sync | `ollama-box2` over Tailscale (HTTP handler), per-host config, origin-host journal tag | `plan9-shipped` |
| 10 | Ensemble cockpit + streaming | live per-provider state/duration + partial-content + synthesis previews | `plan10-shipped` |
| 11 | Job-aware retrieval boost | `/kb-search` weights hits from the active job's project | `plan11-shipped` |
| — | Embedding A/B | `kb/ab_eval.py` harness; decision: keep `nomic-embed-text` (d011) | — |
| — | Auto-decision-capture | `decision-detect.ps1` heuristic (impl shipped; Stop-hook wiring is opt-in) | — |
| — | Decision Loop | auto-captured decision records + two-layer self-improvement consolidation | — |
| — | Cost Ledger | per-project `cost.md` + `/cost` command | — |

Specs for every plan live under [`docs/superpowers/specs/`](superpowers/specs/).

### Shipped since the Fleet Conductor release (v1.2.0 → v1.15.0)

Post–Plan-11 work ships as tagged releases, not numbered plans. Full notes in [`releases/`](releases/).

| Version | Release | What it ships |
|---|---|---|
| v1.2.0 | Fleet Conductor | capability-routing optimizer, cost-optimization engine, `/baton:idea`, tools registry, Grimdex integration |
| v1.3.0 | The Governed Fleet | usage governance over metered workers (lockouts, reset ETAs, conserve mode) |
| v1.4.0 / v1.4.1 | The Learning Conductor | router learns quality from ratings + an LLM judge; price-aware selection |
| v1.5.0 | The Front Porch | `/baton:start` guided entry — new-or-resume, then hand off to `/baton:go` |
| v1.6.0 | The Evolving Baton | real GEPA optimizer for the Conductor planner prompt (candidate pool) |
| v1.7.0 / v1.7.1 | The Proving Ground | live shadow A/B testing of prompt candidates + optimizer hardening |
| v1.8.0 / .1 / .2 | The Coach | guided-use rules engine, session digest, `Next:` footers; memory-bridge follow-ups |
| v1.9.0 | Project Command Center (L1) | project registry + CLI leader — one front door across every project |
| v1.10.0 | Fleet Round-Trip Proof | `fleet doctor --live` end-to-end proof against real installed CLIs (labor Slice 1) |
| v1.11.0 / .1 | Fleet does the labor (S2) | agentic executor — instruments edit files and return repo-applied results; multimodel hardening |
| v1.12.0 | Plan Gate | competitive plan review (accept/revise/reject) before any labor runs (d080) |
| v1.13.0 | Verified Labor V2 | require-verify on labor artifacts before acceptance |
| v1.14.0 | Copilot Credit Budget | fail-open `/baton:usage` spend panel over the GitHub billing API (d079) |
| v1.15.0 | Direct-model commands | `/baton:codex\|grok\|gemini\|agy` + per-model token telemetry + named tiers (d084) |

---

## Parked

The Tier 1–3 backlog (issues #16–#26) is **cleared** — see the Shipped table and
[`releases/2026-06-04-backlog-clearance.md`](releases/2026-06-04-backlog-clearance.md).
What remains:

- ~~**Cross-project consolidation sweep.**~~ **Unblocked + verified 2026-06-05.** A second project (`answerbot`) was registered in the knowledge base with its own decision records. `/consolidate-decisions` now promotes patterns shared across ≥2 projects to `universal/decision-guidance.md` — the first promoted rule ("Back up every project to a private GitHub repo", positive in both `baton` and `answerbot`) is live, and re-runs are idempotent. As more projects accrue decisions + feedback, additional shared patterns will promote automatically.
- ~~**Wire `decision-detect` as a `Stop` hook.**~~ **Done 2026-06-05** — `scripts/hooks/decision-detect.ps1` is deployed to `~/.claude/hooks` and registered as a `Stop` hook in `~/.claude/settings.json`; bootstrap now deploys + registers it for reproducibility. At end of each turn it scans the final message for decision phrasing and, on a hit, writes a review-ready intake draft to `$TEMP` (advisory — it doesn't auto-create the record; the orchestrator's two-step intake remains authoritative).

### Compound-engineering backlog (do-later, from the Every article — 2026-07-13)

Reference lives in Grimdex (`projects/baton/notes/compound-engineering.md`). Baton already
implements most of the Plan → Work → Review → **Compound** loop; these close the remaining gaps.
System-investment track — run alongside features (the 50/50), not instead of the priority order.

- **Named review-role roster** — **→ promoted to Next up (SOON), 2026-07-13.** See above.
- **Compound default + measured** — **→ promoted to Next up (SOON), 2026-07-13.** See above.
  (Model on CE's `/workflows:compound` six subagents incl. a *prevention strategist*.)
- **Release → announce compound sub-step.** Generate the downstream artifacts off a run the way
  CE does: plan → release notes → social posts → screenshots, shipped together. (We did this
  chain by hand for v1.15.1 this session — release notes, then the X + LinkedIn drafts.)

**Bigger framing (dNNN positioning):** the substrate generalizes the loop *beyond coding* —
copywriting/brand voice, product marketing, user research, AI analysis all ride the same
Plan→Work→Review→Compound loop with different **artifact types + review roles + checks**. But
**Baton is a coding tool first** (Kevin 2026-07-13: "at its heart... a coding tool... not at the
expense of the coding bot being awesome"). The general-conductor / non-coding profiles are
**LOW-PRIORITY backlog**, admitted only when they don't detract from coding quality; generalize
the *artifact + review-role + check* abstraction **opportunistically at the named-review-roster
seam**, never as a rescope or rebrand. Coding priority order is unchanged (d083 → V3 → V4).
Keystone if/when pursued: a codified **Voice/Brand skill** that copywriter + product-marketing
inherit; AI analysis is the strongest-check non-coding profile (Kevin's BI wheelhouse). (Grimdex
reserves `Grimlore` for the future general second-brain KB — the knowledge layer anticipates this split.)

### Housekeeping ideas (no issue tracked yet)

- ~~Bootstrap should print a one-line "version vs. deployed" diff at startup.~~ **Done 2026-06-05** — Step 0 compares the repo's nearest `v*` tag against `~/.claude/.cao-version` (written on each deploy).
- ~~Refresh the bootstrap "Next steps" from the Plan-1 era to surface Plan 5/6/7/8 commands.~~ **Done 2026-06-05** — now lists dashboard, fleet/ensemble/six-hats/council, code phase, jobs+KB, projects+cost, and the consolidators.
- ~~**Bootstrap hangs on `Read-Host` in non-interactive runs.**~~ **Done 2026-06-05** — bootstrap now supports `-NonInteractive`, auto-detects redirected stdin, and keeps differing deployed files instead of blocking. The dry-run smoke test exercises this path with `-NonInteractive`.

---

## Decision records

Every architectural choice is captured under `~/.claude/knowledge/projects/baton/decisions/` — the
model-agnostic knowledge base, not this repo. The log now runs through **d084** (GitHub-ops split,
2026-07-11); reference records by id rather than duplicating them here. The table below is a
historical Plan-era snapshot (d001–d013):

| ID | Topic |
|---|---|
| d001 | Cost ledger: per-project `cost.md` + `/cost` command |
| d002 | Plan 5b Six Hats — parallel role dispatch, no per-hat config |
| d003 | Plan 5c LLM Council — two rounds, peer-only critique, quorum 2, cap 5 |
| d004 | Plan 6 code phase — three commands, Agent worktree isolation, cherry-pick default |
| d005 | Plan 7 — read-only multi-project command center, hand-rolled YAML parsing |
| d006 | Plan 8 — local Ollama embeddings + numpy flat search; Python core with PS wrappers |
| d007 | Backlog execution as a fleet model-performance bench, tracked on Project #5 |
| d008 | Unattended dispatch = worktree-per-item + hard merge gate (orchestrator owns the merge) |
| d009 | Only agentic file-editing CLIs (codex, claude) implement; text-only models do research/review |
| d010 | Gated items merge per-item-branch → master; Gemini is the design/interface reviewer |
| d011 | Keep `nomic-embed-text` as the default KB embedding model (A/B vs `mxbai-embed-large`) |
| d012 | Fleet journal tags origin host as the dispatching machine (trailing field) |
| d013 | Ensemble cockpit surfaces partials by reading per-provider `.md` + `synthesis.md` |
