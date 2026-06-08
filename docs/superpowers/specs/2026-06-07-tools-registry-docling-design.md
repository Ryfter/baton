---
title: Tools registry + Docling PDF call-out (d024 slice)
date: 2026-06-07
status: design
supersedes: none
decisions: [d024, d025]
---

# Tools registry + Docling PDF extraction

## Why

`d024` set the cost-optimization direction: cut direct Claude-token cost by pushing
work off Claude — deterministic work → tools (free), cheap-LLM work → local/free
fleet models, Claude reserved for coordination/judgment. The strategic move is to
make **`tools` a first-class concept co-equal with models**: a declared, cost-tiered,
capability-tagged registry the orchestrator (and any future routing layer) can pick
the *optimal* capability from — "optimal, not best": a free/local tool or model that
is as-good-or-close beats the most powerful paid one.

This slice lays the **foundation + first entry**, not the optimizer. It stands up a
`tools.yaml` registry (the sibling of `fleet.yaml`) and proves it by wiring **Docling**
(IBM OSS, local, free) into the KB ingest pipeline as a `pdf-extract` capability, so
PDFs dropped in the corpus become searchable knowledge with **zero Claude tokens**.

## Decisions

- **d024 (prior):** Docling chosen as the hard-PDF extraction call-out (NeMo Retriever =
  too heavy/GPU-bound; Gemini Flash / Mistral OCR = cheap-cloud fallbacks, not default).
- **d025 (this slice):** Build the `tools.yaml` registry now, at n=1, rather than
  deferring it (YAGNI) until a second non-LLM tool exists.
  - **Alternatives rejected:** (a) in-process-only extractor with no registry — cheaper
    today but leaves `tools` un-named, so a later routing layer has no space to route
    over; (b) force Docling into `fleet.yaml` — structural mismatch, `fleet.yaml` entries
    are `{{prompt}}`→completion LLM processes.
  - **Rationale:** the registry encodes a strategic concept (tools as co-equal, cost-tiered
    capabilities) that the roadmap will keep filling; at n=1 the *concept* is the
    deliverable. Invocation is per-entry `kind` (`python` = in-process import,
    `cli`/`http` = subprocess) so a native Python lib is not forced through a subprocess.
  - **confidence:** high. **revisit-if:** tools never grow beyond Docling (then the
    registry was over-built and should collapse back into a KB detail).

## Non-goals (out of scope)

- The capability-routing **optimizer** ("pick the optimal tool/model for the need").
  Its own later slice, extending `knowledge/universal/routing.md` + `/consolidate-routing`
  from models to tools.
- DOCX / PPTX / scanned-image extraction. Docling supports them; the extractor is keyed
  by file extension so adding them later is trivial — but v1 is **PDF only**.
- A PowerShell tools-registry reader. The only consumer this slice is the Python KB;
  `/tools` shells out to `python -m tools.*`. A PS reader waits for a PS-side tool.
- Any cloud-OCR fallback.

## Architecture

Six units, each with one responsibility and a clear interface.

### 1. `references/tools.yaml` (registry seed)

