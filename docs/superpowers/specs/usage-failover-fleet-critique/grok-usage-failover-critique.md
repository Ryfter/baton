I'll ground the critique in what each provider actually surfaces for remaining quota, then map that to a failover architecture.## A) Remaining usage ΓÇö what you can actually know

| Provider | Proactive remaining? | What surfaces | Reality for Baton |
|---|---|---|---|
| **Codex (ChatGPT sub)** | **Partial, fragile** | Interactive `/status` + `/statusline` show 5h + weekly **remaining %**. Not a stable headless REST quota API. OpenAI **API** `x-ratelimit-remaining-*` is a different product path (API key tiers), not ChatGPT Codex allotment. | Scrape/session-parse if you accept breakage; otherwise **reactive** on ΓÇ£usage limitΓÇ¥ / rate-limit text. Token trailers Γëá plan remaining. |
| **Grok (xAI sub)** | **No** (consumer) | SuperGrok: no public remaining-quota API; users hit wall blind. **API** tier shows RPS/TPM in console; headers are short-window rate limits, not ΓÇ£sub days left.ΓÇ¥ | Almost pure **reactive**. Journal ticks + estimate tokens only measure *burn*, not *headroom*. |
| **Claude (Pro/Max sub)** | **Partial UI, weak CLI** | Web Settings ΓåÆ Usage: 5h session + weekly bars. API: excellent `anthropic-ratelimit-*-remaining` + Rate Limits API ΓÇö but that is **API org limits**, not Claude Code subscription. Claude Code statusline/hooks sometimes expose session/week %; no guaranteed machine-readable contract. | Treat sub path as **reactive** (parse limit errors + optional best-effort status scrape). DonΓÇÖt confuse API headers with sub quota. |
| **Copilot** | **Yes (best)** | Billing REST: AI-credit **usage** reports (user/org); plan table ΓåÆ allowance; remaining Γëê allowance ΓêÆ used; run-rate ΓåÆ days-left. Lag possible; org-billed seats need org endpoints. | Only provider where **proactive forecast** is honest. Fail-open panel is correct. |
| **Local (ollama/LM Studio)** | N/A | Hardware/time, not quota. | Never failover *away* for ΓÇ£quotaΓÇ¥; only load/latency. |
| **Token telemetry (specΓÇÖd)** | Consumption only | Post-dispatch tokens (exact/estimate). | Feeds **burn rate**, not remaining. Alone cannot drive ΓÇ£near cap.ΓÇ¥ |

**Hard truth:** ΓÇ£Remaining usageΓÇ¥ is **heterogeneous and mostly untrusted**. Copilot is the outlier with a real billing surface. Codex/Claude give human % in product UI; CLIs are secondary and unstable. Grok sub is opaque. Uniform proactive ΓÇ£% left per modelΓÇ¥ is a fiction unless you invent local budgets.

---

## B) Architecture: hybrid, reactive-primary

**Right shape: reactive core + opportunistic probes + local budgets.** Do not build a universal proactive quota oracle.

```
dispatch ΓåÆ (optional soft probe) ΓåÆ invoke
         ΓåÆ on hard fail: classify ΓåÆ journal lockout ΓåÆ Select-Capability route-around
         ΓåÆ on soft signal (Copilot %, codex status scrape): limited / conserve, not hard-exclude
```

**Layers (in order of reliability):**

1. **Reactive failover (must ship first)**  
   - Classify stderr/exit: `quota_exhausted` vs `rate_limit_burst` vs `auth` vs `transient`.  
   - Map to existing Usage Governor states:  
     - hard: `exhausted` / `waiting_for_reset` (+ `reset_at` if Retry-After / ΓÇ£resets at ΓÇªΓÇ¥)  
     - soft: `cooldown` (short 429) or `limited`  
   - Retry **once** on substitute from same capability band; no unbounded cascade.

2. **Proactive only where signal is real**  
   - **Copilot:** poll billing ΓåÆ write `tick` + optional `limited` at 80/90%.  
   - **Codex:** optional headless probe of `/status` output **if** you can get it without a TUI; treat as soft, TTLΓÇÖd, fail-open.  
   - **Claude/Grok sub:** skip proactive remaining until vendor exposes it.

