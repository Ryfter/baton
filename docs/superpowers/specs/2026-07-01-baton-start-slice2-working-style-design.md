---
title: /baton:start Slice 2 — Working-Style Learning Loop
status: draft
date: 2026-07-01
supersedes: none
relates-to: /baton:start slice 1 (2026-07-01), effective-cost slice 3 (d060)
---

# /baton:start Slice 2 — Working-Style Learning Loop

## Summary

Slice 1 wrote a minimal `user-profile.json` (two fields: `preferred_interview_depth`,
`teaching_level`) so personalization existed from day one. Slice 2 **grows that
profile into a learning loop**: observe what the user actually does across projects,
distil patterns after enough evidence, and let those patterns feed back into the next
onboarding — so a returning user's interview keeps shrinking and the recommendations
keep sharpening, without them having to say anything twice.

This is the **sibling of the d060 learned-cost routing loop**, one layer up:
- d060 learns *who to route to* based on cost/quality evidence from run artifacts.
- Slice 2 learns *how to talk to the user* based on behavioural evidence from
  onboarding sessions.

Both follow the same **discover → crystallise → enforce** ratchet from the Memory
Bridge (d-mb-2): the system proposes; the operator (or auto-promotion threshold)
crystallises; the deterministic key enforces.

## Goals

- **Observe naturally.** Every `/baton:start` onboarding session records a lightweight
  behavioural observation — chosen depth, teaching level, turns taken, answers
  volunteered — into a box-private append-only `style-journal.jsonl`.
- **Fold with confidence gating.** When >=N observations are available, fold the
  journal into `user-profile.json` updates: raise or lower `preferred_interview_depth`
  and `teaching_level` automatically.
- **Grimdex supplement.** When an observation crystallises into a stable preference
  (high-confidence fold), offer to write a compact "working-style note" to the
  Grimdex Baton tier — making the preference portable across machines and available
  to any agent.
- **Opt-in promotion.** Auto-fold is opt-in per profile field (a `_learning: true`
  flag per field, default off for backward-compat). Crystallisation never overwrites
  a field the user has set explicitly and locked.
- **Zero new commands.** The loop is entirely internal to `/baton:start`; no new
  slash commands.

## Non-goals

- Slice 3 (mid-stream idea injection) — out of scope.
- Learning *which projects* a user tends to start, or learning anything about run
  outcomes (that is the d060 / effective-cost domain).
- Syncing the profile *automatically* between machines — Grimdex is the cross-machine
  channel, but sync is manual (the user pushes Grimdex; pull is on the new machine's
  next `/baton:start`).
- Any UI surface beyond the terse one-liner recommendation already emitted by slice 1.

## Architecture

House pattern: extend `start-lib.ps1` (pure functions + thin I/O seams); extend
`commands/start.md` to call the new functions at the right junctures. New file:
`scripts/test-start-lib-s2.ps1` (hermetic suite for the new functions).

### New box-private stores

**`$BATON_HOME/style-journal.jsonl`** — append-only, one JSON object per line:
```json
{
  "at": "2026-07-01T12:00:00-06:00",
  "project_id": "acme-api",
  "depth_used": "full",
  "depth_explicit": false,
  "teaching_used": "teach",
  "teaching_explicit": false,
  "turns_to_goal": 3,
  "audience_volunteered": false,
  "done_volunteered": false,
  "reasoning_quality": "brief"
}
```

Fields:
- `depth_used` / `teaching_used` — what was resolved and applied.
- `depth_explicit` / `teaching_explicit` — true if the user passed a flag; explicit
  observations are excluded from auto-fold (they represent a one-off override, not a
  preference).
- `turns_to_goal` — how many conversational turns the user took to confirm the goal
  (proxy for how much they needed the structure).
- `audience_volunteered` / `done_volunteered` — whether the user gave those
  answers without being asked (signals they are comfortable with full depth).
