# Decision log (plain language)

Every significant choice in this project is captured as a **decision record** — a small
markdown file holding *what was chosen*, *the alternatives*, *the reasoning*, a
*confidence* level, and a *revisit-if* condition. They live in the private knowledge
repo at `~/.claude/knowledge/projects/coding-agent-orchestrator/decisions/dNNN-*.md`.

This page is the human-readable index so you never have to decode a bare ID like
"d007". For the full reasoning and alternatives of any record, open its file.

## How a decision graduates (the lifecycle)

A record starts life as **unproven**. When you later learn how it turned out, you
attach a verdict with [`/baton:decision-feedback`](COMMANDS.md#decision-feedback):

- `worked` → the record moves to **Established patterns** in the guidance.
- `didnt` / `mixed` → it moves to **Known mistakes** and the record is flagged for review.
- *(no verdict yet)* → it sits under **Open / under-feedback**.

`/baton:consolidate-decisions` then rolls all records into two guidance docs:
- **Per-project** — `knowledge/projects/<id>/decision-guidance.md`
- **Universal** — `knowledge/universal/decision-guidance.md` (a pattern only promotes
  here once it has a `worked` verdict in **2+ projects**).

So "graduating d001–d015" simply means: attach an honest verdict to each, then
re-consolidate, so the guidance reflects what's *proven* instead of *untested*.

## The records

| # | Decision | What it decided | Why | Confidence |
|---|----------|-----------------|-----|------------|
| d001 | Per-project cost ledger | Track AI spend in a simple per-project text table + `/cost`, no database | Matches the plain-text style, zero new deps, one billing number is enough today | high |
| d002 | Six Hats run in parallel | Six fixed thinking roles asked across models at once; Claude summarizes | Fixed method needs no config; parallel is faster with no quality loss | high |
| d003 | LLM Council: two rounds | Answer, then critique-and-refine after seeing peers; 2–5 members | Captures peer refinement without doubling cost; hiding own prior answer keeps critiques honest | high |
| d004 | Three-step parallel coding | Decompose → build in isolated repo copies → merge, with a human confirm | Maps to natural review checkpoints; reuses isolation; safe stop on conflicts | high |
| d005 | Read-only project dashboard, no charts | First multi-project view is tables only, basic text parsing | Keeps the feature small, reuses the dashboard; editing/charts can wait | high |
| d006 | Local AI search over the KB | Local embedding model + in-memory math, Python core with light wrappers | Instant at this scale, fully local and free, no paid/binary deps | high |
| d007 | Track which model did each backlog item | Record model/outcome/fixes as GitHub Project board custom fields | At-a-glance, filterable record without a second board | high |
| d008 | Isolated work + orchestrator-only merge gate | Each task in its own repo copy; only the orchestrator merges after strict checks | Self-merging models corrupt repos; isolation + one gatekeeper is the cheapest safeguard | high |
| d009 | Only file-editing AIs implement code | Codex/Claude write code; text-only models do research/review | Verified in practice: text-only models returned unusable prose | high |
| d010 | Gated per-item branches merge to main | Finished items merge straight to main (one revertible commit); Gemini reviews design | Operator owns the repo, everything's backed up, the gate makes direct-to-main safe | high |
| d011 | Keep the smaller embedding model | Keep `nomic-embed-text` vs a larger model, after an A/B test | ~Equal quality, smaller is slightly better and uses < half the disk/RAM | high |
| d012 | Tag each fleet log with its origin machine | Add the launching machine name to every fleet log line, at the end | Only thing that disambiguates merged multi-machine logs; trailing placement avoids breaking parsers | high |
| d013 | Show partial results by reading output files | Dashboard previews progress by reading per-model files; runner untouched | Models already write files as they finish; a read-only change avoids touching risky concurrency | high |
| d014 | One vendor-neutral shared knowledge base | Single private repo named `knowledge`; any AI tool can read/contribute | Decisions describe the work and the user, not one model; the whole fleet shares one brain | high |
| d015 | Fully offline, self-contained dashboard | No external network requests — bundle front-end libs locally, system fonts | A local single-operator tool must work on a fresh PC with no internet | high |
| d016 | Back up every project to private GitHub | Push each project's code + its knowledge/decision data every session | Knowledge lived outside the repo, unversioned; "dead drive → ready on a new PC" | high |

## Status as of 2026-06-05

- **d016** carries a `worked` verdict and sits in **Established patterns**; it was also
  promoted to **Universal guidance** (proven in 2 projects).
- **d001–d015** are still **Open / under-feedback** — proven in practice but without an
  attached verdict yet. Graduating them is the next tidy-up (attach `worked`, with
  `mixed` a fair call for the lightly-exercised d004 and d012, then re-consolidate).
