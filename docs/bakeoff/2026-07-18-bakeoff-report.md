# Real-project bakeoff report (#93)

**Date:** 2026-07-18 · **Status:** COMPLETE for the evidence it can produce · **Spec:**
[`../superpowers/specs/2026-07-18-real-project-bakeoff-design.md`](../superpowers/specs/2026-07-18-real-project-bakeoff-design.md)

**Headline:** Arm B (manual baseline) shipped 4 of 4 slices. Arm A (the governed golden path)
completed **0 of 4** — it never reached labor on any slice. It was stopped by a chain of five
structural defects, every one caught *before* labor at **$0 labor spend**, and every one now filed
with a reproduction. This is a loss for the golden path and a decisive win for the bakeoff: the
"best-designed, least-proven" critique has been converted from an opinion into five numbered,
fixable issues.

Worker names are placeholders per the box-private rule (`worker-a` = primary CLI implementer,
`worker-b` = conductor-side subagent, `worker-c` = secondary CLI). Token counts carry their d059
basis (`exact` | `estimate`) and are never summed across bases.

**Target repo:** a real, active FastAPI/SQLite dashboard project from the owner's portfolio.
**Baseline honesty:** the target's `main` moved three times mid-bakeoff (owner merged two feature
waves), so each slice records its own baseline rather than one frozen number.

---

## 1. Results

| Slice | Arm A (golden path) | Arm B (manual baseline) |
|---|---|---|
| S1 security fix | **Failed** — 4 attempts, never reached labor | **Shipped-mergeable**, ~9 min |
| S2 small feature | **Failed** — plan rejected, never reached labor | **Shipped-mergeable**, ~7 min |
| S3 refactor | **Not run** — blocked by the same defect (see §4) | **Shipped-mergeable**, ~5 min |
| S4 + induced quota death | **Not run** — untestable until labor is reachable | **Shipped-mergeable**, ~24 min |

### Six measures, where both arms produced data

| Measure | Arm A | Arm B |
|---|---|---|
| Completion | 0/4 | **4/4** |
| Human interventions | 6 across 2 slices (re-invokes + 2 env amendments) | 7 across 4 slices (1–4 per slice) |
| Gate / review catches | **7 findings, all substantive** (see §3) | 1 confirmed defect caught in review (S1) |
| Regressions | none possible (nothing shipped) | **0** — every slice green (382 / 437 / 436 / 439) |
| Wall-clock | ~40 min to terminal failure across 2 slices | ~45 min total for 4 shipped slices |
| Effective cost | **$0 labor** — every failure preceded dispatch | worker-a 4,594 tok (estimate) across 3 slices; worker-b 135,844 tok (**exact**) on S4 |

---

## 2. Why Arm A never shipped — the defect chain

Each fix revealed the next layer. This ordering is the finding.

1. **#118 — no onboarding path.** A target repo without a committed `.baton/verification.json`
   can never pass `--execute`; the failure was correct but offered no remedy. Resolved for the
   bakeoff by a logged one-time env setup.
2. **#119 — the planner never knew `verify_profile` existed.** The plan schema documented neither
   `verify_profile` nor `allowed_paths`, so every code-gen plan was rejected by the gate that
   requires them. **Default `--execute` had never completed on a real repo.** Fixed and merged
   same-day (PR #120); the fix visibly worked — plans went from 6 tasks with bogus parallel-worktree
   machinery to 2 clean tasks with red-test and fix correctly merged into one verified task.
3. **#123 — the plan gate has no roster headroom.** It hard-requires 2 unique reviewers, but only
   two providers in the shipped roster declare `plan-review`. With one on an operator hold, the
   golden path became unrunnable with no remedy message. Worked around by granting the capability
   to an already-enabled provider.
4. **#124 — an empty labor pool reports as a verification defect.** With the labor pool empty
   (one provider held, one under a usage lockout), the executor dispatched to nobody, produced no
   diff, and the run reported `verification-failed (no-change)` — while the test suite itself ran
   **green**. The operator is pointed at a phantom implementation bug instead of "no provider can
   edit files, here is why each was excluded." A direct hit on the legibility north star.
5. **#125 — the planner cannot fill `allowed_paths` correctly.** Having learned the field exists,
   it must now guess the repo's layout with no evidence: it proposed `src/` for a repo whose code
   lives in `app/`, and invented `templates/` and `static/` roots. Compounding it, the schema says
   the field takes "files/dirs" while verification enforces **exact path equality**, so even a
   correct directory token fails closed. **This blocked both slices that reached it.**

---

## 3. What Arm A proved it is good at

Arm A produced no shipped code, so its labor, verification, and review-panel quality remain
**unmeasured**. But its *plan gate* — the one node that ran repeatedly — was consistently right:

- **S1: the gate predicted Arm B's only real defect before Arm B wrote it.** It warned that a
  `(key.lower(), key, value)` sort key would reorder repeated identical keys. Arm B's implementer
  then wrote exactly that key; the manual review pass caught it and fixed it to `(key.lower(), key)`.
- **S2: the gate independently identified the chart's central design trap** — that `topic_scores`
  interleaves 1d/3d/7d windows and a single line over mixed windows is misleading. Arm B's
  implementer had handled this well (preferring one window with a fallback). Both arrived at the
  same insight from opposite directions.
- Every scope and path finding checked out against the real repo. Zero false positives across
  seven findings.
- **Total labor cost of all Arm A failures: $0.** Fail-loud spent nothing on unrunnable plans —
  precisely the behavior the d086 flip was built for.

---

## 4. Runs not attempted, and why

S3-A and S4-A were **not run**. Two independent slices had already hit #125's critical
scope-violation, making it a deterministic pre-labor blocker rather than a slice-specific accident;
further runs would have produced identical rejections and no new information. S4-A is additionally
*untestable* until labor is reachable at all — its purpose is measuring automated failover during
labor, and no Arm A run has ever started labor. Both will run once #125 lands. Stated here rather
than quietly omitted, per the protocol's no-cherry-picking rule.

Mulligans used: none. Every attempt is recorded, including the four S1-A attempts and two operator
errors (a run cut from a contaminated base, and a self-inflicted usage lockout left over from S4-B's
induced cap-death — both caught, both logged).

---

## 5. Verdict

**On the question asked** — does the governed golden path ship real work better-per-dollar than a
competent manual baseline? — **the golden path did not ship at all, so on today's evidence the
manual baseline wins outright.** No qualification, no asterisk.

**On what that means.** The failure was not in Baton's ideas; it was in never having run them
end-to-end on a repo that wasn't Baton itself. Every blocker was configuration, schema, or
plumbing between the planner and repo reality — not gate logic, not routing, not verification
semantics. The parts that ran, ran well and cheaply. Notably, the manual arm's quality depended
on a human-shaped review pass: remove it and S1-B ships with the defect Arm A's gate had already
named.

**What the bakeoff bought.** Five filed issues with reproductions, one already merged (#119),
a same-day demonstration that the fix moved the failure one layer deeper, and an end to arguing
about the "least-proven" critique. That is worth more than a green scorecard would have been.

**Next:** fix #125 (with #123 and #124 close behind), then re-run all four Arm A slices from scratch
and update this report with a real head-to-head. The Arm B branches are deliberately left unmerged
so both arms can face an identical `main`.