3. **Local operator budgets (already half-built)**  
   - `fleet.yaml` `budget` + journal `tick` + forecast `days_to_exhaustion` ΓÇö already Usage Governor / saturation.  
   - These are **policy caps**, not vendor truth. Label them `local_budget`, never pretend API remaining.

**Swap trigger:**  
- Hard: classified quota/rate-limit failure ΓåÆ lockout ΓåÆ next `Select-Capability` pass excludes worker.  
- Soft: remaining% < threshold **only** if `source Γêê {billing_api, status_probe}` and `freshness < TTL`.  
- Never soft-exclude on estimated tokens alone.

**Substitute selection:**  
- Same **capability class** (implementer / review / research), not same brand.  
- Reuse `Select-Capability` after route-around filter (already the chokepoint).  
- Prefer: same tier peers ΓåÆ cheaper paid ΓåÆ local.  
- Explicit **quality floor**: if task is `hard`/`orchestrator`, refuse silent drop to weak local; surface ΓÇ£no peer available.ΓÇ¥  
- Record `failover_from` / `failover_to` / `reason` in journal for learning, not silent rewrite of primary preference forever.

**Do not invent a parallel router.** Extend Usage Governor Sprint 2.5 (auto-detect) + existing route-around; proactive Copilot/Codex are **event producers** into the same journal.

---

## C) Risks & mitigations

| Risk | Mitigation |
|---|---|
| **Flapping** | Sticky lockout with `reset_at` / min cooldown (e.g. 15ΓÇô60m); hysteresis: enter soft at 85%, exit only below 70% after TTL; max 1 failover hop per task; donΓÇÖt re-probe every dispatch. |
| **Silent quality drop** | Capability-class + min quality; log swap loudly; optional `failover_policy: sticky\|quality_first\|never`; never auto-swap the orchestrator role without human policy. |
| **Cost blindspot** | Failover to metered API can **increase** $ while saving sub minutes. Track cost-tier of substitute; refuse upgrade-to-paid without flag; pair with effective-cost metric, not token count alone. |
| **Stale usage data** | Every remaining figure has `source`, `observed_at`, `ttl`, `confidence`. Stale ΓåÆ ignore for hard exclude; reactive path always wins. Fail-open probes. |
| **Wrong signal (RPM vs weekly vs $)** | Class taxonomy: `burst_rpm` ΓåÆ short cooldown; `plan_window` ΓåÆ waiting_for_reset; `monthly_credits` ΓåÆ exhausted until cycle. Misclassifying 429 as weekly kills a healthy peer for hours. |
| **Double-spend / wasted call** | One reactive attempt max; mark primary locked *before* retry so parallel fleet doesnΓÇÖt pile on. |
| **Scraper fragility** | Status scrapes behind feature flags; golden tests on fixture stdout; degrade to reactive on parse fail. |

---

## D) Smallest first slice (real value, low build)

**Ship ΓÇ£Sprint 2.5 done rightΓÇ¥ ΓÇö not multi-provider remaining%.**

1. **Classify dispatch failures** ΓåÆ append `lockout`/`cooldown` with parsed `reset_at` when present (regex library over known Codex/Claude/Grok/gh models strings). Fail-open if ambiguous.  
2. **Route-around already works** ΓÇö wire auto events so `Select-Capability` skips the dead worker on the *next* (and same-task retry) pick.  
3. **Single retry on substitute** (same capability), journal the hop, surface one line to operator.  
4. **Copilot billing panel** (planned) as **observe-only** ΓåÆ later soft `limited` at 90%; no hard failover until classification is trusted.  
5. **Do not** scrape Codex/Claude status, do not build ML forecast, do not unify ΓÇ£% remainingΓÇ¥ across providers in v1.

**Done when:** codex dies mid-run ΓåÆ next pick is grok/claude peer without manual `/baton:usage lockout`, no thrash, quality policy honored.

**Explicit non-goals for slice 1:** proactive multi-provider headroom map; ΓÇ£always know remainingΓÇ¥; token-estimate-driven swaps.

---

**Bottom line:** Usage-aware failover is valid, but ΓÇ£track how much each model has leftΓÇ¥ is only true for **Copilot (+ optional local budgets)**. Everywhere else, design for **error-driven availability**, not forecasted remaining. Build on Usage Governor + `Select-Capability`; reactive first, probes as optional soft inputs, never as source of truth.