Mirrors `references/fleet.yaml`. Repo-versioned; bootstrap deploys it to
`~/.claude/tools.yaml` (new Step 5b4, parallel to 5b3's `fleet.yaml`).

```yaml
# tools.yaml — non-LLM callable capabilities, co-equal with fleet.yaml models.
# Lean by design: only what's needed to SELECT and INVOKE a tool lives here.
#
# Fields:
#   name         unique key, [a-z0-9-]+
#   kind         python | cli | http   (how it is invoked)
#   enabled      true | false          (disabled tools are skipped, not invoked)
#   cost_tier    paid | free | local
#   capability   the need it serves (the routing key), e.g. pdf-extract
#   module       (kind:python) importable module path used by the invoker
#   command_template / base_url   (cli/http, future tools)

tools:
  - name: docling
    kind: python
    enabled: true
    cost_tier: local
    capability: pdf-extract
    module: docling.document_converter
```

### 2. `tools/` Python package (new, sibling of `kb/`)

Runs from the repo root, exactly like `python -m kb.index`.

- **`tools/registry.py`**
  - `ToolSpec` dataclass: `name, kind, enabled, cost_tier, capability, module,
    command_template, base_url`.
  - `read_tools(path: Path | None = None) -> list[ToolSpec]` — path resolution
    **param > `$TOOLS_FILE` env > `~/.claude/tools.yaml`** (mirrors `Get-IdeasRoot`/
    `Get-RunsRoot`). Missing file → `[]` (never raises; the `.md` pipeline must survive
    a missing registry). Parsed with `yaml.safe_load` (pyyaml 6.0.3 present).
  - `get_tool(name, *, path=None) -> ToolSpec | None`.
  - `tools_for_capability(capability, *, path=None, enabled_only=True) -> list[ToolSpec]`.
- **`tools/doctor.py`** — `python -m tools.doctor`: for each **enabled** tool, an
  availability probe by `kind` — `python`→`importlib.util.find_spec(module)`;
  `cli`→command on PATH (`shutil.which`); `http`→`base_url` reachable. Prints a
  `NAME / STATUS / DETAIL` table (ok | err | skip) like `fleet-doctor.ps1`; exit `1`
  if any enabled tool errs, else `0`.
- **`tools/list.py`** — `python -m tools.list`: prints `name, kind, enabled,
  cost_tier, capability` as a table.

### 3. `kb/extractors/` (new)

The extraction seam between a corpus file and the chunker.

- **`kb/extractors/__init__.py`**
  - `extract_to_text(path: Path) -> str | None` — dispatch by suffix:
    - `.md`, `.markdown`, `.txt` → `path.read_text(encoding='utf-8', errors='replace')`
      (the existing behavior, now centralized).
    - `.pdf` → look up an **enabled** `pdf-extract` tool via `tools_for_capability`.
      None found → `raise ExtractorUnavailable("pdf-extract: no enabled tool")`.
      `docling` found → call `extract_pdf(path)`.
    - any other suffix (`.png`, `.csv`, …) → `None` (genuinely unhandled type, silent skip).
  - Returns `None` **only** for unknown extensions. For a `.pdf` — a type we promised to
    handle — it always either returns text or raises (`ExtractorUnavailable` when no tool
    is available/enabled, `ExtractorError` on a real conversion failure), so a PDF is never
    silently zero-chunked.
- **`kb/extractors/pdf_docling.py`**
  - `extract_pdf(path: Path) -> str` — **lazy** `from docling.document_converter import
    DocumentConverter`; convert; return `result.document.export_to_markdown()`.
  - `import` failure → `raise ExtractorUnavailable("docling not installed")`.
  - conversion failure → `raise ExtractorError(f"docling failed for {path}: {e}")`.
- Exceptions `ExtractorUnavailable`, `ExtractorError` defined in `kb/extractors/__init__.py`.

### 4. KB wiring (`kb/chunker.py`, `kb/index.py`)

- **`kb/chunker.py`** — split, preserving all current logic:
  - `chunk_text(raw: str, source: str, *, max_chars=1500, overlap=200) -> list[Chunk]`
    — the existing body, operating on a string. Pure; no file I/O.
  - `chunk_file(path, *, max_chars=1500, overlap=200) -> list[Chunk]` — now:
    `raw = extract_to_text(Path(path))`; if `raw is None` → `return []`; else
    `chunk_text(raw, str(Path(path).resolve()), …)`. `ExtractorUnavailable` propagates.
- **`kb/index.py`**
  - `_default_corpus_paths` collects `*.pdf` in addition to `*.md` (universal + projects;
    job lessons stay `.md`). Helper extension list `_CORPUS_GLOBS = ("*.md", "*.pdf")`.
  - In the re-chunk loop, wrap `chunk_file(p)`:
    - `ExtractorUnavailable` → `extractor_skips += 1`, log `  ~ skipped (tool unavailable): {name}`,
      `record_source_mtime` (so it isn't retried until change / `--full`), `continue`.
    - `ExtractorError` → `extractor_errors.append(f"{src}: {e}")`, log to stderr,
      `record_source_mtime`, `continue`.
  - Summary dict gains `extractor_skips: int` and `extractor_errors: list[str]`.
  - `main()` exit code: `2` if `embed_errors` **or** `extractor_errors`, else `0`.

### 5. `commands/tools.md` (`/tools`)

Mirrors `/fleet`. Subcommands:
- `list` → `python -m tools.list`
- `doctor` → `python -m tools.doctor`
- (no `test` — tools aren't uniform prompt→completion; revisit if a `kind:cli` tool lands.)
Empty/unknown subcommand → print usage. Runs from the repo cwd (where `claude` is open).

### 6. bootstrap (`scripts/bootstrap.ps1`, `scripts/test-bootstrap.ps1`)

- New **Step 5b4**: deploy `references/tools.yaml` → `~/.claude/tools.yaml`
  (copy logic identical to 5b3's `fleet.yaml`, incl. the non-interactive keep-existing
  behavior).
- Add `'tools.md'` to the slash-commands deploy array.
- `test-bootstrap.ps1`: two dry-run-stdout assertions (`tools.yaml`, `tools.md`) — same
  shape as SP3's idea-lib/idea.md assertions (assert against dry-run stdout, **not**
  `Test-Path`, because dry-run writes nothing).

## Data flow

```
foo.pdf dropped under ~/.claude/knowledge/projects/<id>/...   (or universal/)
        │
   /kb-index  (incremental)
        │  _default_corpus_paths now includes *.pdf
        ▼
   changed (new mtime) → chunk_file(foo.pdf)
        │
   extract_to_text('.pdf') → tools_for_capability('pdf-extract', enabled_only=True)
        │                         │ none → ExtractorUnavailable (counted skip)
        │                         ▼ docling enabled
        │                    pdf_docling.extract_pdf → markdown string
        ▼
   chunk_text(markdown, source) → existing embed() → VectorStore.upsert
        ▼
   searchable via /kb-search + dashboard KB panel    (both unchanged)
```

Everything downstream of `chunk_text` — embedder, store, search, dashboard — is untouched.

## Error handling

| Condition | Behavior |
|---|---|
| Docling not installed | `ExtractorUnavailable` → skip file, `extractor_skips++`, record mtime, continue. `.md` unaffected. |
| Docling disabled / no enabled `pdf-extract` tool | `ExtractorUnavailable` → skip file, `extractor_skips++`, record mtime, continue (same path as not-installed — a PDF is never silently zero-chunked). |
| `tools.yaml` missing | `read_tools` → `[]` → PDFs skip cleanly. `.md` pipeline never breaks. |
| Corrupt / unconvertible PDF | `ExtractorError` → skip that file, `extractor_errors++`, record mtime, continue; exit code 2. |
| Skipped-because-unavailable PDF | mtime recorded → won't auto-retry until the file changes or `--full`. **Documented behavior.** |

## Testing

PowerShell smoke (`scripts/test-bootstrap.ps1`): dry-run stdout shows `tools.yaml` and
`tools.md` would deploy.

Python (`pytest`):

- `tools/tests/test_registry.py` — fixture `tools.yaml` parses to `ToolSpec`s; path
  precedence param > `$TOOLS_FILE` > default; `get_tool` hit/miss; `tools_for_capability`
  filters disabled out; missing file → `[]` (no raise).
- `tools/tests/test_doctor.py` — doctor over a fixture: `kind:python` importable→ok,
  missing-module→err (monkeypatch `find_spec`); disabled→skip; table printed; exit `1`
  on any err, `0` otherwise.
- `kb/tests/test_extractors.py` — dispatch: `.md`→text; `.txt`→text; unknown→`None`;
  `.pdf` with `extract_pdf` **monkeypatched**→text; with the import made to raise→
  `ExtractorUnavailable`; with `docling` disabled in a fixture registry→`ExtractorUnavailable`. Real
  Docling is **not** exercised in CI (optional heavy dep; same posture as SP3's `gh`).
- `kb/tests/test_chunker.py` — all existing assertions pass after the `chunk_text`/
  `chunk_file` split; add a direct `chunk_text` test (string in → chunks out).
- `kb/tests/test_index_incremental.py` — a `.pdf` fixture with `chunk_file`/extractor
  monkeypatched flows end-to-end (indexed, chunk count > 0); an unavailable-tool run
  bumps `extractor_skips` and records the mtime (second run skips it).

## Build order (TDD)

1. `tools/registry.py` (+ `tools/__init__.py`) + `test_registry.py`.
2. `references/tools.yaml` seed (Docling entry).
3. `tools/doctor.py` + `tools/list.py` + `test_doctor.py`.
4. `kb/extractors/` — `__init__.py` dispatch + exceptions, `pdf_docling.py` (lazy) + `test_extractors.py`.
5. `kb/chunker.py` — `chunk_text`/`chunk_file` split; existing tests stay green + direct `chunk_text` test.
6. `kb/index.py` — PDF discovery + skip/err handling + summary counts + `test_index_incremental.py` additions.
7. `commands/tools.md` (`/tools list|doctor`).
8. `scripts/bootstrap.ps1` Step 5b4 + commands array; `scripts/test-bootstrap.ps1` assertions.

## Success criteria

- A PDF dropped under the corpus is indexed and returned by `/kb-search` — with Docling
  installed — using zero Claude tokens.
- With Docling **not** installed, `/kb-index` skips the PDF with a clear message and the
  `.md` corpus indexes exactly as before (no regression).
- `/tools list` and `/tools doctor` show the registry and Docling's availability.
- `tools.yaml` + `tools.md` deploy via `bootstrap.ps1`.
- Full gate green: existing Python suite + new `tools/` + `kb/extractors` tests + 6 PS
  suites + bootstrap smoke.
