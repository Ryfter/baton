# Sprint 5 — Memory Bridge (design)

**Status:** approved 2026-06-19
**Roadmap:** Baton v2 economic-conductor MVP, Sprint 5 of 7. Follows Sprint 1
(Triage Agent), Sprint 2 (Usage Governor), Sprint 3 (GitHub Projects sync),
Sprint 4 (Research Gate), and the `/baton:go` Conductor capstone.
**Mantra:** *Don't repeat a known-bad fix. Let AI discover the pattern; crystallize it into a deterministic rule.*

## 1. Scope

A **Projectmem-style dev memory** for Baton: an append-only log of
**problem → attempt → outcome**, queried *before* you act, that warns when a new
task matches a past attempt — especially *"you tried this fix before and it
failed."* This is **memory-as-governance**: the cheapest spend that prevents the
most expensive waste (re-walking a dead end).

Built as a **pluggable adapter interface, not a hard Projectmem dependency**
(per d047). v1 ships a local, box-private JSONL journal and a manual capture
source; a real Projectmem backend or auto-ingest from existing event streams can
be added later as additional sources without touching the query core.

Three operator surfaces: **`/baton:remember`** (capture), **`/baton:recall`**
(pre-action warning), **`/baton:memory-promote`** (crystallize a recurring
pattern into a Grimdex rule). Advisory only — never blocks work.

### The ratchet (why this is not just a log)

The strategic concept is a **discover → crystallize** ratchet:

- **Deterministic key matching** is the hot loop that enforces
  already-crystallized knowledge — hermetic, trustworthy, zero-dependency.
- **Semantic recall** (`-Deep`, reusing the KB embedding index) is the
  *discovery* engine: it surfaces neighbors you would not have keyed exactly,
  feeding promotion candidates.
- **Promotion** crystallizes a recurring attempt/outcome into a deterministic
  Grimdex lesson or decision. Future recall then enforces it deterministically.

One line: **semantic recall proposes → you (or the watcher) promote →
deterministic key enforces.**

### Relationship to existing Baton memory surfaces (the gap this fills)

| Surface | What it is | Why Memory Bridge is different |
|---|---|---|
| job `lessons.md` + `/baton:job-lesson` → `/baton:consolidate-lessons` | Human-authored *categorized prose* notes, walked into KB files | Lessons are what someone chose to write; Memory is the structured attempt→outcome loop with pre-action governance |
| `decisions-lib.ps1` (d-NNN) | Architecture decision records | Decisions are direction choices; Memory is operational "did this fix work?" |
| Conductor `events.jsonl` / `decisions.jsonl` | Per-run ledgers of one run | Run-scoped and ephemeral-per-run; Memory is cross-run, cross-job, queried before the next attempt |
| `usage-journal.jsonl` (Sprint 2) | Worker-availability events | Same Read/Add/Fold *pattern*, different domain |

Memory Bridge is the **promotion target** these can feed: the Conductor ledgers
already record attempt+outcome, so Conductor-ledger ingest is the named next
**source adapter** (deferred — see §8).

### Out of scope (deferred, named so the boundary is explicit)

- **Auto-ingest from existing event streams.** v1 captures via the manual
  `/baton:remember` source only. The `MemorySource` adapter seam is built now so
  Conductor-ledger / job-journal / decision-record ingest can be added later as
  additional sources without changing the query core. (Concept-anchoring: the
  seam names the strategic concept at n=1, per d047; the first additional source
  is a Sprint-5.1 follow-on.)
- **A real Projectmem backend.** The storage interface is local JSONL in v1. A
  Projectmem (or other) backend is one more implementation behind the same
  `Read-MemoryJournal`/`Add-MemoryEvent` interface, deferred.
- **Auto-invocation from Triage/Conductor.** Recall is operator-invoked (and
  available for the Conductor to call later). Wiring recall into the Conductor's
  pre-task loop is deferred to a Conductor follow-up.
- **Semantic backend beyond the KB index.** `-Deep` reuses the existing KB
  embedding search (`Invoke-KbSearch`); no new embedding store is built.
- **Scope/kind-driven write-target routing.** `scope` (project|universal) is
  captured on every row, but v1's promotion writer appends to a single box-private
  lessons file regardless of scope/kind. Routing a `universal` promotion to a
  universal target — or a decision-kind promotion to `decisions-lib.ps1` — is
  deferred; it plugs in behind the same `-Writer` seam without touching the rest.

