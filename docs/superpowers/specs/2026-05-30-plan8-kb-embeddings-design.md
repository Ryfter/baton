# Plan 8 — Embedding-Based KB Retrieval — Design

**Date:** 2026-05-30
**Status:** Draft (autonomous defaults — user can redirect mid-stream)
**Author:** Claude
**Predecessors:** Plan 3 (KB), Plan 7 (multi-project dashboard), Decision Loop
**Successors:** (open)

---

## Umbrella context

Plans 3 + Decision Loop populated a growing knowledge base:
`~/.claude/knowledge/universal/*.md` + `projects/<id>/*.md` + `projects/<id>/decisions/d*.md` + `jobs/<id>/lessons.md`. Today, retrieval is grep + reads. As the corpus grows, that breaks. Plan 8 indexes the KB into embeddings and adds semantic top-k lookup — usable from a slash command, callable by `/research` pre-fanout, and (optional) surfaced in the dashboard.

```
KB writers   ── /job-lesson, /consolidate-*, decision-capture, /project-init
KB readers   ── grep + read (today) → top-k semantic search (Plan 8)
Consumers    ── /kb-search, /research pre-fanout, dashboard search box
```

## Purpose

Given a query like *"how do we handle multi-machine ollama dispatch?"* the orchestrator returns the top-k most relevant KB chunks with their source paths. Used:
1. Directly via `/kb-search`.
2. By `/research` to prepend top-k chunks to each fleet member's prompt (turning the ensemble into a tiny RAG).
3. (Optional) Dashboard `/kb/search?q=...` for manual exploration.

## Non-goals (deferred)

- **Auto-indexing on KB writes.** Plan 8 ships explicit `/kb-index`; a PostToolUse hook to re-index touched files is Plan 8.1.
- **Embedding ensemble outputs / job briefs.** High churn, lower long-term signal. Skip in v1.
- **Cross-encoder reranking.** Plain cosine top-k. Reranking is a follow-up.
- **Streaming index updates.** Full or mtime-incremental only.
- **Hybrid sparse+dense (BM25 + cosine).** Cosine-only v1.
- **`sqlite-vec` / dedicated vector DB.** Numpy flat search is fast enough at this scale (~ms per query for <10K chunks); avoid the binary dep.
- **Cloud embedding backends.** Local-first ethos (matches the rest of the orchestrator). Ollama is the default; swap-out point clearly factored.

## Architecture overview

```
       ┌─────────────────────────────────────────────────────────────┐
       │   CLAUDE CODE (orchestrator)                                │
       │     /kb-index [--full]                                      │
       │     /kb-search "<query>" [--k N] [--scope all|universal|<id>]│
       │     /research → calls kb.search → prepends top-k to prompts │
       └─────────────────────┬───────────────────────────────────────┘
                             │  PowerShell slash → python -m kb.*
                             ▼
       ┌─────────────────────────────────────────────────────────────┐
       │  kb/  (NEW python package, sibling of dashboard/)           │
       │     chunker.py   — markdown → chunks                        │
       │     embedder.py  — Ollama /api/embeddings client            │
       │     store.py     — numpy .npz + JSON metadata (flat search) │
       │     index.py     — CLI: walk corpus, embed, upsert          │
       │     search.py    — CLI: query embed → cosine top-k          │
       │     tests/       — pytest                                   │
       └─────────────────────────────────────────────────────────────┘
                             │
                             ▼
            ~/.claude/knowledge/.index/
              ├── vectors.npz      (N × D float32 matrix)
              ├── metadata.json    (per-row source path, span, chunk text, mtime)
              └── manifest.json    (corpus version, dim, model, last index ts)
```

## Components

### 1. `kb/chunker.py`

Markdown-aware splitter. Pure Python.

```
chunk_file(path: Path, *, max_chars: int = 1500, overlap: int = 200) -> list[Chunk]

Chunk:
    source: str        # absolute path
    span: (int, int)   # char offset start, end
    text: str          # chunk text
    section: str | None # nearest preceding markdown heading
```

Strategy:
- Split on `^#{1,6}\s` markdown headings — chunks never cross a heading boundary.
- Within a heading-bounded section, split on blank-line paragraph breaks, accumulating until `max_chars`, then start a new chunk with `overlap` chars of trailing context.
- Plain text (no headings) → paragraph-only splitting, same overlap.

### 2. `kb/embedder.py`

Thin Ollama HTTP client. No `ollama` python package — just `httpx` (already in dashboard requirements).

```
embed(texts: list[str], *, model: str = 'nomic-embed-text', host: str = OLLAMA_HOST) -> np.ndarray
  → shape (N, D), dtype float32. Calls POST {host}/api/embeddings one per text.
```

