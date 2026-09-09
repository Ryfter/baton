# Baton Restructure Audit

**Verdict up front:** The owner's instinct is correct, but understated. Baton doesn't need to be "split up" — it needs to be **cut by ~70%**. Of 36,120 lines of pwsh control plane, only ~12,000 lines are genuine orchestrator logic. Another ~9,400 lines are re-implementations of tools that already exist (Kun's stack). The rest is scaffolding for features that never paid off. The pwsh runtime is the wrong substrate on a Mac (SIGABRT/.NET corruption is a platform bug, not a Baton bug), and every dispatch, hook, and MCP tool call rides it. This is not a refactor; it's a rebuild around a small core plus three adoptions.

---

## 1. Bucketing the pwsh control plane

Method: every code file >200 LOC gets one bucket; smaller files are assigned via their functional cluster. Tests follow their code.

### CORE — genuine orchestrator logic (port, own, keep)

| File | LOC | Why it's CORE |
|---|---:|---|
| `scripts/conductor-lib.ps1` | 1,864 | The golden-path loop itself (#97). The heart. |
| `scripts/maestro-lib.ps1` | 1,285 | Admission, reconcile, handoff — d108/d111 seating says this is deterministic code. |
| `scripts/fleet-lib.ps1` | 1,001 | Roster, provider state, dispatchability. |
| `scripts/window-budget-lib.ps1` | 874 | **Governor spend logic** — explicitly CORE. |
| `scripts/window-service-lib.ps1` | 644 | Governor metering service half. |
| `scripts/fleet-backlog.ps1` | 782 | Job queue / state. |
| `scripts/fleet-models.ps1` | 495 | Roster/capability config surface. |
| `scripts/choices-lib.ps1` | 491 | Conductor choices queue (d086 spine). |
| `scripts/routing-lib.ps1` | 434 | Routing policy — the "cheapest capable model" rule lives here. |
| `scripts/memory-ingest-lib.ps1` | 427 | Grimlore glue. |
| `scripts/memory-lib.ps1` | 435 | Grimlore/Grimdex glue. |
| `scripts/fleet-go.ps1` | 385 | The `/baton:go` entrypoint logic (#190). |
| `scripts/decisions-lib.ps1` | 375 | `baton-dNNN` decision records. |
| `scripts/effective-cost-lib.ps1` | 319 | Cost-aware routing rank. |
| `scripts/project-create-lib.ps1` | 304 | Project state. |
| `scripts/plan-gate-lib.ps1` | 289 | Plan gate (d086 spine). |
| `scripts/routing-dispatch.ps1` | 284 | Dispatch policy (not the transport — see ADOPT). |
| `scripts/projects-lib.ps1` | 248 | Project state. |
| `scripts/job-lib.ps1` | 238 | Job model. |
| `scripts/maestro.ps1` | 246 | Maestro CLI surface. |
| `scripts/maestro-session-lib.ps1` | 215 | Session state. |
| `scripts/baton.ps1` | 375 | Current CLI entry — becomes the spec for `baton` verbs. |
| Cluster: small glue (`baton-home`, `baton-resolve`, `baton-session`, `runs-lib`, `registry-lib`, `kb-lib`, `session-markers-lib`, `fleet-window-*`, `fleet-project(s)`, `maestro-*` small cmds, `cost-lib`, `cost-resolver-lib`, `saturation-lib`, `triage-lib`, `instruments-lib`, `worker-lib`, `fleet-doctor`, `fleet-runs-bridge`, `http-auth-lib`) | ~2,600 | State paths, run records, doctor. |

**CORE total: ~12,000 LOC** (of which ~2,600 is small glue). Realistic port target: **4,000–5,000 lines** of typed Python — pwsh inflates everything ~2.5×.

### ADOPT — replace with Kun's tools

| File | LOC | Replaced by |
|---|---:|---|
| `scripts/fleet-executor-lib.ps1` | 2,512 | **firstmate** — crew dispatch, isolated worktrees, watchers, PR return. This is the single biggest adoption win; the executor is where pwsh dispatch breaks (#196, #152, #183). |
| `scripts/usage-probe-lib.ps1` | 1,261 | **quota-axi** — one call, all providers. Kills #173/#185 outright. |
| `scripts/diff-apply-lib.ps1` | 929 | **firstmate** — workers edit inside their own worktrees; Baton stops hand-applying diffs. |
| `scripts/coordination-lib.ps1` | 915 | **firstmate** — liaison/crew layer. |
| `scripts/verification-lib.ps1` | 724 | **no-mistakes** — validation gate, disposable worktree run, branch forwarded only after checks pass. This *is* #96/#95/#117. |
| `scripts/gate-lib.ps1` | 598 | **no-mistakes**. |
| `scripts/dark-factory-lib.ps1` | 522 | **treehouse** — worktree pool, deps/build cache intact, conflict detection (#203). |
| `scripts/heartbeat-lib.ps1` | 477 | **firstmate** — event-driven zero-token watchers. |
| `scripts/cursor-quota-lib.ps1` | 384 | **quota-axi**. |
| `scripts/usage-classify-lib.ps1` | 367 | **quota-axi**. |
| `scripts/code-lib.ps1` | 238 | **firstmate** (labor phase). |
| `scripts/copilot-credit-lib.ps1` | 201 | **quota-axi**. |
| `scripts/usage-lib.ps1` | 281 | **quota-axi**. |

**ADOPT total: ~9,400 LOC deleted by adoption, not porting.**

### DROP — dead, redundant, or never paid off

| File | LOC | Reason |
|---|---:|---|
| `scripts/officers-lib.ps1` | 1,574 | Captain/first-mater hierarchy roleplay. firstmate's liaison model replaces it; 1,574 lines of persona management is the "WAY out of hand" the owner senses. |
| `scripts/ship-report-lib.ps1` | 1,088 | Report theater. A `baton status --json` + 50 lines of formatting. |
| `scripts/start-lib.ps1` | 553 | "Front porch" coach. Not the goal. |
| `scripts/optimize-prompt-lib.ps1` | 501 | Prompt A/B optimizer — overfit to harness lore; Kun's exact warning. |
| `scripts/bootstrap.ps1` | 613 | Installs the pwsh world being deleted. |
| `scripts/coach-lib.ps1` | 283 | Coaching scaffold. |
| `scripts/prompt-pool-lib.ps1` | 376 | Prompt pool — no evidence of payoff. |
| `scripts/research-gate-lib.ps1` | 273 | Research gate — scope creep off the golden path. |
| `scripts/fleet-ensemble.ps1` | 232 | Ensemble mode — never the goal. |
| `scripts/routing-learn.ps1` (321) + `routing-observe-lib.ps1` (512) + `routing-calibrate.ps1` (102) + `fleet-routing-observe.ps1` (114) | 1,049 | The routing "learning loop" (S3/S4). Classic clever-scaffolding rot; keep static policy + effective-cost, drop the self-tuning. |
| `scripts/parse-otel.ps1` (246) + `otel-env.ps1` (29) + `prime-hours.ps1` (151) + `efficiency-lib.ps1` (151) + `model-quality-lib.ps1` (41) + `six-hats-lib.ps1` (63) + `council-lib.ps1` (132) + `holdout-lib.ps1` (127) + `security-researcher-lib.ps1` (167) + `idea-lib.ps1` (192) + `consolidate-*.ps1` (282) + `seed-overnight-choices.ps1` (93) + `smoke-*.ps1` (155) + `fleet-ensemble/ask/choices/optimize-prompt/orchestrate/ship-report/...` small cmds | ~2,100 | Assorted experiments, ceremony commands, and one-off smokes. |
| All `test-*.ps1` for dropped/adopted code | ~15,000 | Follows their code. Port only CORE tests (~6,000 LOC → ~2,500 in pytest). |
| `scripts/mcp-bridge.ps1` (113) + `uninstall-octopus.ps1` (41) + fixtures | ~250 | Bridge dies with the MCP dispatch surface; octopus is already dead. |

**DROP total: ~14,700 LOC** (code) + ~15,000 LOC tests.

### Totals

| Bucket | pwsh LOC | % |
|---|---:|---:|
| **CORE** (port) | ~12,000 | 33% |
| **ADOPT** (delete via firstmate/gnhf/treehouse/quota-axi/no-mistakes) | ~9,400 | 26% |
| **DROP** (delete outright) | ~14,700 | 41% |
| Total | 36,120 | 100% |

Plus 23,686 LOC of pwsh tests → keep/port ~6,000, drop the rest. **End state: a ~5k-LOC Python core + 5 adopted external CLIs.** That is the "full-on developed CLI harness" the owner described — and it's smaller than what exists today by an order of magnitude in maintenance surface.

---

## 2. The minimal Baton-core CLI

### Command surface

```
baton go <goal|spec-file> [--execute]     # THE golden path (#190/#97). Everything else serves this.
baton status [run-id]                     # run state, per-agent status, spend, Needs-You boundary (#202)
baton fleet list|probe                    # roster + dispatchability + quota (quota-axi backed)
baton route <task>                        # dry-run routing decision: which model, why, est. cost
baton jobs list|show|retry <id>           # backlog inspection
baton decide <text>                       # record a baton-dNNN decision
baton kb search <q>                       # Grimdex/Grimlore semantic search (existing kb/ package)
baton doctor                              # env, providers, pwsh-free health check
```

Six verbs of substance, two utilities. Everything else in `commands/` (56 files) is either a DROP'd experiment or a thin alias.

### On-disk state

```
~/.baton/
  config.toml          # replaces fleet.yaml + BATON_HOME sprawl: roster, cost tiers, governor caps, policy seam (#200)
  runs/<run-id>/       # append-only event log (adopt #206 as the design, day one)
    events.jsonl       #   the log IS the source of truth; status is a projection
    plan.json
    state/             # materialized projection, rebuildable
  decisions/           # baton-dNNN markdown
  kb/                  # grimdex index (existing kb/ package points here)
```

Per-project worktrees are **not** Baton state — they belong to treehouse/firstmate. Worker identity (#204) = named mailbox dirs under `runs/<id>/workers/<name>/`.

### Golden path, step by step (`baton go`)

1. **Admit** (Maestro, deterministic): parse goal, resolve project, create run dir, write `plan.json` request. Fail loud here or nowhere.
2. **Plan**: dispatch plan task to Fable (per d111 seating); plan-gate check (CORE `plan-gate-lib` port, ~150 lines).
3. **Route** (CORE): for each plan task, pick cheapest capable model via `routing-lib` + `effective-cost` against `config.toml`; check quota-axi *before* dispatch (#156/#185 die here); apply policy seam ALLOW/DENY/ASK (#200).
4. **Dispatch** (firstmate): liaison agent runs the crew; each worker in a treehouse worktree with injected port (#203) and pinned cwd (#152); timeouts enforced by firstmate's watchers, not pwsh `TimeoutS` (#196).
5. **Verify** (no-mistakes): disposable worktree run — tests, lint, test-tamper check (#117); branch forwarded only on pass; one bounded CI retry (#205).
6. **Review**: Opus reviews the diff (d111); sprint-review to Fable.
7. **Ship/hold**: merge or surface `Needs You` (#202) with the failure injected — never label a quota exhaustion as `no-change` (#156).

### Language

**Python 3.12+, packaged with `uv`, single `baton` console script.** Two sentences: the repo already contains ~7,000 lines of working, tested Python (kb/, dashboard/, hooks/) and the MCP server — Python is the only language where Baton has proven competence, and it shares the runtime with the adopted tools' integration seams. Go would be faster but you'd be rewriting the kb package and learning a second stack while the actual product never ships.

### MCP server

**The dispatch-facing MCP server dies.** `baton_mcp/` (324 LOC + 846 test LOC) exists only to shell every tool back into pwsh via `mcp-bridge.ps1` — it's a pwsh proxy wearing an MCP costume, and it's the masked-launch-path bug source. Keep exactly one thing: `baton kb search` can remain exposed as a single MCP tool (or just be called via `uv run baton kb search` from Claude Code Bash — simpler, kill the server entirely). Kun's AXI thesis is right: agents want a CLI, not an MCP shim.

### Claude Code plugin

**Stays, reduced to a shell.** Keep:
- `commands/go.md` — one slash command that runs `baton go "$ARGUMENTS" --execute` and nothing else. Optionally `commands/fleet.md` → `baton status`.
- The 7 pure-Python hooks (`pwsh-guard` becomes unnecessary and dies; `publish-guard`, `rm-rf-guard`, `decision-detect`, `test-gate`, `kb-autoindex`, `baton-health-canary` stay — they're already Python and don't touch the control plane).

Delete: the other 54 command files, all 6 pwsh hooks (`baton-init`, `baton-coach`, `baton-session-start/stop`, `log-tool-call`, `run-feed` — session-marker refresh dot-sourcing a lib per tool call is issue #149; deleting it *is* the fix).

---

## 3. The 32 open issues

| # | Disposition |
|---|---|
| 211 | **CORE** — concurrent-session git guard; becomes a lock file in `runs/` + treehouse worktree isolation; mostly trivial in core. |
| 210 | **CORE** — merge-detection in `baton status`; small. |
| 209 | **CORE** — trivial docs task; do this week. |
| 208 | **DROP** — verb-naming ceremony; the CLI surface above settles it. |
| 207 | **CORE** — failed-approach warning = lookup in run event log; trivial once #206 log exists. |
| 206 | **CORE** — append-only event log; adopt as the *foundation* of the new state layout, not a feature. |
| 205 | **FIXED-BY-ADOPTION** — no-mistakes (bounded retry with injected failure). |
| 204 | **FIXED-BY-ADOPTION** — firstmate named workers; mailbox dirs in core state. |
| 203 | **FIXED-BY-ADOPTION** — treehouse (per-task worktree + env injection). |
| 202 | **CORE** — Needs-You boundary observed from process state; small module in core. |
| 201 | **CORE** — failover policy with hysteresis; this is routing-dispatch logic, must be owned. |
| 200 | **CORE** — policy seam in `config.toml` in front of routing. |
| 197 | **DROP** — grok ACP blocker; with firstmate, grok is one worker among many — if it can't go headless, route around it; stop blocking the spine on one provider. |
| 196 | **FIXED-BY-ADOPTION** — firstmate watchers replace pwsh `TimeoutS` enforcement entirely. |
| 190 | **CORE** — this *is* the restructure; closed by the golden path above. |
| 188 | **CORE** (trivial) — remove/renames `gh-copilot` in `config.toml`. |
| 185 | **FIXED-BY-ADOPTION** — quota-axi; `Read-Fleet` is deleted, not fixed. |
| 183 | **CORE** (trivial) — capability truthing in roster config; `agentic:false` for grok-cli until proven. |
| 182 | **DROP** — test dies with heartbeat-lib. |
| 178 | **CORE** (trivial) — doctor check in `baton doctor`. |
| 177 | **CORE** — honor `model_pick` in routing; one line in the new router. |
| 173 | **FIXED-BY-ADOPTION** — quota-axi generalizes the probe seam by existing. |
| 156 | **CORE** — quota-exhaustion labeling; fixed structurally by pre-dispatch quota-axi check + fail-loud run state. |
| 152 | **FIXED-BY-ADOPTION** — firstmate/treehouse pin cwd per worktree. |
| 150 | **CORE** — scope-brief enforcement is a worker-prompt + no-mistakes diff-scope check. |
| 149 | **DROP** — hook deleted. |
| 123 | **CORE** — plan-gate headroom check against roster dispatchability; trivial in new router. |
| 117 | **FIXED-BY-ADOPTION** — no-mistakes test-tamper check. |
| 115 | **CORE** — gates as first-class plan tasks; part of plan schema in core. |
| 97 | **CORE** — the spine; the whole plan. |
| 96 | **FIXED-BY-ADOPTION** — no-mistakes verification telemetry; graduation flag in core config. |
| 95 | **FIXED-BY-ADOPTION** — firstmate parallel worktree labor. |
| 91 | **CORE** — closeout artifact + prevention answer; a `baton go` epilogue step, ~100 lines. |

**Score: 12 CORE (5 trivial), 11 FIXED-BY-ADOPTION, 6 DROP, 3 CORE-trivial-config.** Notably: **zero issues require fixing the pwsh executor as-is.** Every dispatch-class bug (#196, #152, #183, #197, #203) is cheaper to delete than to patch.

### Do first regardless of restructure

1. **#196** — a timeout that doesn't fire means the system can hang forever, silently, tonight. Even a `timeout 600 pwsh …` wrapper stops the bleeding.
2. **#183** — a worker marked agentic that can't edit files makes `--execute` a silent no-op; this poisons trust in every run until fixed. One roster flag.
3. **#152** — cwd inheritance breaks every dispatch outside a trusted dir; a two-line cwd pin unblocks all real use.
4. **#156 + #185** — quota exhaustion mislabeled as no-change is a *correctness* lie in the run record; fix the label and the `usage_policy` schema crash together.
5. **#211** — concurrent-session git corruption can destroy the owner's actual work; a lockfile guard is an afternoon.

---

## Biggest risk

**The port itself.** 12,000 LOC of CORE pwsh contains routing policy, governor logic, and conductor behavior that has *never run correctly end-to-end* — meaning there is no golden master to port against. You could spend three months faithfully porting logic that was always broken, and end up with a beautiful Python system that also doesn't ship code.

**De-risk: strangler pattern with a hard spike-first rule.**
1. Week 1: build *only* `baton go` steps 1→7 as a dumb linear script (no maestro, no officers, no learning loop) using firstmate + quota-axi + no-mistakes, hardcoded to 2 providers (openrouter-glm + one Opus path). Prove it ships one real PR.
2. Only then port CORE libs *into* the working spine, one per week, behind the event log (#206) so every behavior change is observable.
3. Freeze `scripts/` immediately (no new pwsh features, bug-fix-only), delete on adoption. No parallel-run period — the pwsh plane has never been correct enough to be a reference oracle.

## On the premise

The "split it up" framing is half right. What's wrong is the implied geometry: the problem isn't that plugin/MCP/pwsh are tangled *together* — it's that Baton is four mechanisms doing one job, and two-thirds of the pwsh body is either someone else's tool or ceremony. Don't split Baton into multiple apps; **collapse it into one app and adopt five.** The owner's other instinct — "it should be a full-on CLI harness of its own" — is exactly right, and the numbers back it: ~5k LOC of owned Python core, firstmate for the crew, treehouse for worktrees, quota-axi for the meter, no-mistakes for the gate, gnhf as the overnight-loop reference (adopt its loop semantics into `baton go --overnight` rather than depending on it). The well-defined goal survives intact; what dies is everything that was never the goal.