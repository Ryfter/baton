# Memory Architecture — Cross-Model Persistent Memory (Overnight Draft)

> STATUS: PROVISIONAL — drafted without repository/tool access. Claims are tagged
> `[BRIEF]` (stated in the task brief) or `[TBD]` (confirm against sources before
> relying). Verify against: `GRIMLORE.md`, `projects/baton/BATON.md`,
> `projects/baton/index.md`, `projects/baton/docs/ecosystem-boundaries.md`, and the
> memory-ingest/recall commands. Companion sheet:
> `projects/baton/constraints-sheet.md` (same unverified status).

## 0. Hard rules this design honors [BRIEF]
1. **No-copy:** No Source cards are copied into the Baton repo. This document lives
   under `~/.baton/overnight/` (user state, outside the repo) and references sources
   by pointer only.
2. **No-unified-plugin:** Grimlore, Grimdex, and Baton remain separate surfaces.
   This architecture defines interfaces between them, never a merged plugin.
3. **Ask First:** Any promotion between persistence layers (especially into
   Grimlore) routes through Ask First. Exact rule text: [TBD].

## 1. Layer roles [BRIEF — verify wording]
| Layer              | Role                              | Nature                          |
|--------------------|-----------------------------------|---------------------------------|
| Grimlore           | Durable store of selected files   | Long-term, curated, write-gated |
| Grimdex            | Index                             | Derivative lookup layer         |
| Caura-style recall | Live fleet recall                 | Runtime, hot, fleet-wide        |
| Run ledgers        | Per-run records                   | Append-only, automatic          |

## 2. Comparison for cross-model persistent memory
| Dimension          | Grimlore                  | Grimdex            | Caura-style recall            | Run ledgers                    |
|--------------------|---------------------------|--------------------|-------------------------------|--------------------------------|
| Write path         | Gated (selection+Ask First) [TBD] | Derived (reindex) | Continuous, runtime    | Automatic per run              |
| Read path          | File retrieval            | Fast lookup/query  | Fleet-wide live recall        | Replay/scan per run            |
| Lifetime           | Durable                   | Tracks indexed content | Life of live session/fleet | Permanent record              |
| Cross-model fit    | High (canonical files)    | High (shared index)| Highest (built for fleet)     | Medium (per-run fragmentation) |
| Staleness risk     | High if gate is slow      | Mirrors source     | Low while live                | Append-only, but no current-state view |
| Failure mode       | Under-writing/starvation  | Index drift        | Loss on restart [TBD]         | Volume/noise                   |
| Best at            | Canonical truth           | Retrieval speed    | In-flight coordination        | Audit + reconstruction         |

## 3. Requirements for 7-day factory uptime [derived]
- R1 Continuity: any model picks up another model's working context mid-window.
- R2 Interruption tolerance: state recoverable after process/host restart.
- R3 Low-latency recall: hot path must not replay 7 days of history.
- R4 Bounded staleness: working context reflects the current shift.
- R5 Auditability: every automated action traceable afterward.

## 4. Recommended default: **Caura-style live recall**
- R1/R4: only layer whose native read pattern is "current shared context across
  models"; purpose-built for fleet recall.
- R3: serves the hot path directly — no replay, no index hop.
- R2: NOT satisfied natively [TBD — confirm restart behavior]. Mitigation is
  structural: run ledgers run underneath regardless (§5), so a dead recall service
  is rebuilt by replaying ledgers to the interruption point. Ledger replay is the
  documented recovery procedure, not an emergency hack.
- R5: satisfied by the ledger substrate.

**Fallback trigger:** if verification shows Caura-style recall does not survive
restarts AND ledger replay cannot reconstruct its state within the uptime SLA,
demote the default to **run ledgers** (durability-first) and treat live recall as
a cache. Decide before day 1, not after the first crash.

## 5. Supporting cast (roles around the default — not merged, not optional)
- **Run ledgers** — always-on substrate; written every run regardless of default.
  Recovery source (R2), audit source (R5).
- **Grimdex** — index over durable content (Grimlore) and, if supported [TBD],
  ledger summaries. Serves lookups the live path shouldn't handle.
- **Grimlore** — destination for anything that must outlive the 7-day window. Not
  the default working memory: its selection gate suits canonical artifacts, not
  high-frequency operational state.

## 6. Promotion flow (Ask First only)
```
live recall (working set)
   └─ end-of-shift / milestone distillation
        └─ ASK FIRST approval  [verbatim rule text TBD]
             ├─ approved artifact → Grimlore (durable)
             │                      └─ Grimdex reindexes
             └─ rejected → remains in recall/ledgers only
```
No path writes to Grimlore except through Ask First. No path copies Source cards
into the repo.

## 7. Boundary compliance
- Four surfaces stay four surfaces. Integration = documented interfaces (ingest
  command, recall command, index refresh), never a combined plugin. [matches
  ecosystem-boundaries intent — verify]
- This file and successors live in `~/.baton/overnight/`; nothing here is copied
  into `projects/baton/`.

## 8. Open items blocking "verified" status
1. Grimlore selection criteria — who selects "selected files," via what command?
2. Grimdex scope — paths, metadata, embeddings? Which sources may it index?
3. Caura-style recall — restart semantics, capacity, fleet membership model.
4. Run ledgers — location, writer, retention, immutability guarantees.
5. Ask First — verbatim text; scope (Grimlore only vs all cross-layer moves)?
6. No-copy — bans exports/backups, or only runtime duplication?
