# Milestone Panel — Deep Periodic Review + Producer-Class Agents

**Date:** 2026-08-02  
**Status:** SPEC — design only; not approved for build  
**Extends:** `scripts/gate-lib.ps1` / named review panel (`2026-07-13-review-named-panel-design.md`, shipped), acceptance gate (d058), verified labor path scope (`allowed_paths`), fleet labor executor  
**Does not rebuild:** the competitive review mechanism, `review-roles.yaml` contract, or the per-artifact `/baton:gate`

---

## 1. Problem

The operator already has a **named review panel** and an **advisory acceptance gate**. Two of five asks are covered by existing roles (`security`, `correctness`). What is missing is a **deeper, rarer tier** that:

1. Adds the missing **cross-platform** review lens.
2. Introduces a second class of agents — **producers** — that emit documentation and marketing prose as *files*, not findings.
3. Treats **single-pass review as a sample, not a filter** (observed: same brief / same four reviewers → accept with zero findings on one run, reject with a *critical* on the next).
4. Does all of that under a **~5× tighter budget** on the incumbent paid vendor, without dumping unreviewed generated prose into `README.md`.

The per-artifact gate must stay cheap and frequent. The milestone panel is the expensive, deliberate check.

---

## 2. Ground truth (do not re-propose)

| Piece | Status | Contract |
|---|---|---|
| `$BATON_HOME/review-roles.yaml` | ships | `name` + `lens` + `tier` (`strong`\|`cheap`) + `enabled`. **No model/provider IDs.** |
| Six roles | ship | `correctness`, `security` (adversarial), `architecture`, `spec-compliance`, `simplicity`, `framework-style` |
| `Invoke-AcceptanceGate` / `/baton:gate` | ships | ≥2 independent reviewers, dedupe, severity-weighted `accept`\|`polish`\|`reject`, polish brief. **Advisory; never blocks.** Roles route via `Select-Capability`. |
| Labor `allowed_paths` | ships | Plan tasks can confine writes; scope violations fail closed under verified labor. |
| Humanizer skill | external | Prompt-shaping only. **Not a gate.** |

Asks already covered: (1) security, (2) real bugs. Asks missing: (3) portability, (4) technical documentor, (5) storyteller / marketing voice with humanizer + reject-capable voice gate.

---

## 3. Core distinction

```
REVIEWERS  → consume an artifact → emit findings → feed a verdict
PRODUCERS  → consume grounded inputs → emit a scoped diff (files) → that diff is then reviewed
```

Producers **must not** be entries in `review-roles.yaml`. A role's output is advisory findings and must never write the repository. Putting a documentor or storyteller in that file would either (a) violate the role contract or (b) smuggle write authority into an advisory path — both failures.

---

## 4. Decisions

### d-mp-1 — Milestone is an explicit tier, not a gate flag on every run

A **milestone** is a deliberate deep review, triggered only when one of the following holds:

| Trigger | How it fires | Notes |
|---|---|---|
| **Operator invoke** | `/baton:milestone` (or `fleet-milestone.ps1 run`) | Primary path. Always available. |
| **Release cut** | version tag / release branch intent passed as `--reason release` | Operator or release script. |
| **Task-group closeout** | conductor / closeout hook offers a milestone run after a plan/sprint ships | **Offer, never auto-start** (mirrors compact discipline). |
| **High-stakes release candidate** | optional: `/baton:go --execute` with `stakes=high` *and* explicit `--milestone` | Still opt-in; not implied by high stakes alone. |

**Not triggers:** ordinary `/baton:gate`, ordinary go acceptance, polish passes, every PR, every commit.

**Difference from the per-artifact gate:**

