# Guided Use — the Baton Coach (design)

**Date:** 2026-07-03
**Status:** approved approach (Kevin: "Approach 1 looks good. Spec it.")
**Decision record:** d074
**Target version:** v1.8.0

## Problem

Kevin (2026-07-03): "a lot of these features are kind of hidden unless they are
suggested to the user. So, it may be worth creating (and prompting) workflows.
So, fire off certain commands when starting and suggest as development goes on,
what commands to issue to optimize the use of Baton. Think of it as guided use."

Baton's surface area (optimizer pool, shadow A/B, acceptance gate, usage
governor, effective-cost leaderboard, ideas, memory bridge) is invisible to
anyone who doesn't already know the command names. The legibility north star
applies to the tool itself, not just the agents. Today the only guidance is
`/baton:start`'s resume path (`Get-NextCommandRecommendation`, a run-status →
`{command, why}` map in `scripts/start-lib.ps1`) — guided use at n=1.

## Decisions made

- **Approach: coach engine + two surfaces** (chosen over prompt-only guidance
  in the command `.md` files, which can't read signals or fire at session
  start and would drift; and over a full `/baton:coach` surface with
  suggestion queue + statusline glyph, which is the v2 of this design).
- **Session start auto-runs a digest** — cheap, read-only, local-only checks
  (project state, pool verdict, budget position), never a model call, never a
  mutation. (Chosen over recommend-only, which teaches nothing, and full
  implicit `/baton:start`, which hijacks quick sessions.)
- **Volume scales with registration** — registered Baton project → full
  digest; unregistered git repo → one quiet onboarding line; anywhere else →
  silence. (Chosen over projects-only, which never fixes discoverability, and
  everywhere-same-volume, which is Clippy.)
