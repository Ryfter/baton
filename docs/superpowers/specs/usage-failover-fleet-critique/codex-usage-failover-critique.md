# Codex usage-failover critique (final verdict; repo-exploration prose trimmed)

_Codex v0.144.1 · 297s · 146,049 tokens · 2026-07-11_


- **Claude subscription:** Partly observable. `/usage` shows plan bars and resets; status-line JSON exposes five-hour/seven-day `used_percentage` and `resets_at`, but only for Pro/Max and only after the first response. Exhaustion errors explicitly identify session/weekly/Opus limits and often include reset time. There is no documented zero-cost, standalone headless quota query for `claude -p`; proactive collection requires session/status-line integration or adopting Agent SDK rate-limit events. [Claude status-line fields](https://code.claude.com/docs/en/statusline), [Claude limit errors](https://code.claude.com/docs/en/errors)

- **Grok subscription:** Weak automation surface. Grok Build has interactive `/usage` for credit usage/billing, but xAI documents no machine-readable schema or headless quota command for `grok -p`. `/context` is context-window usage, not account quota. xAI API RPS/TPM limits and 429s belong to API teamsΓÇönot necessarily the Grok subscription used by the CLI. Treat subscription exhaustion reactively unless xAI adds a supported query. [Grok commands](https://docs.x.ai/build/modes-and-commands), [xAI API limits](https://docs.x.ai/developers/rate-limits)

- **Copilot:** The billing API reports consumed AI credits/premium requests by user or organization. It does **not** directly return ΓÇ£included allowance remaining.ΓÇ¥ Budget endpoints return configured overage budgets, also not the plan allowance. Baton must combine usage with a verified entitlement/configured allowance; otherwise `% remaining` is inferred and potentially wrong. Billing data may lag. [Billing usage API](https://docs.github.com/en/rest/billing/usage), [Budgets API](https://docs.github.com/en/rest/billing/budgets)

Token telemetry cannot solve this generally: subscription quotas use provider-specific rolling windows and weighting, with no published token denominator.

### B) Architecture

Use a **hybrid**, with reactive failover as the correctness layer.

- Normalize observations as `{worker, scope, used_pct, reset_at, source, observed_at, confidence}`. Scope must distinguish five-hour, weekly, model-specific, subscription, API rate limit, and paid-credit budget.

- Pre-dispatch swap only on fresh authoritative data:

  - hard: `used_pct >= 100`;
  - soft: remaining headroom below a configurable reserve, e.g. 10%;
  - forecast: expected task consumption exceeds remaining headroom.

- Always classify post-dispatch failures:

  - subscription/quota exhausted ΓåÆ `waiting_for_reset`;
  - temporary 429 with retry/reset ΓåÆ `cooling_down`;
  - ambiguous 429/server overload ΓåÆ short cooldown, not exhaustion;
  - auth/config errors ΓåÆ no failover loop.

- Pick the next candidate from Baton's existing capability ladder, requiring the same capability, `agentic` class, context floor, tool/permission profile, quality floor, and cost ceiling.

- For coding agents, retry in a clean worktree or only when the failed attempt produced no accepted diff. Never run a substitute blindly over partially completed edits.

### C) Risks

- **Flapping:** Sticky provider choice per run; hysteresis such as swap out at 90%, restore below 70%; minimum cooldown; restore only after reset plus successful canary.

- **Quality drop:** Capability equivalence is insufficient. Require a learned-quality floor and acceptance gate; journal and visibly report every substitution.

- **Cost blindspot:** Never silently replace subscription-included work with metered API work. Enforce `max_cost_tier`/run budget; paid fallback requires explicit policy.

- **Stale data:** Give each source a TTL. Expired/unknown telemetry must not hard-block a healthy provider; dispatch and rely on reactive classification.

- **Retry storms:** Maximum one automatic failover per task, maintain an attempted-provider set, and stop with the collected errors when the ladder is exhausted.

### D) Smallest useful slice

Extend the already-shipped Usage Governor reactively:

1. Parse quota/rate-limit failures from every fleet dispatchΓÇÖs exit code plus stdout/stderr.
2. Append `lockout`, `cooldown`, or `limited` with parsed reset time.
3. Retry once using the next same-capability peer, from clean state.
4. Journal `original_worker`, `substitute`, `reason`, `reset_at`, and whether partial output/diff existed.
5. Add hermetic fixtures for Codex, Claude, Grok, generic 429, overload, and ambiguous errors.

Then add proactive adapters incrementally: Codex app-server first, Claude status-line/SDK second, Copilot billing reconciliation third. Do not build a Grok TUI scraper.


146,049

