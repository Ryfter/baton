# Copilot Credit Budget — design spec

**Status:** design (approved to spec 2026-07-06). Follow-up track; not scheduled for build.
**Author:** Claude (orchestrator), with Kevin.
**Decision record:** d079 (this spec's key choices).

## 1. Problem

Kevin burned ~1018 of his 1500 monthly GitHub **Copilot AI Credits** ($0.01/credit,
$15 allowance) in the first days of a cycle and had no idea until he opened the
GitHub billing page by hand. The drain turned out to be **Copilot automatic PR code
review** (a ruleset toggle he enabled without knowing it metered), re-reviewing on
every push. Nothing about it was Baton — but the episode is a direct hit on Baton's
cost-legibility north star: a metered AI spend Kevin couldn't see until a week later.

Baton's Usage Governor already forecasts per-worker budgets (`Get-WorkerBudget` +
`Get-UsageForecast`: run-rate → days-to-exhaustion), but it only knows what Baton
itself dispatches. It has zero visibility into the Copilot credits Kevin's IDE, CLI,
and the PR-Reviewer app consume. This spec closes that gap by pulling the real number
from GitHub's billing API and surfacing it in `/baton:usage`.

## 2. Scope

**In:**
- Fetch current-cycle Copilot AI-credit usage from GitHub's user-level billing API.
- Surface a Copilot-credit panel in `/baton:usage`: used / allowance / % / remaining /
  days-to-exhaustion, plus a per-model split (the finest granularity a personal account
  exposes).
- A coach-style threshold warning (default 80% of allowance) so the next `/baton:usage`
  (or a coach surface) can flag the burn before the cycle is gone.
- Box-private config on the `gh-copilot` fleet entry: the `budget` (allowance in credits)
  and a `credit_reset_day` (billing-cycle anchor for the forecast).

**Out (YAGNI / later slices):**
- **Governing** — actively throttling Baton's own dispatch or entering conserve mode
  based on the Copilot credit level. This slice is *informational + warning* only.
- **Per-source split** (IDE vs Chat vs agent vs PR-review). GitHub only exposes that in
  enterprise NDJSON reports, not for an individual account. Per-model is the ceiling.
- Enterprise / org billing endpoints.
- Auto-toggling the Copilot PR-review ruleset (that's an account action, not Baton's).
- Historic backfill / charts.

## 3. Granularity ceiling (honesty)

GitHub's user-level endpoint
`GET /users/{username}/settings/billing/ai_credit/usage` returns `usageItems[]`, each:

```json
{ "product": "Copilot AI Credits", "sku": "AI Credit", "model": "GPT-5",
  "unitType": "ai-credits", "pricePerUnit": 0.01,
  "grossQuantity": 100, "grossAmount": 1, "netQuantity": 100, "netAmount": 1 }
```

Filterable by `model` and `product`. This is **current-billing-cycle aggregate by
model/product**, not per-day and not per-source. The docs are explicit: user endpoints
only apply to a **personally-purchased** Copilot plan (org/enterprise-managed licenses
use org/enterprise endpoints instead) — Kevin's $15 personal plan qualifies. The panel
must therefore never claim a source ("Chat did it"); it reports the model mix and the
budget math, and points the human at GitHub's own analytics for source detail.

## 4. Components

All new code lives in one focused library, `scripts/copilot-credit-lib.ps1`, plus a
render call from the existing `/baton:usage` runner. No new subsystem; the forecast math
reuses the Usage Governor's existing shape.

### 4.1 `Get-CopilotCreditUsage`

```
Get-CopilotCreditUsage [-User <string>] [-Fetcher <scriptblock>]
  -> @{ ok = <bool>; used = <double>; amount = <double>; currency = 'USD';
        by_model = @( @{ model; credits; amount } ... );
        fetched_at = <iso8601>; reason = <string|null> }
```

- Resolves the GitHub login (from `-User`, else `$env:BATON_GH_USER`, else
  `gh api user --jq .login`).
- Calls the billing endpoint through the injectable **`-Fetcher`** seam (default =
  a thin wrapper over `gh api "users/$user/settings/billing/ai_credit/usage"`; note:
  no leading slash — a leading `/` is only a Git Bash MSYS path-rewrite hazard, and
  Baton runs under pwsh where it is safe, but the wrapper omits it regardless).