- **One-shot suggestions + a coach level knob** — each push suggestion fires
  once per triggering state (the `promote_recommended_at` pattern from
  v1.7.1); global level `off | quiet | teach`, default `quiet`. The
  **orientation digest is a status report, not a nag — it never dedups**;
  one-shot stamps apply to push suggestions only (in-flight footers, plus
  the digest's one push case: the unregistered-repo onboard line).

## Architecture

One pure rules engine, two consumers.

```
scripts/coach-lib.ps1            ← engine (new)
scripts/hooks/baton-coach.ps1    ← consumer 1: SessionStart digest (new)
fleet-go / fleet-gate /
fleet-optimize-prompt /
fleet-usage                      ← consumer 2: "Next:" footers (modified)
$BATON_HOME/coach/seen.json      ← one-shot stamps
$BATON_HOME/coach/config.json    ← { "level": "quiet" }
```

### coach-lib.ps1 (engine)

All functions never throw to callers on bad state — they degrade to empty
results (guidance must never break the thing it guides).

- `Get-CoachLevel ([string]$BatonHome)` → `'off' | 'quiet' | 'teach'`.
  Reads `$BATON_HOME/coach/config.json`; absent/unreadable file → `'quiet'`.
- `Get-CoachContext (-BatonHome, -ProjectDir)` → hashtable of signals, each
  gathered fail-open (a failed reader leaves its key `$null`, never throws):
  - `project` — project record for `$ProjectDir` (projects-lib), incl.
    `last_run.status`
  - `is_git_repo` — bool (`.git` present walking up from `$ProjectDir`)
  - `pool` — champion id, active challenger id, per-candidate gated-run
    counts, current `Get-ShadowVerdict` state, any pending
    `promote_recommended_at` (prompt-pool-lib)
  - `usage` — conserve mode (`Get-ConserveMode`), today's budget position
    (`Get-WorkerBudget` / `Get-UsageForecast`) (usage-lib)
  - `failure_runs` — count of qualifying polish/reject runs not yet consumed
    by an evolution (reuse `Get-HistoricalRuns` from optimize-prompt-lib)
- `Get-CoachSuggestions (-Context, -SeenPath, [switch]$IncludeSeen)` →
  `@( @{ id; command; why; dedup_key } )`, ordered by the rule table below.
  Filters out entries whose `dedup_key` is stamped in `seen.json` unless
  `-IncludeSeen` (the digest passes `-IncludeSeen`; footers don't). Pure
  given its inputs — the rule table is data inside this function.
- `Set-CoachSeen (-SeenPath, -Key)` — stamps `key → UTC ISO-8601 Z` in
  `seen.json` (utf8NoBOM). Callers stamp only suggestions they actually
  displayed.

### Rule table (v1)

| id | Trigger (from context) | Suggests | dedup_key |
|----|------------------------|----------|-----------|
| `next-command` | `project.last_run.status` present | existing `NextCommandMap` entry (reuse `Get-NextCommandRecommendation`) | — (digest-only, no stamp) |
| `gate-failure` | newest run with gate verdict `polish` or `reject` | `/baton:optimize-prompt` — "this failure can feed the prompt optimizer" | `gate-failure:<run_id>` |
| `promote-pending` | a candidate has `promote_recommended_at` set and is still active | `/baton:optimize-prompt --apply <id>` — "live evidence says this challenger wins" | `promote:<candidate_id>` |
| `pool-verdict` | active challenger and both champion + challenger have ≥5 gated live runs | `/baton:optimize-prompt --pool` — "enough live evidence for a verdict" | `pool-verdict:<champion_id>:<challenger_id>` |
| `budget` | conserve mode ON, or forecast shows today's budget at risk | `/baton:usage` — "see where the spend is going" | `budget:<yyyy-MM-dd>` (daily) |
| `onboard` | `is_git_repo` and no project record | `/baton:start` — "register this repo so Baton can orient and route for you" | `onboard:<normalized ProjectDir>` |

Adding a rule later = one table entry; no new plumbing. (A fleet-health rule
is deliberately deferred: fleet doctor has no cached freshness signal to read
yet — don't invent one for this feature.)

### Consumer 1 — SessionStart digest (`scripts/hooks/baton-coach.ps1`)

New hook script registered in `hooks/hooks.json` under `SessionStart`
(matcher `startup`), after `baton-init.ps1`. Its stdout becomes session
context, which Claude relays as orientation. Contract identical to
baton-init: `$ErrorActionPreference = 'Continue'`, always `exit 0`, errors
appended to `$BATON_HOME/logs/baton-coach.err.log`, never blocks a session.

Behavior by scope (and level — `off` prints nothing at all):

- **Registered project:** 3–5 lines — project + last-run status, pool
  one-liner (champion / challenger / verdict state), budget one-liner, then
  the single top suggestion from the rule table. `teach` level appends each
  line's `why`; `quiet` prints commands only.
- **Unregistered git repo:** the `onboard` line only, one-shot per repo
  (stamped — this is a push suggestion, not a status report).
- **Not a git repo:** print nothing.

The digest performs **no model calls, no network calls, no writes** except
onboard's one-shot stamp. Total budget: fast local file reads; if
`$BATON_HOME` is absent, print nothing and exit 0.

### Consumer 2 — in-flight footers

`fleet-go.ps1`, `fleet-gate.ps1`, `fleet-optimize-prompt.ps1`, and
`fleet-usage.ps1` end by calling `Get-CoachSuggestions` (without
`-IncludeSeen`) against fresh post-action context and print at most **one**
footer line, then stamp it:

- `quiet`: `Next: /baton:optimize-prompt`
- `teach`: `Next: /baton:optimize-prompt — this failure can feed the prompt optimizer`
- `off`, or no unseen suggestion: no footer.

The footer path is fail-open: any coach error is swallowed (stderr note at
most) and never changes the command's exit code or output above the footer.
A command never suggests itself (`fleet-usage` skips the `budget` rule, etc.
— the engine takes an optional `-ExcludeIds` for this).

### Command-doc updates

`commands/go.md`, `gate.md`, `optimize-prompt.md`, `usage.md`, `start.md`
gain a short "coach" note (footer exists, how to set the level);
`docs/COMMANDS.md` gains a Guided Use section documenting the digest, the
knob (`$BATON_HOME/coach/config.json`), and the rule table.

## Error handling

- Hook: exit 0 on every path; catch-all writes to
  `$BATON_HOME/logs/baton-coach.err.log`; missing lib files → silent exit.
- Engine: every context reader individually try/caught to `$null`; a
  malformed `seen.json` is treated as empty (and rewritten on next stamp);
  a malformed `config.json` means `quiet`.
- Footers: wrapped so a coach failure can never fail the host command.
- All writes utf8NoBOM; no shell arg approaches the 965-byte limit (hook
  invocations are fixed file paths).

## Testing

Hermetic throughout — temp `BATON_HOME` via try/finally restore, never real
`~/.baton` or `~/.claude` (house rule).

- `scripts/test-coach-lib.ps1` (new): level default/parse; context gathering
  against fixture pool/usage/runs/project records incl. every-reader-fails →
  all-null context; each rule fires on its trigger and stays silent
  otherwise; dedup stamp round-trip (suggest → stamp → filtered; new
  triggering state → new key → fires again); `-IncludeSeen` bypass;
  `-ExcludeIds`; ordering.
- Hook test (pattern of `test-baton-init-hook.ps1`): registered-project
  digest lines; unregistered-repo one-liner + stamp; non-repo silence;
  `off` silence; absent BATON_HOME silence; always exit 0 (including with a
  poisoned pool file).
- Footer coverage added to the touched fleet scripts' suites: footer
  present at `quiet`/`teach`, absent at `off`, absent when stamped,
  self-suggestion excluded, and host-command output/exit unchanged when the
  engine is broken.
- Regressions: full `test-start-lib*`, `test-conductor-lib`,
  `test-prompt-pool-lib`, `test-optimize-prompt-lib`, `test-usage` suites.

## Slicing and release

- **Slice 1 (the "fire off at start" half):** coach-lib + SessionStart
  digest + hook registration + tests → v1.8.0-rc.1.
- **Slice 2 (the "as development goes on" half):** footers in the four fleet
  scripts + command-doc updates → v1.8.0.

One implementation plan covers both slices; slice boundary = commit/RC
boundary, not separate specs.

## Non-goals

- No statusline glyph, no dedicated `/baton:coach` command, no persistent
  suggestion queue (v2 candidates — revisit if the two surfaces prove the
  pattern and Kevin wants more).
- No LLM-generated suggestions — the rule table is static data; the digest
  and footers cost zero model dollars.
- No auto-running of paid or mutating commands at session start.
- No fleet-health rule until fleet doctor exposes a cached freshness signal.