- `reasoning_quality` — `'brief' | 'detailed' | 'none'` (how much reasoning they
  gave for the CHARTER's Why section; a proxy for engagement level).

**`user-profile.json`** — extended schema (backward-compatible; slice-1 fields
unchanged):
```json
{
  "preferred_interview_depth": "light",
  "teaching_level": "teach",
  "updated_at": "2026-07-01T09:20:00-06:00",
  "depth_learning": true,
  "teaching_learning": true,
  "depth_observations": 5,
  "teaching_observations": 5
}
```

New fields:
- `depth_learning` — bool, default `false`. When `true`, `preferred_interview_depth`
  may be updated by the fold.
- `teaching_learning` — bool, default `false`. Same for `teaching_level`.
- `depth_observations` / `teaching_observations` — count of non-explicit
  observations used to derive the current value (for confidence display).

### New functions in `start-lib.ps1`

All pure unless noted. Path params injectable for tests.

#### `Add-StyleObservation` (thin I/O)
```
Add-StyleObservation
  -JournalPath <string>   # default $BATON_HOME/style-journal.jsonl
  -ProjectId   <string>
  -DepthUsed   <string>
  -DepthExplicit <bool>
  -TeachingUsed <string>
  -TeachingExplicit <bool>
  [-TurnsToGoal <int>]
  [-AudienceVolunteered <bool>]
  [-DoneVolunteered <bool>]
  [-ReasoningQuality <string>]
```
Appends a single JSON line. Never throws — write failures caught + logged to
`Write-Debug`; a missed observation is not fatal.

#### `Read-StyleJournal` (thin I/O)
```
Read-StyleJournal -JournalPath <string> -> object[]
```
Reads all lines, parses each as JSON, silently skips malformed lines. Returns `@()`
on missing file (fail-open).

#### `Get-StyleFoldDecision` (pure)
```
Get-StyleFoldDecision
  -Observations <object[]>     # from Read-StyleJournal, ALL rows (function filters)
  [-MinObservations <int>]     # default 5
  [-ConfidenceThreshold <double>] # default 0.70
  -> @{
       depth_recommendation    : string | $null
       teaching_recommendation : string | $null
       depth_confidence        : double
       teaching_confidence     : double
       observation_count       : int
     }
```

Pure logic — no I/O. Rules:

**Depth fold:**
- Filter to non-explicit observations (`depth_explicit -eq $false`).
- If count < `MinObservations`: `depth_recommendation = $null` (insufficient data).
- Vote by plurality: tally `depth_used` across the window. Majority winner wins.
- `depth_confidence = winner_count / total_non_explicit_count`. If confidence <
  `ConfidenceThreshold`, recommendation is `$null` (split signal — don't act).

**Teaching fold:** Same logic over `teaching_used` / `teaching_explicit`.

Both are conservative: a split signal produces no recommendation. Zero rows → both
$null, count 0, confidences 0.0 (no divide-by-zero).

#### `Invoke-StyleFold` (thin I/O + calls `Get-StyleFoldDecision`)
```
Invoke-StyleFold
  -JournalPath     <string>
  -ProfilePath     <string>
  [-MinObservations <int>]   # default 5
  -> @{ updated: bool; depth_changed: bool; teaching_changed: bool; note: string }
```
- Reads journal + profile.
- If `depth_learning` absent or `$false`: skip depth fold. Same for `teaching_learning`.
- Calls `Get-StyleFoldDecision`. For each recommendation that meets the confidence
  threshold and differs from the current profile value:
  - Update the profile field.
  - Increment `depth_observations` / `teaching_observations`.
  - Set `updated_at`.
- Writes profile if any field changed (`utf8NoBOM`).
- Returns the change summary.

#### `Format-StyleFoldNote` (pure)
```
Format-StyleFoldNote -FoldResult <hashtable> -> string | $null
```
Returns `$null` if `updated -eq $false`. Otherwise returns a terse one-liner:
```
[baton:start] Interview style updated: depth → light, teaching unchanged
  (based on 6 sessions; your next /baton:start will reflect the lighter interview)
```
Emitted at end of onboarding (same teach/quiet gating). `quiet` mode still shows
it — a profile update is always visible.

#### `Get-GrimdexStyleNote` (pure)
```
Get-GrimdexStyleNote -Profile <object> -> string
```
Formats a compact plain-text working-style note suitable for appending to
`D:\Dev\Grimdex\projects\baton\notes\working-style.md`:
```markdown
## Working-style snapshot — <date>
- Interview depth: light (from 6 sessions)
- Teaching level: teach (from 3 sessions)
- Updated: <timestamp>
```
Pure — returns the string; caller decides whether to write it. Used by `start.md`
when a fold produces a high-confidence update (`depth_confidence > 0.85` or
`teaching_confidence > 0.85`) to surface the suggestion: "Your preferences have
stabilised — want me to save this to Grimdex so any machine knows?"

**Never auto-writes Grimdex** — operator decision, matching the Memory Bridge's
crystallise step.

### `commands/start.md` changes (additions only; slice-1 logic untouched)

Two new junctures:

1. **After capturing interview answers (before writing CHARTER):**
   Call `Add-StyleObservation` with the resolved depth/teaching + observed
   behaviour (turns taken, answers volunteered). Always called — even if the user
   passed explicit flags (recorded as `explicit: true`, excluded from fold).

2. **After writing CHARTER / before handing to `/baton:go`:**
   Call `Invoke-StyleFold`. If `updated -eq $true`, emit `Format-StyleFoldNote`.
   If `depth_confidence > 0.85` or `teaching_confidence > 0.85`, also emit the
   Grimdex suggestion line. If the user consents, write `Get-GrimdexStyleNote`
   output to Grimdex notes file (check for path existence first — if Grimdex is not
   present on this box, skip silently with a note to the user).

## Data flow

```
/baton:start
│
├── [existing] resolve depth + teaching from profile
├── [existing] run interview
│
├── [NEW s2] Add-StyleObservation → style-journal.jsonl (append)
│
├── [existing] write CHARTER, register project
│
├── [NEW s2] Invoke-StyleFold
│   ├── Read-StyleJournal
│   ├── Get-StyleFoldDecision (pure)
│   └── Write-UserProfile (if changed)
│       → emit Format-StyleFoldNote to user
│       → if high-confidence: offer Get-GrimdexStyleNote write (operator-gated)
│
└── [existing] hand to /baton:go
```

## Box-private boundary

- `style-journal.jsonl` and the extended `user-profile.json` are box-private under
  `$BATON_HOME`. Never in the knowledge repo or shared seed.
- The Grimdex working-style note (`notes/working-style.md`) is the *only* cross-box
  artefact, and it is written only on explicit operator consent. The note contains
  only preference labels and counts, never project content.

## Testing (`test-start-lib-s2.ps1`)

Hermetic. Temp dirs, injected `JournalPath`/`ProfilePath`, zero network.

**Observation writer (A-series, ~4 checks):**
- A1: `Add-StyleObservation` appends a valid JSON line; round-trips via `Read-StyleJournal`.
- A2: Multiple appends are each on their own line (no overwrite).
- A3: Missing journal dir → created; missing file → created.
- A4: `Read-StyleJournal` on a missing path returns `@()` (no throw).

**Fold decision (B-series, ~10 checks):**
- B1: Fewer than `MinObservations` non-explicit rows → both recommendations `$null`.
- B2: 5 rows all `full`/`teach` → `depth_recommendation = 'full'`, confidence 1.0.
- B3: 4/5 `light`, 1/5 `full` → confidence 0.8 (>= threshold) → recommendation returned.
- B4: 3/5 `light`, 2/5 `full` → confidence 0.6 (< 0.70) → `$null`.
- B5: Explicit rows excluded from vote + count; split after exclusion → `$null`.
- B6: Mixed explicit/non-explicit dataset: only non-explicit rows counted.
- B7: Teaching fold: majority `quiet` → `teaching_recommendation = 'quiet'`.
- B8: Teaching split → `$null`.
- B9: `observation_count` reflects non-explicit count only.
- B10: Zero rows → both `$null`, count 0, confidences 0.0 (no divide-by-zero).

**Fold invoke (C-series, ~8 checks):**
- C1: Profile with `depth_learning: false` → depth fold skipped; `depth_changed: false`.
- C2: Profile with `depth_learning: true`, clear signal → depth updated; `updated: true`, `depth_changed: true`.
- C3: Profile field already equals recommendation → no write, `depth_changed: false`.
- C4: Profile `$null` → fold is a no-op (learning flags absent → default off).
- C5: `depth_observations` counter incremented on each update.
- C6: `updated_at` refreshed when a field changes; unchanged when nothing changed.
- C7: Both depth and teaching update in the same fold → both reflected in result.
- C8: Journal write failure (read-only path) → `Add-StyleObservation` returns without throw.

**Format (D-series, ~4 checks):**
- D1: `Format-StyleFoldNote` returns `$null` when `updated: false`.
- D2: `Format-StyleFoldNote` with `depth_changed: true` includes `depth →` in output.
- D3: `Get-GrimdexStyleNote` output includes depth, teaching, timestamp.
- D4: High-confidence threshold: confidence 0.86 → above 0.85 threshold; 0.84 → below.

**Bootstrap (E-series, 2 checks):**
- E1: `scripts/start-lib.ps1` staged (already asserted; re-verify).
- E2: `scripts/test-start-lib-s2.ps1` staged by `bootstrap.ps1`.

**Target: ~28 checks.**

## Decisions

### d-s2-1 — Append-only journal, not a mutable store

The journal is `style-journal.jsonl`, append-only. Avoids read-modify-write races,
preserves full history, matches the Memory Bridge and effective-cost patterns already
in the codebase.

*Alt:* Update a running aggregate in `user-profile.json` on every session. *Rejected:*
Loses history; conflates raw observations with the distilled signal.

### d-s2-2 — Opt-in `_learning` flags per field, default `false`

A user who never opts in is unaffected — their profile is written exactly as slice 1
wrote it. Matches d-mb-2's crystallise step: transparent, deliberate, never surprising.

*Alt:* Default on. *Rejected:* Silently changing interview depth after 5 sessions
without the user's knowledge is surprising behaviour.

### d-s2-3 — Conservative plurality vote with confidence gate

Fold uses plurality (majority winner) with a `ConfidenceThreshold` (default 0.70).
A split signal produces no change. Prevents oscillation on noisy data.

*Alt:* Weighted average of a numeric encoding. *Rejected:* Depth + teaching are
categorical, not ordinal. Plurality is transparent and easy to explain.

### d-s2-4 — Grimdex write is always operator-gated

The style note is never auto-written to Grimdex. The command emits the suggested
content and asks. Matches the Memory Bridge promotion pattern.

*Alt:* Auto-write when confidence > 0.85. *Rejected:* Grimdex is the canonical
knowledge store; silent writes violate the "operator crystallises" principle.

### d-s2-5 — Fold runs every session after observation write

`Invoke-StyleFold` is called after every observation. Simple (no state machine),
correct (idempotent: only writes when something changes), and cheap (reads one small
file, runs a trivial vote).

## Out of scope / future

- **Slice 3 — Mid-stream idea injection.**
- **`/baton:profile` command** — future surface to read/set/reset profile fields
  including toggling the learning flags.
- **Multi-machine pull** — pulling the Grimdex style note into a fresh machine's
  profile (`Read-GrimdexStyleNote → Merge-UserProfile`).