- Sums `grossQuantity` across `product == "Copilot AI Credits"` rows into `used`, folds
  the per-model breakdown into `by_model`, sums `grossAmount` into `amount`.
- **Fail-open, never throws.** Any failure sets `ok=$false` + a human `reason` and
  leaves the numbers null:
  - `gh` not on PATH → `reason = 'gh-cli-missing'`
  - HTTP 404 / "needs the user scope" → `reason = 'insufficient-scope'` (with the exact
    `gh auth refresh -h github.com -s user` hint surfaced by the caller)
  - org-managed license (endpoint returns nothing applicable) → `reason = 'org-managed'`
  - offline / non-JSON / schema drift → `reason = 'fetch-failed'`

### 4.2 `Get-CopilotCreditForecast`

```
Get-CopilotCreditForecast [-User] [-FleetPath] [-Now <datetime>] [-Fetcher]
  -> @{ status; used; budget; remaining; pct; by_model; reset_date;
        days_elapsed; days_left_in_cycle; run_rate; days_to_exhaustion; reason }
```

- Reads the allowance via the existing `Get-WorkerBudget -Worker 'gh-copilot'` (the
  `budget` field already supported on any fleet entry — no fleet-schema change).
- Reads `credit_reset_day` from the same `gh-copilot` entry (new optional field; a
  day-of-month 1–28). Absent → forecast falls back to `status='no_reset_anchor'` and
  reports used/budget/% without a run-rate.
- Computes the cycle window from `credit_reset_day` and `-Now`: `days_elapsed` since the
  last reset, `reset_date` = next reset, `days_left_in_cycle`.
- **Cycle-anchored run-rate:** `run_rate = used / max(1, days_elapsed)` credits/day.
  `days_to_exhaustion = remaining / run_rate` (guard run_rate 0 → null). Works on the
  **first call** with no local history — no journal snapshots required.
- `status`:
  - `unavailable` — fetch failed (carries `reason` from §4.1).
  - `no_budget` — fetched OK but no `budget` configured (shows used only).
  - `no_reset_anchor` — budget but no `credit_reset_day` (used/budget/% only).
  - `ok` — full forecast.

### 4.3 `/baton:usage` render

- After the existing worker-state render, if a Copilot budget is configured, append a
  **Copilot Credits** panel:
  ```
  Copilot Credits   1018 / 1500  (68%)   ·   ~$10.18 of $15.00
    run-rate 145/day · ~3.3 days to exhaustion · resets 2026-07-31 (25d)
    by model: GPT-5 612 · Claude-Sonnet 300 · Gemini 106
    ⚠ over 80% — check Copilot code-review ruleset (biggest metered driver)
  ```
- If no budget configured → **byte-for-byte unchanged** `/baton:usage` (the panel only
  appears once Kevin opts in via fleet.yaml). If configured but `status=unavailable`,
  show a single honest line: `Copilot Credits — unavailable (<reason>)` + the scope hint
  when `reason='insufficient-scope'`.
- `--json` includes the `Get-CopilotCreditForecast` object under a `copilot_credits` key.

## 5. Config (box-private)

Real numbers live ONLY in the live `~/.baton/fleet.yaml`; the shared `references/fleet.yaml`
seed carries commented placeholders (per the standing box-private rule):

```yaml
- name: gh-copilot
  # ... existing fields ...
  budget: 1500            # monthly Copilot AI-credit allowance (credits)
  credit_reset_day: 10    # billing-cycle reset day-of-month (1-28)
  credit_warn_pct: 80     # optional; default 80 — threshold for the ⚠ line
```

The seed adds these three as **commented** example lines with a one-line note that the
allowance/reset are per-account and must be set in the live file.

## 6. Auth

- **Default:** piggyback the existing `gh` login via `gh api`. No new token to manage.
- The billing endpoint needs the token to carry the **`user`** scope (and billing read).
  If `gh`'s token lacks it, the fetch returns `insufficient-scope` and the panel surfaces
  the exact fix: `gh auth refresh -h github.com -s user`.