## 2. Decisions

- **d-mb-1 — hybrid matching: deterministic key is the backbone, semantic is
  discovery.** Each entry carries a normalized `signature` (token-set) computed
  at write time. Recall matches deterministically by signature token-overlap —
  hermetic and trustworthy for a *governance* warning. Semantic recall (KB
  embeddings) is opt-in behind `-Deep` and produces promotion *candidates*, not
  authoritative matches. (Chosen over semantic-first, which is non-deterministic
  — wrong for a warning you must trust — and over deterministic-only, which is
  too brittle to discover drifted phrasings.)
- **d-mb-2 — discover → crystallize ratchet.** Non-deterministic AI recall
  proposes patterns; promotion crystallizes endorsed ones into deterministic
  Grimdex rules that govern cheaply afterward. The architecture treats promotion
  as the spine, not a bolt-on. (Directly reflects the operator's stated working
  style: leverage AI to discover, then build deterministic goals from the
  results.)
- **d-mb-3 — two nomination paths, one promotion action.** Promotion candidates
  arise two ways: **watch** (`Get-PromotionCandidates` auto-detects items
  crossing a threshold — failed ≥ N, or winner seen ≥ N) and **flag**
  (`/baton:memory-promote <id|signature>` — the operator nominates a specific
  memory). Both run the same `Invoke-MemoryPromote`; neither promotes silently —
  both end in a visible Grimdex write. (Chosen over a single auto-only path,
  which gives the operator no doorway, and over manual-only, which makes the
  operator babysit.)
- **d-mb-4 — pluggable source adapter (d047 applied).** Capture goes through an
  `Invoke-MemorySource` seam. Manual entry is the built-in v1 source; additional
  sources (Conductor ledgers, etc.) plug in without touching recall. No hard
  Projectmem dependency.
- **d-mb-5 — advisory, never blocking.** Recall emits a warning + candidates; it
  does not stop work. Consistent with Triage, Research Gate, and the Conductor's
  minimal-interrupt posture.
- **d-mb-6 — box-private state, hermetic seams.** The journal lives at
  `$BATON_HOME/memory-journal.jsonl` (box-private). The semantic touch goes
  through a `-Searcher` seam; tests stub it — no network, no model, no real
  `$BATON_HOME`, no real Grimdex. Any committed example carries placeholder
  content only.

## 3. Memory entry schema (one JSONL row)

```json
{
  "ts": "2026-06-19T18:30:00.000Z",
  "id": "mem-20260619-183000-a1b2",
  "kind": "attempt",
  "signature": "auth flaky fix test",
  "problem": "auth integration test is flaky in CI",
  "approach": "mock the system clock in the token-expiry check",
  "outcome": "fail",
  "tags": ["ci", "auth", "testing"],
  "source": "manual",
  "refs": { "job": "j-0042", "run": null, "decision": null },
  "scope": "project",
  "promoted": false
}
```

| Field | Meaning |
|---|---|
| `id` | `mem-<yyyyMMdd>-<HHmmss>-<rand4>` — stable row id, used by flag-promote |
| `kind` | `attempt` \| `outcome` \| `note` |
| `signature` | deterministic key: normalized token-set of `problem`, computed once at write |
| `outcome` | `pass` \| `fail` \| `partial` \| `unknown` |
| `source` | which `MemorySource` produced it (`manual` in v1) |
| `refs` | optional links to job / Conductor run / decision record |
| `scope` | `project` \| `universal` (mirrors lessons; drives promotion target) |
| `promoted` | set `true` once crystallized, so it stops re-flagging |

**Signature normalization** (`Get-MemorySignature`, pure, deterministic):
lowercase → strip absolute/relative paths, line-numbers, hex/UUID hashes, and
digits-with-units → collapse whitespace → split → drop stopwords → return the
sorted distinct token set joined by spaces. Same input always yields the same
signature; stored on the row so matching never re-derives it.

## 4. Architecture

House pattern: a **pure layer** (no network/model, fully unit-testable) plus a
**seamed layer** (`-Searcher` for semantic discovery, `Invoke-MemorySource` for
capture).

### Files

