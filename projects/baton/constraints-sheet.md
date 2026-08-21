# Constraint Sheet — Persistence Roles & Promotion Rules (PROVISIONAL)

> Status: SCAFFOLD — UNVERIFIED. Derived solely from the task brief, not read
> from source files. Downstream tasks must confirm/replace every entry against:
> GRIMLORE.md, projects/baton/BATON.md, projects/baton/index.md,
> Baton docs/ecosystem-boundaries.md, and memory-ingest/recall commands.

## Persistence roles (per brief; verify before relying)
| System             | Role (as stated in brief)      | Verified? | Source + line |
|--------------------|--------------------------------|-----------|---------------|
| Grimlore           | Durable store of selected files| [ ]       | TBD           |
| Grimdex            | Index                          | [ ]       | TBD           |
| Caura-style recall | Live fleet recall              | [ ]       | TBD           |
| Run ledgers        | Per-run records                | [ ]       | TBD           |

## Ask First promotion rule (name only; exact text TBD)
- Rule exists under the name "Ask First" governing promotion.
- Verbatim rule text: TBD — must be quoted from sources before enforcement.

## Hard constraints (names only; exact scope TBD)
- No-copy: TBD — confirm precise prohibition (e.g., no duplicating persisted
  content across stores vs. broader ban on copies/exports).
- No-unified-plugin: TBD — confirm precise prohibition (e.g., no single plugin
  unifying Grimlore/Grimdex/Caura surfaces).

## Open questions for the evidence pass
1. What qualifies a file as "selected" for Grimlore durability?
2. What does Grimdex index (paths, metadata, embeddings)?
3. What does "live fleet recall" cover in the Caura-style path?
4. Where do run ledgers live, who appends to them, and are they immutable?
5. Does Ask First gate promotion into Grimlore only, or all cross-layer moves?
6. Does no-copy forbid backups/exports, or only runtime duplication?

## Downstream pointers (added by overnight pass)
- `~/.baton/overnight/memory-architecture.md` — PROVISIONAL draft comparing the four
  persistence layers; recommends Caura-style live recall as the 7-day factory-uptime
  default, with run-ledger replay as the recovery path and Ask First as the sole
  promotion gate. Same unverified status as this sheet — confirm both against
  sources in the same evidence pass.
