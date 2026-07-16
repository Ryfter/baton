# Per-PR ship report — design

**Date:** 2026-07-16 · **Status:** SPEC — Kevin approved the direction in conversation
("Ok, good. That is where I need help."); build slots after #94 Layer 2 · **Origin:**
Claude's blind-spot observation 2026-07-16: *Baton measures its instruments obsessively but
never the pipeline* — nobody can answer "what did shipping this PR actually cost, end to
end?" even though every ingredient is already journaled. Terms per `docs/glossary.md`.

## 1. What this is

One **ship-report card** per merged PR: the end-to-end cost, quality, and choreography story
of that unit of shipped work, assembled from data Baton already records. No new
instrumentation in slice 1 — this is journal aggregation.

Example (reconstructed from #94 slice 1, 2026-07-16):

| Dimension | Value |
|---|---|
| Build | codex, 439k tok (exact), 1 cap-death recovery, 8 commits |
| Review | deep: grok-cli 25k, 8 findings / 8 confirmed · lenses: 2 local (free), 11 findings / 3 confirmed |
| Fix passes | grok-cli 2k, 1 commit |
| Verification | 2 full local gates (68 suites) + pytest, free |
| Wall-clock | ~2.5h dispatch→merge |
| Conductor overhead | not tracked (honest gap — see §5) |
| Outcome | merged `fcfc1df`; post-merge defects: (fills in later) |

## 2. Data sources (all existing)

- **Fleet journal** — per-dispatch provider, duration, exit, `tok:N` + basis (exact/estimate),
  origin host (d012).
- **`decisions.jsonl`** (run-scoped, v1.17.0) — stakes, stakes_basis, depth_tier,
  selection_mode, cost_tier per task.
- **Usage Governor journal** — lockout/cooldown/failover events (cap-deaths, substitute hops).
- **git** — commits, authorship, branch lifetime (first commit → merge timestamp).
- **GitHub** (gh CLI, d084) — PR number, merge SHA, linked issue.
- **Review verdicts** — slice 1 parses the conductor's review-record comment format
  (VERDICT / FINDINGS-COUNT lines are already conventions in `prompts/review-*.txt`); a
  shared verdict enum (#96 candidate) upgrades this later.

## 3. Surface

- **`/baton:ship-report <pr-number>`** (and `-Branch`/`-RunDir` fallbacks for unmerged
  work-in-progress views). Renders the card as markdown.
- **Written to:** the run dir (`ship-report.md`) + posted as the PR's closing comment —
  the evidence-on-the-issue pattern, automated.
- **Trend view:** `/baton:ship-report --all` = one table row per shipped PR (cost, findings
  confirmed-rate, wall-clock) — the cost-per-shipped-PR trend line.

## 4. What it unlocks (why it's worth a slice)

1. **Cost-per-shipped-PR trending** — the pipeline-level analytics that instruments-only
   telemetry can't answer.
2. **Provider ROI at the task level** — the dataset #93's bakeoff needs; the evidence engine
   for closing "best-designed, least-proven."
3. **Reviewer roster ratings** — findings-confirmed-rate per reviewer, computed instead of
   anecdotal (tonight's "locals are tripwires: 27→3" lesson becomes a standing metric).
4. **#91 compound skeleton** — the card IS the closeout artifact's factual half; #91 adds
   the prevention-answer half.
5. **#96 feed** — once fix/verify stages emit a shared verdict enum, FIX_PROVEN rates per
   provider drop straight into the card and the graduation dataset.

## 5. Honest gaps (declared, not faked)

- **Conductor (Claude) tokens are not journaled** — slice 1 prints `conductor: not tracked`.
  Adding it is a separate decision (it likely means journaling from the Claude side, not the
  fleet side).
- **Post-merge defect linkage** is manual in slice 1 (a `defects:` field editable on the
  card); automated linkage (issue-back-references) is a later slice.
- Attribution asymmetry: `tok:` basis (exact vs estimate) is carried per row and surfaced on
  the card — never summed silently across bases (d059).

## 6. Scope

**In (slice 1):** `ship-report` command (single-PR card + `--all` trend table); journal +
git + gh aggregation; run-dir write + PR-comment post (post gated behind an explicit flag —
observe-first, d078); hermetic tests with fixture journals; bootstrap deploy-assert.

**Out:** new instrumentation of any kind; conductor-token tracking; dashboards/charts;
automated defect linkage; verdict-enum migration (rides #96); cross-project aggregation.

## 7. House rules

965-byte args; utf8NoBOM; `[Console]::Error.WriteLine` + exit 2; guard every divide (rates
with zero denominators: render `n/a`, never divide); box-private — the card contains
provider names and token counts, which stay in run dirs/PR comments on Kevin's own repos;
the repo seed/docs use placeholder examples only. Ladder: mostly Sonnet-tier aggregation
coding; Codex or Sonnet build; deep review not required unless the diff says otherwise.