- **`scripts/memory-lib.ps1`** — core library.
  - *Pure:*
    - `Get-MemorySignature` — text → normalized token-set key (see §3).
    - `Read-MemoryJournal` — robust JSONL reader (missing path → empty; malformed
      line skipped). Mirrors `Read-UsageJournal`.
    - `Add-MemoryEvent` — append one row; computes `id` + `signature`; creates the
      parent dir; never throws on write fault (warns). Mirrors `Add-UsageEvent`.
    - `Find-MemoryMatches` — fold the journal; return rows whose `signature`
      token-overlap with the query signature meets a ratio floor; ranked by
      overlap then recency. The deterministic core.
    - `Get-PromotionCandidates` — scan folded matches/journal; flag a signature
      with `fail` count ≥ `FailThreshold` (governance) or a `pass`/winner count ≥
      `WinThreshold` (crystallize). Excludes rows already `promoted`.
    - `Format-RecallReport` — matches + auto-flagged candidates → human-readable
      warning string (and the hashtable a `-Json` caller serializes).
    - `Format-PromotionMemo` — a candidate → the Grimdex lesson/decision draft text.
  - *Seamed:*
    - `Invoke-MemoryRecall` — orchestrates: signature → `Find-MemoryMatches`
      (deterministic, always) → if `-Deep`, append KB semantic neighbors as
      candidates via the `-Searcher` seam (default = `Invoke-KbSearch`; offline
      makes **zero** searcher calls) → `Get-PromotionCandidates` overlay →
      return the recall hashtable.
    - `Invoke-MemorySource` — capture adapter; `-Source` selects the producer
      (`manual` built-in; default scriptblock builds a row from CLI args). Named
      seam for future Conductor-ledger ingest.
    - `Invoke-MemoryPromote` — given a candidate (from watch) or an `id`/signature
      (from flag): `Format-PromotionMemo` → write the memo to the box-private Grimdex
      lessons file via the `-Writer` seam → stamp source rows `promoted`. (Scope/kind
      then routing to a universal target or `decisions-lib.ps1` is deferred — see §1;
      the seam makes it a drop-in later.) A `-Writer` seam stands in for the write in tests.
- **`scripts/fleet-memory.ps1`** — CLI dispatching three subcommands:
  `remember` (capture), `recall` (warn), `promote` (watch list / flag one).
- **`commands/remember.md`, `commands/recall.md`, `commands/memory-promote.md`** —
  the `/baton:*` slash commands (each shells to `fleet-memory.ps1 <sub> $ARGUMENTS`).
- **`scripts/test-memory-lib.ps1`** — hand-rolled `Check($n,$c)` harness;
  `-Searcher` and `-Writer` stubbed, journal + Grimdex targets are temp dirs.
  Never touches a real network, model, `$BATON_HOME`, or Grimdex.
- **Touched:** `scripts/bootstrap.ps1` (manifest: add `memory-lib.ps1`,
  `fleet-memory.ps1`), `scripts/test-bootstrap.ps1` (two deploy assertions),
  `.claude-plugin/plugin.json` (`1.2.0-rc.12` → `1.2.0-rc.13`).

## 5. Data flow

### remember
1. Parse `problem` / `approach` / `outcome` / `tags` / `scope` from CLI.
2. `Invoke-MemorySource -Source manual` builds the row.
3. `Add-MemoryEvent` computes `id` + `signature`, appends to the journal.
4. Echo the stored `id` + computed signature.

### recall
1. Resolve task text (`--text` / `--file` / `--url`, reusing the one-of-three idiom).
2. `Get-MemorySignature` → `Find-MemoryMatches` (deterministic, always).
3. If `--deep`: `-Searcher` → KB semantic neighbors appended as candidates
   (degrade silently to deterministic-only on searcher error/empty index).
4. `Get-PromotionCandidates` overlay.
5. `Format-RecallReport` → stdout (or `--json`). Warning leads with failed-attempt
   count; promotion candidates listed below.

### promote
- **No args (watch):** scan the journal → list every current candidate with its
  reason (failed ≥ N / winner ≥ N) → operator confirms each to write.
- **`<id|signature>` (flag):** resolve the memory → `Invoke-MemoryPromote` →
  Grimdex write → stamp `promoted`.

## 6. Error handling

- **Missing/empty journal** → recall returns "no prior memory" cleanly; no throw.
- **Malformed journal line** → skipped (robust reader).
- **`--deep` searcher throws / KB index absent** → degrade to deterministic-only;
  report notes "semantic discovery unavailable."
