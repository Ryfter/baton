# Memory Bridge follow-ups — M1 write-target routing, M2 stable serialization, M3 recall --json (design)

**Date:** 2026-07-04
**Status:** DRAFT — batch-authored at Kevin's direction; defaults chosen,
forks flagged. Not yet approved.
**Target:** one small slice (single RC) — this is finishing work, not a feature

## Problem

Sprint 5 (d054) shipped the Memory Bridge with three tracked review
follow-ups, open since 2026-06-19:

- **M1:** `Write-PromotionToGrimdex` writes one box-private lessons file
  regardless of the promotion's `scope`/kind — the "discover → crystallize"
  ratchet ends in a puddle instead of routing universal lessons to Grimdex's
  universal tier and project lessons to the project tier.
- **M2:** `Set-MemoryPromoted` rewrites journal rows with scrambled key
  order (round-trips fine, but diffs of the journal are noisy and the
  append-only file stops being visually greppable).
- **M3:** `recall --json` has zero test coverage.

## Decisions made (defaults)

- **M1 — scope/kind-driven write-target routing, behind the existing
  `-Writer` seam (d-mb-4 honored):** the default writer becomes a router:
  - `scope: universal` → `$BATON_GRIMDEX_ROOT/universal/lessons.md`
    (avoid-kind promotions → `universal/mistakes.md`, matching the
    established Grimdex layout).
  - `scope: project` → `$BATON_GRIMDEX_ROOT/projects/<project-id>/lessons.md`
    (project id via the same network-free resolution the coach uses).
  - `BATON_GRIMDEX_ROOT` unset/nonexistent → today's box-private lessons
    file, unchanged (fail-open; Grimdex is a box-specific install at
    `D:\Dev\Grimdex`, never assumed).
  Writes are **append-with-header** (date + signature + provenance), never
  rewrites of existing Grimdex content; the Grimdex repo commit/push stays
  human/session-driven (the bridge writes files, the standing backup order
  handles the push). (Alternative — shell out to `decisions-lib.ps1` for
  d-records — rejected: promotions are lessons/rules, not decision records;
  Grimdex's GRIMDEX.md contribution rules govern.)
- **M2 — ordered serialization:** journal rows round-trip through
  `[ordered]` hashtables preserving the original field order (id first,
  then the capture-time fields, `promoted` stamp appended last). Purely
  cosmetic-correctness; no schema change.
- **M3 — backfill `recall --json` tests:** valid-JSON assert + shape
  (matches array, signature, warn fields) + empty-journal → `[]` (the
  `ConvertTo-Json -InputObject @(...)` array trap explicitly asserted —
  the v1.4.0 lesson).
- **Explicitly OUT (still deferred):** the Conductor-ledger ingest producer
  (`Invoke-MemorySource -Producer` reading `decisions.jsonl`) — real
  feature, own spec when the run volume justifies it.

## Architecture (files)

```
scripts/memory-lib.ps1      ← Get-PromotionWriteTarget (pure: scope/kind/root
                              → path); default -Writer routes through it;
                              Set-MemoryPromoted ordered round-trip
scripts/test-memory-lib.ps1 ← target-routing rows, order-stability row,
                              recall --json rows
commands/memory-promote.md  ← routing behavior + BATON_GRIMDEX_ROOT docs
```

## Error handling

- Unwritable/absent Grimdex target → fall back to the box-private lessons
  file + a warning line (a promotion must never be lost to a bad path).
- Unknown `scope` value → box-private file (fail-open default).
- All writes utf8NoBOM append; the journal rewrite in `Set-MemoryPromoted`
  stays whole-file-atomic (write temp, replace) to protect the append-only
  log — this also quietly fixes a latent torn-write risk.

## Testing

Hermetic (temp BATON_HOME + temp fake Grimdex root via env; the existing
`BATON_MEM_LESSONS` redirect keeps everything off the real KB):

- `Get-PromotionWriteTarget`: universal/prefer → lessons.md; universal/avoid
  → mistakes.md; project scope → project tier path; no root → box-private;
  unknown scope → box-private.
- Router writer: append-with-header lands in the fake root; unwritable root
  → box-private fallback + warning.
- M2: promote → re-read journal → field order identical to pre-promotion
  capture (string-level compare, not just semantic).
- M3 rows as above. Full memory suite + bootstrap regression green.

## Open forks (for Kevin)

1. **Env var vs profile field for the Grimdex root:** default
   `BATON_GRIMDEX_ROOT` env (box-private by nature); a `user-profile.json`
   field is the alternative if you want it visible to `/baton:start`.
2. **Should avoid-kind universal promotions also mirror into the
   box-private file** (belt-and-suspenders) or write once? Default: once,
   to the routed target.

## Non-goals

- No Conductor-ledger ingest producer (future spec).
- No semantic/KB write path changes; `-Deep` recall untouched.
- No Grimdex git automation inside memory-lib.