| | Per-artifact gate | Milestone panel |
|---|---|---|
| Cadence | every finished artifact on the ship path | rare; explicit |
| Roster | enabled roles in `review-roles.yaml` (today's six) | milestone pack: existing six **+** `portability` **+** `voice` (when prose is in scope) |
| Passes | 1 | **≥2** (default 2) with model diversity when the pool allows |
| Aggregation | single merge | cross-pass stable/volatile (see §8) |
| Producers | none | documentor + storyteller (opt-in flags; default **on** for release reason) |
| Cost posture | cheapest capable per role tier | local/high-capacity preferred; incumbent paid reserved (see §9) |
| Output | verdict + polish brief | milestone report + optional producer branch(es) |

### d-mp-2 — Panel stays advisory; fail-loud when degraded

**Default: advisory.** A milestone `reject` does not block merge, CI, or `/baton:go` completion. Rationale:

- Matches the acceptance-gate thesis (d-ag-1): quality signal, human decision.
- Milestone depth is the most expensive operation; auto-blocking would force either (a) skipping milestones under budget pressure or (b) rubber-stamping when the panel is noisy.
- Producer **write** authority is already gated by path scope + human merge of the branch — the dangerous failure mode is unreviewed prose landing on `master`, not an advisory reject being ignored.

**Fail-loud (not fail-block):** if the milestone pack cannot staff its strong roles, all passes unparse, or producers write outside scope, the report opens with `MILESTONE DEGRADED` and the CLI exits **non-zero only when** `--strict` is set (for release scripts that want a hard stop). Without `--strict`, exit 0 with a loud degraded banner (same spirit as golden-path fail-loud surfacing, without inventing a new merge veto).

**Case for later blocking (not v1):** if post-ship defect data shows that ignored milestone `reject`s correlate with real production failures at a rate the operator cares about, flip via a named decision — same pattern as Plan Gate opt-in → default-on. Do not assume blocking.

### d-mp-3 — Two new reviewer roles; same yaml contract

Seed additions to `review-roles.yaml` (still no model IDs):

```yaml
  - name: portability
    lens: >-
      Cross-platform defects only: what breaks on Windows vs macOS vs Linux
      (and other OSes if the artifact claims them). Paths and separators,
      shell/CLI assumptions, line endings, case-sensitive filesystems,
      executable bit / shebang vs .ps1/.cmd, Python launcher names,
      native modules, env-var conventions, CI-only assumptions. Flag
      "works on this box" traps. Do not re-litigate pure logic bugs.
    tier: strong
    enabled: true

  - name: voice
    lens: >-
      Prose only. Does this read as though a human engineer wrote it?
      REJECT (critical/important) for AI-speak, vagueness, inflated claims,
      unsupported superlatives, empty enthusiasm, stock transitions, and
      marketing that invents capabilities. Prefer concrete, slightly
      uneven human voice over polished brochure copy. Not a style-nit
      role for code.
    tier: cheap
    enabled: true
```

- **`portability`:** always in the milestone pack for code/diff artifacts. Optional on ordinary gates (operator may enable; not required for v1 default gate path).
- **`voice`:** runs on **prose artifacts only** (README, docs producer diffs). On pure code diffs the panel **skips** `voice` (recorded as `skipped:not-applicable`, not degraded).

Existing six roles keep their lenses. Milestone does not replace them; it deepens the pass structure around them.

### d-mp-4 — Producer class is separate config + scoped labor

New box-private (seeded) file: `$BATON_HOME/producer-roles.yaml` (or `references/producer-roles.yaml` seed deployed like review roles).

```yaml
# Producers emit files. They are never reviewers.
producers:
  - name: documentor
    purpose: "Full technical documentation of what the tool can do; update docs to match reality."
    tier: strong
    allowed_path_prefixes:
      - "docs/"
    # README technical sections may be touched only when --allow-readme-tech is set;
    # default documentor stays under docs/ to avoid fighting the storyteller.
    enabled: true

  - name: storyteller
    purpose: "README positioning: why someone should use this. Persuasive, accurate, not AI-speak."
    tier: strong
    allowed_path_prefixes:
      - "README.md"
    humanizer: true   # inject humanizer skill guidance into the labor prompt
    enabled: true
```

**Where output goes:**

1. Producer runs as a **labor task** (fleet executor / go-style agentic worker) on a dedicated branch: `baton/milestone-<run-id>/<producer-name>`.
2. `allowed_paths` / path prefixes are **hard-enforced** (existing verified-labor scope). Writes outside → task fail-closed; no partial apply to the milestone result.
3. Producer **never** merges to the default branch. Diff is left for the human (or a later explicit merge command).
4. After the producer finishes, the **milestone panel reviews the producer diff** as an artifact — same competitive machinery as any other change, with `voice` always included for storyteller (and for documentor when prose-heavy).

**Gating chain (the failure the operator named):**

```
producer labor (scoped paths)
    → proof-by-diff (non-empty, in-scope)
    → multi-pass panel on that diff
         (voice + accuracy/claim-check + relevant code roles if needed)
    → accept | polish | reject  (advisory on the *docs branch*)
    → human merges only if they accept the report
```

Unreviewed generated prose cannot land on `master` through this system: the system never auto-merges producer branches.

### d-mp-5 — Documentor vs code disagreement: **docs follow code**

**Chosen:** when documentation and code disagree, the documentor **updates the documentation to match the code**, and emits a **discrepancy note** (not a silent rewrite of history).

| Situation | Documentor action |
|---|---|
| Code has behavior docs omit | Document it. |
| Docs claim behavior code lacks | Remove or rewrite the claim to match code. |
| Docs describe intended design that code fails | **Still docs-follow-code for the prose change.** Additionally emit a `discrepancy` finding (severity `important` or `critical` if safety-related) into the milestone report's **product-gap** section for humans / correctness follow-up. **Does not edit product code.** |

**Why this way:**

- A documentor's job is "explain what the tool can do" — that is an honesty obligation about *actual* behavior, not a second implementer.
- Letting the documentor "fix" code collapses producer into implementer, explodes `allowed_paths`, and bypasses the code panel.
- Reporting product gaps as findings keeps the adversarial security/correctness panel (and the human) in charge of code changes.
- The alternative (treat every doc/code mismatch as a code defect) produces false positives whenever docs are aspirational or stale marketing — common in this repo's history.

**Assumption:** the operator prefers honest docs over aspirational docs. Flag if wrong.

### d-mp-6 — Storyteller stays accurate via grounded inventory + claim check

The storyteller **must not invent capabilities.** Grounding pipeline:

1. **Capability inventory (deterministic prelude, no LLM):** collect a short inventory file from reality:
   - command list (`commands/*.md` names + first-line descriptions),
   - README current feature bullets (as *candidates*, not truths),
   - `docs/roadmap.md` / release notes "shipped" claims if present,
   - optional: help text from `fleet-*.ps1` synopsis comments.
   Written to the run dir as `capability-inventory.md`.
2. **Producer prompt** includes the inventory and a hard rule: *Every concrete claim must be supportable from the inventory or from cited paths in the repo. If unsure, omit.*
3. **Humanizer guidance** is injected into the prompt (skill text / condensed checklist) — shapes tone only.
4. **Post-diff claim check (panel, not skill):**
   - `voice` rejects AI-speak / hype.
   - A **claim-check** pass (implemented as a dedicated review prompt under role name `spec-compliance` *or* a milestone-only lens overlay — see §7) requires each marketing claim to map to inventory items; unsupported claims → `critical` or `important`.
5. Storyteller **may** restructure and rephrase; it **may not** add features, performance numbers, or platform support not in inventory.

If inventory is empty/malformed → storyteller **does not run** (degraded note), rather than free-writing.

### d-mp-7 — Multi-pass is mandatory at milestone; single-pass remains the ordinary gate

Default **`passes: 2`**. Configurable `1..3` in milestone config; v1 ships 2.

### d-mp-8 — A `scope-fidelity` role, because prose prohibitions are not enforceable

Added from run `go-2026-08-02T13-07-24`, where a worker asked to add two read-only helper
functions to `app/queries.py` instead bumped `SCHEMA_VERSION 9→10`, changed the `topics` table
primary key from `id` to a compound `(id, interest)`, and wrote a migration function.

Two things that run proved, both of which this design must absorb:

1. **Path scoping did not catch it.** `app/db.py` sits inside the allowed `app/` path. The
   violation was caught by the diff *growing*, not by the path rule — the weaker, more
   incidental guard. Allowed-path lists bound *where* a worker may write, never *how much* or
   *how destructively*.
2. **The prohibition was prose and was ignored.** The brief said "no schema change, no
   migration" in plain text. The worker read it and did it anyway.

**Principle for this spec and for Baton generally: a prohibition expressed only in a prompt is a
suggestion. Only an oracle is a rule.** Anything genuinely forbidden — schema edits, migrations,
dependency additions, touching a named file — needs a deterministic check that fails closed, not
a stronger sentence in the brief. This mirrors Grimdex law 7: a rule that keeps being violated
gets converted into something deterministic rather than more emphatic wording.

None of the existing six roles squarely covers this. `spec-compliance` hunts *under*-building,
`simplicity` hunts over-engineering as a design smell. Neither asks the blunt question:

```yaml
  - name: scope-fidelity
    lens: >-
      Did this change do MORE than the task asked? Flag unrequested schema
      changes, migrations, new dependencies, config/version bumps, deletions,
      and edits to files the task never mentioned — even when those files sit
      inside an allowed path. An allowed path bounds WHERE a worker may write,
      never HOW MUCH. Judge against the task text, not against taste. A
      technically-correct change nobody asked for is a finding.
    tier: strong
    enabled: true
```

Runs in the milestone pack for code/diff artifacts, and is a strong candidate for the ordinary
gate too — this failure mode has now appeared twice on the same cheap model tier (a repo-root
scratch file in one run, a schema migration in another), which also makes it a **routing**
signal: `code-gen` tasks carrying a scope contract should not route to a tier with a
demonstrated history of ignoring one. See #150.

---

## 5. Architecture

### 5.1 Surfaces

| Surface | Role |
|---|---|
| `scripts/milestone-lib.ps1` | Pure: pack resolution, pass plan, cross-pass aggregate, report format, producer task graph |
| `scripts/fleet-milestone.ps1` | CLI: `run`, `--strict`, `--no-producers`, `--producers doc,story`, `--passes N`, `--reason`, `--diff`/`--ref` |
| `commands/milestone.md` | `/baton:milestone` |
| seed `review-roles.yaml` | +`portability`, +`voice` |
| seed `producer-roles.yaml` | documentor, storyteller |
| run dir under `$BATON_HOME/runs/milestone-<id>/` | inventory, per-pass findings, aggregate, producer branches metadata, `milestone-report.md` |

No second dashboard. Report is CLI markdown + run-dir files (ship-report pattern).

### 5.2 Milestone pack

```
code/diff review pack:
  correctness, security, architecture, spec-compliance,
  simplicity, framework-style, portability
  (+ voice only if artifact is prose-classified)

prose/diff review pack (producer output):
  voice, spec-compliance (claim-check lens overlay), correctness
  (security only if docs touch auth/secrets guidance)
```

Ordinary `/baton:gate` **unchanged** unless the operator enables the new roles globally (they are just more rows in the same yaml). Milestone *orchestration* is what forces multi-pass + producers.

### 5.3 Phases of one milestone run

```
Phase 0  Resolve scope
         - git diff / ref range / working tree
         - reason (release | closeout | manual)
         - flags (producers on/off, passes, strict)

Phase 1  Deep review (multi-pass panel on the product diff)
         - for pass in 1..N:
             assign providers per role with diversity preference (§8)
             Invoke-AcceptanceGate panel path (reuse)
         - Aggregate-MilestoneFindings (§8)
         - emit code-verdict (stable findings only)

Phase 2  Producers (if enabled and reason/flags allow)
         - Build capability inventory
         - documentor labor → branch A
         - storyteller labor → branch B  (may depend on documentor finishing
           if storyteller is told to read updated docs; default: parallel
           with inventory only — v1 parallel to cut wall-clock)
         - scope verify each

Phase 3  Review producer diffs (multi-pass, prose pack)
         - per producer branch: aggregate verdict
         - voice reject ⇒ producer verdict reject/polish; branch kept, not merged

Phase 4  Report
         - milestone-report.md: code verdict, product-gap discrepancies,
           producer verdicts, stable vs volatile findings, cost rollup
         - print to stdout; leave branches for human
```

### 5.4 Reuse boundaries

- **Reuse:** `Get-ReviewRoles`, `Build-ReviewPrompt`, `Invoke-AcceptanceGate`, `Merge-ReviewFindings`, `Get-AcceptanceVerdict`, `Select-Capability`, labor spawn + `allowed_paths`, journal/token telemetry.
- **New:** pass scheduler, diversity assignment, cross-pass aggregation, producer role parse, inventory builder, milestone report, CLI.
- **Do not:** add model IDs to role yaml; teach producers to merge; make humanizer a gate; run producers on every acceptance gate.

---

## 6. Reviewer additions (detail)

### 6.1 `portability`

**Tier:** `strong` (judgment; false confidence on "it runs here" is expensive).

**In scope:** OS differences that make the same commit fail or misbehave elsewhere.

**Out of scope:** pure logic bugs (correctness), pure design taste (architecture/simplicity), pure naming (framework-style).

**Evidence style expected in findings:** name the OS pair and the concrete API/path/shell assumption (e.g. "`Join-Path` vs string concat with `/`; breaks when …").

### 6.2 `voice`

**Tier:** `cheap` by default — AI-pattern detection is pattern-heavy and does not need the most expensive model; local/high-capacity free tiers often suffice. (If live data shows voice is too lenient on cheap models, raise tier without schema change.)

**Severity guidance in lens application (prompt side):**

| Severity | Example |
|---|---|
| critical | Invented capability; false security/performance claim |
| important | AI-speak density, unsupported superlatives, brochure emptiness that would embarrass a human author |
| minor | Minor cadence nits that still read human |

**Voice rejects marketing prose; it does not rewrite it.** Rewrite is a polish-brief job for a follow-up labor task (out of v1 auto-loop; human or manual re-run storyteller with the brief).

---

## 7. Producer class (detail)

### 7.1 Documentor

**Inputs:** repo tree under `docs/`, public commands, existing specs/roadmap, the product diff under review (so it knows what changed this milestone).

**Outputs:** patches under `docs/**` only (v1). Prefer updating existing pages over inventing a parallel doc tree.

**Discrepancy channel:** `product-gaps.jsonl` in the run dir — one object per suspected code defect / missing implementation, with `severity`, `summary`, `doc_path`, `code_hint`. Folded into the milestone report; **not** auto-filed as GitHub issues in v1.

### 7.2 Storyteller

**Inputs:** `capability-inventory.md`, current `README.md`, optional product one-liner from `--pitch` / reason.

**Outputs:** `README.md` only (v1).

**Humanizer:** prompt injection from the humanizer skill's checklist (condensed). Not executed as a separate interactive skill session unless the worker already supports skill loading — v1 can inline a short "banned patterns" block derived from the skill to avoid harness coupling.

**Accuracy gate:** panel claim-check (d-mp-6). Voice + claim-check both required before the report marks producer output `acceptable`.

### 7.3 Why labor tasks, not "role with write bit"

- Labor already has worktree/branch, `allowed_paths`, proof-by-diff, and verified-labor fail-closed semantics.
- Review roles share a JSON findings schema that cannot express a file tree.
- Keeps the advisory gate pure: reviewers never touch the repo, even "to help."

---

## 8. Multi-pass and aggregation

### 8.1 Why multi-pass

A single panel run is **one draw** from a high-variance process (model sampling + role lens + provider quirks). Observed accept↔critical flip on the same brief proves that.

### 8.2 Pass plan

For each pass `p ∈ 1..N` (default N=2):

1. For each enabled role in the pack, select a provider via `Select-Capability` with the role's tier cap.
2. **Diversity preference (soft):** if pass `p>1` and another capable provider exists for that role's tier, **prefer a provider not used for that role in earlier passes**. If the pool has only one capable provider, reuse is allowed and recorded as `diversity: none`.
3. Run independent reviews (no cross-talk between roles or passes).
4. Store per-pass merge result under `passes/p{n}/`.

No third-party "chair" LLM to reconcile — pure aggregation (consistent with d-ag-2).

### 8.3 Cross-pass aggregation

Dedupe key: existing finding key (normalized `area` + `summary`), with light normalization (collapse whitespace, lowercase) already in gate-lib.

For each unique key:

| Field | Meaning |
|---|---|
| `support_passes` | how many passes raised it |
| `support_roles` | distinct roles across all passes |
| `max_severity` | highest severity seen |
| `raised_by` | list of `pass/role/provider` triples (providers as box-private names in run dir only) |

**Classification:**

- **stable** — `support_passes ≥ 2` **OR** (`support_passes = 1` **AND** `support_roles ≥ 2` within that pass — i.e. classic `agreed`)
- **volatile** — raised once by a single role in a single pass

**Verdict rule (milestone):**

- Compute `Get-AcceptanceVerdict` on **stable** findings only (same critical→reject, important→polish, else accept thresholds).
- **Volatile findings never alone drive `reject`.** They appear in a separate report section: "Volatile (single-sample) — treat as signal to re-check, not as automatic veto."
- **Exception (security bias):** a **volatile critical from `security`** is promoted to **stable-for-verdict** when its summary matches high-risk keywords in a fixed list (authz, injection, secret, path traversal, RCE). Rationale: security misses from variance are costlier than false polish; this is a narrow exception, listed in the report as `promoted:security-critical`.
- If passes disagree at the verdict level (e.g. pass1 accept vs pass2 reject) **and** stable set is non-empty → overall at least `polish`. If stable set is empty but volatile criticals exist (non-security) → `polish` with reason `pass-disagreement-volatile-only`.

**Deduping for the operator:** the report shows stable findings first (agreed-first within), then a short volatile appendix. No raw dump of N×R near-duplicate lines.

### 8.4 What multi-pass is not

- Not majority vote on free-form prose.
- Not "run until accept."
- Not automatic re-dispatch of producers on voice reject (v1 stops at polish brief).

---

## 9. Cost and routing defaults

### 9.1 Budget reality

Incumbent paid vendor budget is dropping ~**5×**. Milestone depth is the most expensive planned feature. Defaults must make a full run **survivable on local + non-incumbent high-capacity** providers, with incumbent spend **exceptional and named**.

### 9.2 Routing policy (config intent — still no model IDs in role files)

Role yaml keeps only `tier`. Box-private fleet / routing overlays implement:

| Role class | Default cost posture | Incumbent paid? |
|---|---|---|
| `simplicity`, `framework-style`, `voice` | `cheap` → local/free first | no |
| `correctness`, `architecture`, `spec-compliance`, `portability` | `strong` → **high-capacity non-incumbent / local-strong first** | only if nothing else capable |
| `security` | `strong` → prefer the provider with best **adversarial** track record on this box | **yes, reserved seat** when that is the incumbent |
| documentor / storyteller labor | `strong` agentic | prefer non-incumbent agentic; incumbent only if no other agentic worker |

**Where the expensive vendor clearly wins (reserve it):**

1. **`security`** — adversarial "try to break it" benefits most from the strongest careful reasoner available; a miss is high-cost.  
2. **Optional second seat: `architecture` on release milestones only** — large structural judgment; default off in v1 to save budget (`milestone.yaml`: `incumbent_roles: [security]`).

**Where it does *not* automatically win:** voice (pattern checklist), simplicity, framework-style, multi-pass diversity seats (use *other* models deliberately).

### 9.3 Rough cost shape per milestone run

Order-of-magnitude **relative** to one ordinary single-pass six-role gate (`1×`):

| Phase | Shape | Notes |
|---|---|---|
| Deep review, N=2, ~7 roles | ~**2.0–2.5×** one gate | second pass ≈ first; diversity may move spend across vendors |
| Security on incumbent | +**0.3–0.8×** | one role × 2 passes if both use incumbent; config can pin only pass-2 to incumbent |
| Documentor labor | ~**2–5×** | agentic, multi-file; dominant cost risk |
| Storyteller labor | ~**1–2×** | single file, but agentic overhead |
| Producer panel review | ~**0.5–1×** | smaller artifact, fewer roles, still × passes |
| **Total (review-only, no producers)** | ~**2–3×** one gate | |
| **Total (full, with both producers)** | ~**6–12×** one gate | dominated by agentic doc writes |

In absolute terms (illustrative placeholders only — box-private prices vary):

- Review-only milestone: roughly **low single-digit $** on paid APIs if mostly non-incumbent/local; **more** if security+architecture both sit on the expensive vendor both passes.
- Full milestone with both producers: **one to low tens of $** equivalent depending on agentic verbosity — treat as a **release-tax**, not a PR-tax.

**v1 cost controls:**

- `--no-producers` (review-only).
- `--producers documentor` or `storyteller` alone.
- `--passes 2` default; `--passes 1` escape (loud warning: variance unprotected).
- Per-run budget cap reused from go budget machinery when present; if cap would be exceeded before Phase 2, **skip producers** and report `producers_skipped:budget` rather than partial-write.

### 9.4 Default MaxCostTier

Milestone CLI default: `MaxCostTier=paid` (so strong roles *may* use paid) but **selection order remains cheapest-capable** within the overlay that deprioritizes the incumbent except reserved seats. This is policy in fleet routing notes / box-private config, not hardcode of vendor names in the repo.

---

## 10. CLI sketch (non-normative names OK at plan time)

```text
/baton:milestone run
  --diff <range> | --ref <sha> | (default: merge-base..HEAD)
  --reason manual|closeout|release
  --passes 2
  --producers all|none|documentor,storyteller
  --strict
  --json
```

Exit codes:

| Code | Meaning |
|---|---|
| 0 | completed; report written (even if verdict is reject — advisory) |
| 2 | usage / config error |
| 3 | `--strict` and (verdict reject **or** degraded) |

---

## 11. v1 scope (buildable in a couple of days)

**In:**

1. Seed roles: `portability`, `voice` in `review-roles.yaml` (+ plugin reference).
2. Seed `producer-roles.yaml` with documentor + storyteller path prefixes.
3. `milestone-lib.ps1`: pack resolve, pass loop calling existing gate, diversity helper (provider exclude list), `Aggregate-MilestoneFindings` (stable/volatile + security promotion), `Format-MilestoneReport`.
4. Capability inventory builder (deterministic file scrape — no LLM).
5. Producer dispatch as **one labor task each** with hard path prefixes + branch naming; wire to existing executor if ready, else a thin "spawn agentic with allowed_paths" seam that tests can stub.
6. CLI + `/baton:milestone` command; hermetic tests for aggregate math, role parse, inventory, path-scope rejection, report sections.
7. Bootstrap manifest + deploy-assert for new scripts/seeds.

**Deliberately out of v1 (see §12).**

---

## 12. Deliberately excluded

- Auto-merge of producer branches to default branch.
- Milestone as default on every `/baton:gate` or every go acceptance.
- Blocking merge without `--strict` (and even then: CLI exit, not git hook malware).
- Third LLM "chair" synthesis across reviewers.
- N>3 passes; auto-run-until-stable.
- Documentor writing product code or tests.
- Storyteller writing beyond `README.md` (no website, no tweets, no changelog fiction).
- Continuous doc sync on every PR.
- GitHub issue auto-filing from product-gaps.
- Making humanizer skill itself a reject gate.
- Model IDs in `review-roles.yaml` / `producer-roles.yaml`.
- Cross-exam / debate rounds between reviewers.
- Dashboard UI for milestones.
- Training a custom voice classifier.

---

## 13. Error handling

| Condition | Behavior |
|---|---|
| No review roles usable | degraded; fail-open accept on code phase **unless** `--strict` |
| One pass fully unparsed | aggregate on surviving pass; mark diversity/support reduced; volatile-heavy |
| Producer scope violation | producer fail; no branch publish; report failure |
| Empty capability inventory | skip storyteller; documentor may still run |
| Producer diff empty | producer `noop`; no panel spend |
| Budget would exceed mid-run | skip remaining producers; finish report |
| Voice reject on README | producer verdict reject/polish; branch retained for human |

---

## 14. Testing (hermetic)

- Aggregate: same finding two passes → stable; one pass one role → volatile; security critical volatile → promoted.
- Verdict: only stable drives reject; disagreement → polish.
- Role parse: new roles; `voice` skipped on code-only artifact classifier fixture.
- Inventory: fixture repo → expected command bullets.
- Producer path: write outside prefix → fail.
- CLI: `--no-producers` never calls producer dispatcher (stub).
- Regression: ordinary `Invoke-AcceptanceGate` single-pass path byte-stable when milestone code is unloaded.

---

## 15. Assumptions (flagged)

1. **Docs follow code** is the preferred honesty policy (d-mp-5).  
2. Operator will **actually invoke** milestones at release/closeout — if not, the feature rots; the closeout *offer* is intentional friction.  
3. At least two distinct **strong** providers exist on the box for diversity; if not, multi-pass still reduces *sampling* variance on one model but not *model* variance.  
4. Agentic labor for docs is trustworthy enough under path scope; if not, v1 can degrade producers to "draft into run dir only" without branch (escape hatch for plan phase).  
5. `voice` at `cheap` tier is good enough; may need promotion after live data.  
6. Incumbent vendor = the one whose budget dropped ~5× (box-private identity).  
7. README is the sole marketing surface that matters for v1.

---

## 16. Where this design is probably wrong

Honest self-critique — read before approving:

1. **Stable-only verdicts may suppress true single-finder criticals** outside the security keyword list (e.g. a subtle data-loss bug only one correctness pass sees). Multi-pass was motivated by false criticals *and* false cleans; biasing toward suppression of volatiles re-creates false cleans. Mitigation later: promote *any* volatile critical to a "human must ack" section without changing the formal verdict, or require a third targeted confirm pass (named panel v2 already parked confirm-on-critical).

2. **Docs-follow-code can launder product bugs into "documented limitations."** A sophisticated failure mode: broken behavior gets documented as intended. Discrepancy notes help only if humans read them. Alternative worth considering: documentor never deletes a capability claim without filing a product-gap of severity ≥ important.

3. **Producers as full agentic labor may dominate cost** and get permanently run with `--no-producers`, leaving asks 4–5 unserved. A cheaper v1.5 would be "draft into run dir as markdown proposals" without agentic repo edit — weaker UX, far cheaper.

4. **Milestone triggers that are "offer only" will be skipped** under time pressure — the same reason gates stayed advisory. If the operator wanted depth *enforced* at release, `--strict` on a release script is required; social process may not hold.

5. **Claim-check via `spec-compliance` overlay** overloads a role name that means "artifact vs original task" on code. Cleaner: a milestone-only role `claims` — but that grows the roster. v1 should decide at plan time whether to overload or add `claims`.

6. **Parallel documentor + storyteller** can race (storyteller rewrites README while documentor still reflects old behavior). v1 parallel is a cost/latency choice; **serial (documentor → inventory refresh → storyteller)** is safer and probably correct — flag this as the first plan-time flip.

7. **Diversity soft-preference** is easy to implement wrong (always same "cheapest" wins). Needs an explicit `Select-Capability` exclude-or-rerank hook; without it, multi-pass is double-tax on one model.

8. **Advisory + expensive** is a motivationally unstable combo: people ignore costly advice they can skip. Either spend less (review-only default) or make release scripts `--strict`.

---

## 17. Decisions summary (for later Grimdex capture on approve)

| Id | Choice |
|---|---|
| d-mp-1 | Explicit milestone tier; not every gate |
| d-mp-2 | Advisory default; `--strict` for loud non-zero; no merge veto in v1 |
| d-mp-3 | Add `portability` (strong) + `voice` (cheap); same yaml contract |
| d-mp-4 | Producers separate yaml; scoped labor → panel on diff; never auto-merge |
| d-mp-5 | Docs follow code; product gaps as findings, not code edits |
| d-mp-6 | Storyteller grounded on deterministic inventory + claim-check panel |
| d-mp-7 | Multi-pass default 2; stable/volatile aggregate; security-critical promotion |

---

## 18. Suggested implementation order (after approval)

1. Aggregation pure functions + tests (no fleet).  
2. Role seed additions + gate pack filter.  
3. Milestone CLI review-only path.  
4. Inventory + storyteller/documentor stubs with path scope.  
5. Wire real labor spawn; cost telemetry on the report.  
6. Dogfood on one real release cut; adjust voice tier and serial/parallel producers.

---

## 19. Open forks for the operator

1. **Serial vs parallel producers** — design default parallel; **recommendation: serial** (documentor → storyteller).  
2. **New role `claims` vs overlay on `spec-compliance`.**  
3. **Review-only as the default** (`--producers` opt-in) vs producers-on for `--reason release`.  
4. **Whether volatile non-security criticals should force human ack** (report section vs verdict).  
5. **Confirm-on-critical third micro-pass** now vs later (interacts with named-panel v2 backlog).

---

*End of spec. Design only — no implementation in this change.*