- **Promote an unknown id/signature** → clear error, no write.
- **Grimdex write fault** → warn, leave rows un-stamped so the candidate re-surfaces.
- **No `$BATON_HOME`** → resolved via `baton-home.ps1` like every other surface.

## 7. CLI surface

```
/baton:remember --problem "<p>" --approach "<a>" --outcome pass|fail|partial|unknown
                [--tags a,b,c] [--scope project|universal] [--ref-job <id>]
/baton:recall   --text "<task>"  [--deep] [--json]
/baton:recall   --file <path.md> [--deep] [--json]
/baton:memory-promote                      # watch: list current candidates
/baton:memory-promote <id|signature>       # flag: promote one
```

Recall example:

```
$ baton recall --text "fix the flaky auth integration test"
RECALL — signature: auth flaky fix integration test
⚠ 2 prior attempts on this signature — 2 FAILED:
  • mock the system clock in token-expiry  — FAILED (still flaky)  [j-0042]
  • raise the test timeout to 30s          — FAILED (masked it)    [j-0051]
PROMOTION CANDIDATE: this signature has failed 2× — consider /baton:memory-promote
  to record a rule ("don't fix auth-test flakiness by mocking the clock / raising timeouts").
```

## 8. Testing (~28 checks)

**Pure layer (no network/model):**
- `Get-MemorySignature`: strips paths, line-numbers, UUIDs/hex, digit-units;
  stopwords dropped; identical input → identical token-set; order-independent.
- `Read-MemoryJournal`: missing path → empty; malformed line skipped; valid rows parsed.
- `Add-MemoryEvent`: appends a row with computed `id` + `signature`; creates parent
  dir; write to an unwritable path warns, does not throw.
- `Find-MemoryMatches`: exact-signature hit; token-overlap hit above floor;
  below-floor miss; ranked by overlap then recency.
- `Get-PromotionCandidates`: fail-count ≥ threshold fires; winner-count ≥ threshold
  fires; `promoted:true` rows excluded; below-threshold yields none.
- `Format-RecallReport`: leads with failed count; lists each match; lists candidates.
- `Format-PromotionMemo`: renders problem, the attempts, the proposed rule.

**Seamed (stubbed `-Searcher` / `-Writer`):**
- `Invoke-MemoryRecall`: deterministic matches with no `-Deep` make **zero**
  searcher calls; `-Deep` invokes the stubbed searcher and appends its neighbors
  as candidates; searcher error → deterministic-only, noted.
- `Invoke-MemorySource`: manual source builds a well-formed row.
- `Invoke-MemoryPromote`: watch candidate → `-Writer` called with the memo, source
  rows stamped `promoted`; flag by `id` → same; unknown id → error, no write;
  writer fault → rows left un-stamped.

**CLI (temp `$BATON_HOME`, temp Grimdex):**
- `remember` round-trips a row into the journal; `recall --text` prints the warning;
  `recall --json` emits JSON; `promote` (no args) lists candidates; `promote <id>`
  writes via the stubbed writer. Zero network and zero real-model calls across the suite.

**Bootstrap:** asserts `memory-lib.ps1` and `fleet-memory.ps1` deploy.

## 9. Risks

- **Signature too coarse / too fine.** Over-normalizing collapses distinct
  problems to one key (false warnings); under-normalizing misses drifted
  phrasings (silent gaps). Mitigation: the token-set + overlap-ratio floor is
  tunable; `-Deep` semantic recall backstops missed matches; tests pin the
  normalization rules.
- **Promotion noise.** Aggressive thresholds nag. Mitigation: thresholds are
  config; nothing promotes silently; `promoted` stamping stops re-flagging.
- **Stale memory.** A fix that failed once may work after the codebase changes.
  Mitigation: memory is advisory, shows the original context, and records
  `pass` outcomes too — a later success outweighs an old failure in the report.
- **Scope leakage.** A project-specific memory promoted as `universal` pollutes
  the global constitution. Mitigation: `scope` is explicit on every row, and
  promotion is operator-confirmed and box-private (nothing leaves the box). v1
  writes one box-private lessons file; once scope/kind-driven routing lands (§1),
  `scope` selects the target so a `universal` promotion reaches the universal file.
