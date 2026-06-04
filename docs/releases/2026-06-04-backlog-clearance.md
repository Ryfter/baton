# Release notes — 2026-06-04 — Backlog clearance (Plans 9–11 + KB hooks + fleet hardening)

This release closes out the entire post–Plan-8 backlog on
[Project #5](https://github.com/users/Ryfter/projects/5). It bundles the work
completed across the autonomous backlog runs of 2026‑05‑31 → 2026‑06‑04 plus the
interactive finalization session, and it leaves the tracker empty.

**Master tip at release:** `17abade`
**Tags:** `plan9-shipped`, `plan10-shipped`, `plan11-shipped`

---

## What shipped

| Issue | Title | Delivered | Merge |
|---|---|---|---|
| #16 | Plan 8.1 — auto-index hook on KB writes | `kb.index --file` single-file path + `kb-autoindex.ps1` PostToolUse hook (re-indexes only the touched file) | `f4baa61` |
| #17 | Plan 8.2 — extend KB pre-fetch to `/ensemble` + `/six-hats` | KB pre-fanout retrieval block added to both commands | `d3f45e7` |
| #18 | Plan 8.3 — `--decisions-only` filter + dashboard click-through | `kb-lib.ps1`/`kb-search.md` filter + dashboard KB router/templates | `5f8270c` + `d79c494` |
| #19 | Bootstrap default `--Force` for lib scripts | `Copy-WithPrompt` defaults `-Force` for repo-owned scripts (kills a background-hang foot-gun) | `81cbb42` |
| #20 | Plan 9 — cross-machine fleet sync over Tailscale | `ollama-box2` HTTP handler + per-host config + origin-host journal tag; **+ fleet.yaml parser bug fix** | `5e0a92d` + `3396a02` |
| #21 | Plan 10 — ensemble cockpit view | per-provider partial-content + synthesis previews on the live cockpit | `c41889e` |
| #22 | Run `/consolidate-decisions` | consolidated d001–d013 into per-project guidance | (skill run) |
| #23 | Plan 11 — job-aware retrieval boost in `/kb-search` | project-weighted hit scoring (tunable, conservative default) | `0c9d410` |
| #24 | Embedding A/B test | `kb/ab_eval.py` harness; decision: keep `nomic-embed-text` (d011) | `3547c8d` |
| #25 | Auto-decision-capture via Stop hook + heuristic | `decision-detect.ps1` multi-pattern heuristic + docs | `d9f1988` |
| #26 | Streaming ensemble UI | partials surfaced as each provider finishes (see reasoning below) | `c41889e` |
| — | Auto-close + timestamp fixes (this session) | gated merges now emit `Closes #N`; consolidation timestamp fixed | `17abade` |

---

## Reasoning & key decisions

### #20 — Plan 9: what "real" meant, and a latent bug it exposed
The disabled `ollama-box2` was a `kind: cli` provider running `ollama run` against
a remote host — which hangs. Making it real meant routing through the native
Ollama `/api/generate` HTTP endpoint (the generic `kind: http` dispatcher already
auto-routes `ollama-box2` → `scripts/fleet/ollama-box2.ps1` → `Invoke-OllamaBox2`,
so no dispatch change was needed).

Two design calls:
- **Origin-host journaling (decision d012):** every fleet journal line now carries
  a trailing `host:<name>` tag = the *dispatching* machine (not the serving box,
  which is already identified by the provider name). This makes a journal merged
  across the tailnet attributable per node — the actual point of "cross-machine
  sync." Trailing placement keeps positional parsers (dashboard, `parse-otel`)
  unaffected. Override via `CAO_FLEET_HOST`.
- **Verification caught a real bug:** the live dispatch first failed with
  "Invalid URI." Root cause: `ConvertFrom-FleetValue` only stripped quotes when a
  value *both* started and ended with one, so `base_url: 'http://..'  # comment`
  was read literally (quotes + inline comment included). This had silently blocked
  the fleet path all along — connectivity had only ever been confirmed via direct
  API, never `Invoke-Fleet`. Fixed to parse quoted values up to the matching close
  quote and strip whitespace-preceded `#` on unquoted values. Re-verified live:
  `ollama-box2` → wraith2 returned exit 0 (9s) with a `host:`-tagged journal line.

### #21 + #26 — why #26 needed no runner change (decision d013)
The cockpit (reader + `/partials/fleet` + 2s-polled `fleet_activity.html`) already
showed per-provider state/duration live. The gaps versus the issue text were
partial *content* and a *synthesis* preview — both pure read-side additions over
files the run already produces (`<label>.md`, `synthesis.md`).

Crucially, #26's premise (migrate `Wait-Job` → `Receive-Job -Keep` to write
partials) was already obsolete: the `EnsembleWorker` child writes its own
`<label>.md` and flips `<label>.live.json` to done/error **the instant it
finishes**, independently of its siblings. `Wait-Job` only blocks the *parent's*
final manifest — not the per-provider files. So "partials as they arrive" was
already true at the file level (the Plan 10 cockpit refactor achieved it); the
spec's migration would have been churn. #26 fell out of #21 for free once the
reader surfaced the content. Fleet providers are one-shot (CLI / `stream:false`
HTTP), so token-level intra-provider streaming was explicitly out of scope.

### Tracker reconciliation + the auto-close fix
Six issues (#17, #18, #19, #23, #24, #25) were shipped-but-open. Root cause: the
gated-merge automation's commit messages (`merge auto/issue-N … (gate passed)`)
never referenced the issue, so GitHub never auto-closed them — whereas
hand-written commits with `Closes #N` (#16, #20) did. Fixed at the source:
`Merge-ItemToIntegration` now appends `Closes #N` to the merge commit body when the
branch name encodes an issue number, so future gated merges auto-close on reaching
master. Covered by a `test-fleet-orchestrate.ps1` case.

### Decision records added this batch
`d007`–`d010` (backlog-as-bench, worktree+hard-gate dispatch, agentic-CLI-only
implementers, per-item-branch-to-main with Gemini review), `d011` (keep
nomic-embed-text), `d012` (origin-host journaling), `d013` (cockpit partials).
All consolidated into `decision-guidance.md` under "Open / under-feedback" — they
graduate to "Established patterns" once outcomes are attached via
`/decision-feedback`.

---

## Verification at release

- **Python** (`kb` + `dashboard`): 116 passed.
- **PowerShell** fleet suites: `test-fleet-lib`, `test-fleet-dispatch`,
  `test-fleet-orchestrate` (incl. the new `Closes #N` case), `test-fleet-ensemble` — all pass.
- **Live**: `ollama-box2` over Tailscale returns exit 0 with a host-tagged journal;
  `/partials/fleet` renders partial content + synthesis end-to-end through the real
  FastAPI+Jinja stack and against real `~/.claude/ensembles` data.
- Working tree clean, on `master`, in sync with `origin/master`.

## Housekeeping done

- Trimmed all merged feature branches (local + remote) and dead worktrees; repo is
  down to `master` + `integration/backlog`, single working tree.
- Two hooks deployed to `~/.claude` and wired in `settings.json`: `kb-autoindex`
  (live) and the project context7 permission allowlist. (`decision-detect` is
  implemented and deployed but **not** yet registered as a `Stop` hook — wiring it
  is the one remaining opt-in.)

## Still open (intentionally)

- **Cross-project consolidation sweep** (promote patterns seen in ≥2 projects to
  universal guidance) — blocked until a second project exists; no issue tracked.
- **Wire `decision-detect` as a `Stop` hook** to make auto-decision-capture live.
