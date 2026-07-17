# Baton glossary — the domain language

One canonical vocabulary so every agent (Claude, Codex, Grok, Gemini, local models) and every
brief speaks the same language. Fleet briefs should reference this file ("terms per
`docs/glossary.md`") instead of re-explaining concepts inline.

## The three tiers (the musical model)

- **Conductor** — the thin natural-language front door (`/baton:go`). Holds the operator's
  intent, dispatches everything, decides nothing an Orchestrator or the operator should decide.
- **Orchestrator** — the brain: planning, routing, gating, verification. One type, two modes
  (plan / execute).
- **Instrument** — a fleet worker (a model behind a CLI/HTTP endpoint) that performs labor:
  build, review, research. Instruments never merge.
- **Fleet** — the roster of instruments in `~/.baton/fleet.yaml` (box-private; the repo seed
  carries placeholders only).
- **Front door** — any entry surface that drives Baton (slash commands, `baton_mcp`). Front
  doors invoke the same CLI surface; they are never a parallel code path.

## The golden path (d086)

- **Spine** — the sequence of issues making `/baton:go` the one authoritative, fail-loud ship
  path (umbrella #97, label `d086-spine`).
- **Gate** — a quality checkpoint. Three kinds: **plan gate** (reviews the plan before
  execution), **acceptance gate/panel** (reviews the artifact; the *named panel* is its
  role-based reviewer roster), **verify** (runs the artifact's own checks).
- **Fail-loud** — a degraded gate HALTS the run and names why (exit 1). Opposite of
  **fail-open** (proceed with a warning), which is reserved for advisory signals only.
- **Merge word** — the operator's explicit, per-PR approval. Nothing merges without it; one
  PR's word never extends to another.

## Stakes and depth (v1.17.0)

- **Stakes** — how much a task matters (`low | standard | high`), set by the planner or the
  operator (`--stakes`, basis journaled as `stakes_basis`).
- **Depth tier** — how much model capability a dispatch buys (`tier_low/med/high` provider
  args). **Depth policy** (`Resolve-TaskDepthPolicy`) maps stakes → allowed tiers and cost caps.
- **Champion / selection mode** — routing picked the strongest qualifying candidate rather
  than the cheapest (`selection_mode` in the journal).
- **Cost tier** — `free | economy | paid`; `max_cost_tier` is a ceiling, never silently exceeded.

## Usage governance (d083 / d090)

- **Usage Governor** — the journal-backed state machine tracking provider availability:
  **lockout** (exhausted until reset), **cooldown** (short pause), **limited** (advisory soft
  state), `waiting_for_reset`.
- **Reactive classifier** (`usage-classify-lib.ps1`) — classifies a failed dispatch's
  exit/stdout/stderr into `quota_exhausted | rate_limit_burst | auth_config | context_overflow |
  server_overload | ambiguous`; auth is evaluated first and never triggers failover.
  `context_overflow` is not a usage failure (no lockout/cooldown; provider stays routable);
  remedy is shrink/split the prompt or reroute to a larger-context peer.
- **Failover hop / substitute retry** — ONE retry on a same-capability peer after the primary
  is locked; honors stakes/depth policy and cost ceilings; never cascades.
- **quality_first** — failover posture: substitute only equal-or-better; otherwise surface
  "no peer available" loudly rather than silently downgrade.
- **Pre-flight / soft cap** — Layer 2: probe a provider's used% before dispatch; above the
  operator's soft cap (e.g. 75% of 5h, 85% weekly), hold for the operator instead of dispatching.
- **Surplus spend** — prefer a provider with headroom as its window reset approaches
  (use-it-or-lose-it), within all quality/cost guards.

## Verification and memory

- **Verified Labor** — the contract that an instrument's claim ("tests green") is verified,
  not trusted; includes **one-clean-retry** in a fresh worktree (a retry never runs over
  another model's partial edits).
- **Journal** — append-only run records: the fleet journal (per-dispatch rows incl. `tok:N`
  with basis `exact|estimate`) and `decisions.jsonl` (per-task routing decisions).
- **Compound** — the closeout artifact + prevention answer a run leaves behind (#91).
- **Taste seam** — a deliberate interrupt where the operator injects judgment (design forks,
  merge words, over-cap dispatches). Automation routes *between* seams, never through them.
- **d-records** — numbered decision records (`d086`) in the knowledge base; referenced by id,
  never duplicated.
- **Box-private** — data that never leaves the operator's machines: real rosters, endpoints,
  quotas, allowances, scorecards. Repo seeds and docs carry placeholders.

## House rules shorthand

- **965-byte rule** — no shell argument over 965 bytes; long content travels as files.
- **d059 honesty** — never claim green without running; label token counts exact vs estimate.
- **Observe-first (d078)** — new signals surface and journal before they are allowed to route.