- **Fallback:** if `$env:BATON_GH_BILLING_TOKEN` is set, the default fetcher uses it
  (a PAT scoped for billing read) instead of ambient `gh` auth. Box-private; never
  logged, never written to the repo or the usage-journal.

## 7. Error handling

Every path is advisory and fail-open — the Copilot panel can never break `/baton:usage`
or change its exit code. All failures collapse to a one-line "unavailable (<reason>)"
render and an `ok=$false` object. No credential value is ever emitted to stdout, the
journal, or logs.

## 8. Testing

Hermetic, per house rules — never touches real `gh`, `~/.baton`, `~/.claude`, or the
network:
- Inject a fake **`-Fetcher`** returning canned `usageItems` JSON; assert `used`,
  `by_model`, and `amount` folding.
- Forecast branches: `ok` (budget + reset day, first-call rate), `no_budget`,
  `no_reset_anchor`, `unavailable` (fetcher throws / returns error).
- Cycle-window math: reset-day boundary cases (before/after reset day in the month,
  day-28 clamp), `days_elapsed` never 0 (guard), run_rate 0 → `days_to_exhaustion` null.
- Render: panel present when budget configured, absent (byte-for-byte) when not,
  honest line + scope hint on `insufficient-scope`.
- `--json` carries `copilot_credits`.
- Temp `BATON_HOME` + temp fleet.yaml + `try/finally` restore.

## 9. Deployment / docs

- New `scripts/copilot-credit-lib.ps1` MUST be wired into `bootstrap.ps1`'s deploy
  manifest **and** a `test-bootstrap.ps1` deploy-assert (the v1.8.0 coach-lib omission
  lesson: a new lib that isn't in the manifest silently fails to deploy on-box).
- Update the `/baton:usage` command doc with the Copilot-credits panel + the three
  fleet.yaml fields + the scope requirement.
- One line in `docs/agent-handoffs.md` (cross-agent continuity).
- Plugin **minor** bump.

## 10. House rules (binding)

965-byte arg ceiling (files for anything large); `[Console]::Error.WriteLine` + `exit 2`
for CLI errors (never `Write-Error` under Stop); `utf8NoBOM` writes; `ConvertFrom-Json`
auto-parses ISO dates → re-stringify on round-trip; `ConvertTo-Json -InputObject @(...)`
for guaranteed arrays; never name vars `$args/$input/$event/$matches/$host/$pid`;
unary-comma flatten only on direct-assignment returns, `@()` when callers pipe; guard
0/0 → NaN; box-private placeholder hosts/numbers only in the shared seed.

## 11. Execution (when scheduled)

Subagent-driven, per Kevin's model ladder. Transcription-grade tasks (the lib with
complete code in the plan) → Haiku; the `/baton:usage` render integration → Sonnet;
Opus final whole-branch review. Streamlined ceremony (no per-task reviewers; one final
review).

## 12. Decisions (d079)

- **Informational-first, not governing.** The point Kevin raised was invisibility, so
  the MVP makes the spend visible + warns; it does not throttle Baton's own dispatch on
  the Copilot level. Governing is a named later slice. Revisit-if: the panel proves out
  and Kevin wants Baton to auto-conserve against Copilot credits.
- **`gh api` piggyback auth, `BATON_GH_BILLING_TOKEN` fallback.** Reuses the existing
  login (zero new secret in the common case); the env-var PAT is the escape hatch when
  the ambient token lacks the billing scope. Revisit-if: `gh`'s default scope stops
  covering billing, or a second box needs a headless token.
- **Cycle-anchored run-rate (used ÷ days-elapsed), not journal snapshots.** Works on the
  first call with no accumulated history and needs only the `credit_reset_day` anchor;
  avoids a snapshot-diff subsystem for an informational readout. Revisit-if: a smoother
  trailing-window rate is wanted (then snapshot deltas into the usage-journal as `tick`s
  and reuse `Get-UsageForecast` unchanged).
- **Reuse `Get-WorkerBudget`'s `budget` field; no fleet-schema change.** The allowance
  rides the existing per-worker `budget` int; only `credit_reset_day` / `credit_warn_pct`
  are new optional fields. Revisit-if: credits and request-budgets need to coexist on one
  worker with different units.