`OLLAMA_HOST` default = `http://localhost:11434`, overridable via `OLLAMA_HOST` env (matches Ollama's own convention).

L2-normalises vectors before returning so cosine similarity reduces to a dot product.

### 3. `kb/store.py`

Flat-search vector store. Pure numpy + JSON.

```
class VectorStore:
    def __init__(self, index_dir: Path): ...

    def load(self) -> None
        # reads vectors.npz, metadata.json, manifest.json; tolerates missing
    def save(self) -> None
    def upsert(self, rows: list[dict], vectors: np.ndarray) -> None
        # rows[i] keys: source, span, text, section, mtime
        # idempotent on (source, span) — replaces same-key rows
    def remove_source(self, source: str) -> int
        # drops all rows for a source (used by incremental re-index when mtime changes)
    def search(self, query_vec: np.ndarray, k: int = 5, *, scope_filter: str | None = None) -> list[Hit]
        # cosine top-k via vectors @ query_vec.T (vectors already L2-normalised)
        # scope_filter: 'universal' or '<project-id>' — matched against the source path prefix
        # returns Hit(score, source, span, text, section)
    @property
    def manifest(self) -> dict
```

`vectors.npz` is a single `np.float32` matrix shape (N, D). `metadata.json` is a list aligned to row index. `manifest.json` records `{dim, model, last_index_at, source_mtimes: {<path>: <iso ts>}}` — the mtime map drives incremental reindex.

### 4. `kb/index.py` (CLI)

```
python -m kb.index [--full] [--scope universal|<id>|all] [--corpus-root <path>]
```

Walks the corpus (defaults: `~/.claude/knowledge/**`, `~/.claude/jobs/**/lessons.md`), chunks each file, embeds, upserts. Incremental by default: only re-index sources whose mtime is newer than the manifest's record. `--full` rebuilds from scratch.

**In-scope sources:**
- `~/.claude/knowledge/universal/**/*.md`
- `~/.claude/knowledge/projects/*/**/*.md` (incl. `decisions/d*.md`, `cost.md`, `decision-guidance.md`)
- `~/.claude/jobs/*/lessons.md`

**Out-of-scope sources (deferred):**
- `~/.claude/jobs/*/brief.md`, `manifest.yaml`, `phase-log.md`
- `~/.claude/ensembles/**` (high churn)
- `~/.claude/jobs/*/phases/**` (job-internal scratch)

Prints a summary: files scanned / chunked / added / removed / skipped, plus elapsed time.

### 5. `kb/search.py` (CLI)

```
python -m kb.search "<query>" [--k 5] [--scope all|universal|<id>] [--json]
```

Embeds the query, runs top-k, prints `score  source:span  section  snippet` per line. `--json` emits the same as a JSON array (consumed by `/research` integration).

### 6. PowerShell slash commands

**`commands/kb-index.md`:**
- `/kb-index [--full]` → invokes `python -m kb.index` (with `--full` passed through), pipes output to user, then prints next steps.
- Bootstrap-time: if `nomic-embed-text` is not pulled in Ollama, prompts the user with `ollama pull nomic-embed-text` (one-time, 274 MB) before retry.

**`commands/kb-search.md`:**
- `/kb-search "<query>" [--k N] [--scope <id>|universal|all]` → invokes `python -m kb.search` and pretty-prints the result.

### 7. `/research` integration

Extend the existing `/research` slash command to:
1. Take the question.
2. Before fanning out to the fleet, call `python -m kb.search "<question>" --k 3 --json`.
3. If hits returned, prepend a "Relevant prior knowledge" section to each provider's prompt: `"<source>: <snippet>"` joined with `---`.
4. Fan out as today; synthesize as today; the synthesis MAY cite which retrieved chunks informed the answer.

Backward-compatible: if `kb-search` returns nothing (no index yet, or no hits), `/research` falls back to its current behavior unchanged.

### 8. Dashboard search panel (deferred / optional)

If time permits in this PR: `GET /kb/search?q=<query>&k=N&scope=...` returns JSON; a small home-page card with a text input lets you search the KB live. Otherwise this lands in a follow-up.

## Output / data flow

```
~/.claude/knowledge/.index/
  ├── vectors.npz       np.float32 shape (N, D=768 for nomic-embed-text)
  ├── metadata.json     [{source, span_start, span_end, section, text, mtime}]
  └── manifest.json     {model, dim, last_index_at, source_mtimes:{...}}
```

Incremental reindex algorithm:
1. Read manifest; for each tracked source, compare current mtime to recorded.
2. **Removed sources** (in manifest but no longer on disk) → `remove_source(path)`.
3. **Changed sources** (mtime newer) → `remove_source(path)` then re-chunk + embed + upsert.
4. **New sources** (on disk but not in manifest) → chunk + embed + upsert.
5. **Unchanged** → skip.
6. Persist manifest with updated mtimes.

## Bootstrap changes

- Add `kb-index.md`, `kb-search.md` to the commands foreach.
- Add `kb-lib.ps1` (thin wrapper calling `python -m kb.*`) to the scripts foreach.
- Create `~/.claude/knowledge/.index/` directory (empty seed).
- Print a one-line prompt: "Run `ollama pull nomic-embed-text` to enable Plan 8 retrieval, then `/kb-index`."

`requirements.txt` (top-level OR dashboard/requirements.txt) gains: `numpy` (already), `httpx` (already). **No new dependencies** for the v1 numpy backend.

## Testing strategy

`kb/tests/test_chunker.py`:
- Empty file → no chunks
- File with no headings → paragraph-split chunks within `max_chars`
- File with headings → chunks don't cross heading boundaries
- `overlap` carries trailing context into the next chunk

`kb/tests/test_store.py`:
- `upsert` + `save` + `load` round-trip preserves rows and vectors
- `upsert` is idempotent on (source, span) — re-upserting same key replaces, doesn't duplicate
- `remove_source` drops all rows for a path
- `search` returns top-k sorted by score (descending)
- `search` with `scope_filter='universal'` excludes project sources

`kb/tests/test_index_incremental.py`:
- Initial full index → manifest records mtimes
- Touch a file → incremental run re-indexes only that file
- Delete a file → incremental run removes its rows
- Unchanged corpus → second run is a no-op (zero embed calls)

Embedder tests **mock** the HTTP call — no live Ollama dependency in CI.

`scripts/test-kb-lib.ps1` — short smoke for the PowerShell wrappers (assumes Ollama present; skipped if not).

## File layout (repo)

```
D:\Dev\coding-agent-orchestrator\
├── docs/superpowers/specs/2026-05-30-plan8-kb-embeddings-design.md    ← this
├── commands/
│   ├── kb-index.md                  ← NEW
│   ├── kb-search.md                 ← NEW
│   └── research.md                  ← MODIFY: pre-fanout kb.search call
├── scripts/
│   ├── kb-lib.ps1                   ← NEW (python -m kb.* wrappers)
│   ├── test-kb-lib.ps1              ← NEW
│   └── bootstrap.ps1                ← MODIFY: deploy kb-lib + kb-index/search commands, seed .index dir
└── kb/                              ← NEW python package
    ├── __init__.py
    ├── chunker.py
    ├── embedder.py
    ├── store.py
    ├── index.py
    ├── search.py
    └── tests/
        ├── __init__.py
        ├── conftest.py
        ├── test_chunker.py
        ├── test_store.py
        └── test_index_incremental.py
```

Deployed under `~/.claude/`: `scripts/kb-lib.ps1`, `commands/kb-index.md`, `commands/kb-search.md`, dir `knowledge/.index/`. The `kb/` Python package stays in-repo and is invoked by absolute path — no install step needed (matches dashboard's pattern).

## Success criteria

- `/kb-index --full` against the current KB completes in < 2 minutes and produces `vectors.npz` + `metadata.json` + `manifest.json`.
- `/kb-search "decision loop"` returns at least one hit pointing at `~/.claude/knowledge/projects/coding-agent-orchestrator/decision-guidance.md` or a related file, with score > 0.4.
- `/kb-index` (incremental) on an unchanged corpus issues zero `/api/embeddings` calls.
- `/research "..."` continues to work when the index is empty (graceful fallback) and uses retrieved chunks when present (verifiable in the synthesis).
- All `kb/tests/` pass.

## Decisions made (autonomous)

- **Local-only embeddings via Ollama (`nomic-embed-text`).** Matches the orchestrator's local-first ethos. Free. 768-d. Bootstrap nudges the user to `ollama pull nomic-embed-text` (one-time 274 MB). Swap point is a single line in `embedder.py`.
- **Numpy flat search, no sqlite-vec / FAISS.** At expected corpus size (≤10K chunks) flat cosine is sub-millisecond per query. Removes a binary dep. Swap point is `kb/store.py`.
- **Python core, PowerShell wrappers.** Matches dashboard pattern. PowerShell slash commands invoke `python -m kb.*` for the actual work.
- **Mtime-based incremental indexing.** Simpler than content-hash tracking; good enough since file edits always change mtime.
- **Scope: KB + decisions + lessons.** Skip jobs/briefs and ensemble runs in v1 (high churn, lower long-term signal).
- **Markdown-aware chunking.** Heading-bounded, paragraph-respecting; 1500-char chunks with 200-char overlap (text-units, not tokens — simpler, slightly conservative).
- **No reranking, no hybrid search v1.** Cosine top-k is the floor; can layer later.
- **L2-normalise at embed time.** Lets `search` use plain matmul (faster than recomputing norms per query).
- **No auto-index hook in v1.** Explicit `/kb-index` keeps surprise factor low; auto-on-write is Plan 8.1.
- **Dashboard search panel is optional in this plan.** If implementation is taking longer than expected, ship the core (CLI + slash commands) and follow up with the panel.
