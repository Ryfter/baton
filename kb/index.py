"""CLI entry: python -m kb.index [--full] [--scope ...] [--file ...] [--corpus-root ...] [--index-dir ...]

Walks the corpus, chunks files, embeds chunks, upserts into the vector store.
Default mode is incremental (mtime-based); --full rebuilds from scratch.
"""
from __future__ import annotations

import argparse
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from kb.chunker import chunk_file
from kb.embedder import DEFAULT_MODEL, embed, EmbedError
from kb.extractors import ExtractorUnavailable, ExtractorError
from kb.store import VectorStore


def _default_corpus_paths(corpus_root: Path, jobs_root: Path) -> list[Path]:
    """Return every file that should be indexed (full enumeration)."""
    files: list[Path] = []
    _CORPUS_GLOBS = ("*.md", "*.pdf")
    # Universal KB
    uni = corpus_root / "universal"
    if uni.exists():
        for glob in _CORPUS_GLOBS:
            files.extend(p for p in uni.rglob(glob) if p.is_file())
    # Per-project KB (incl. decisions/, decision-guidance.md, cost.md, etc.)
    projs = corpus_root / "projects"
    if projs.exists():
        for project_dir in projs.iterdir():
            if not project_dir.is_dir():
                continue
            for glob in _CORPUS_GLOBS:
                files.extend(p for p in project_dir.rglob(glob) if p.is_file())
    # Job lessons.md
    if jobs_root.exists():
        for job_dir in jobs_root.iterdir():
            if not job_dir.is_dir():
                continue
            lesson = job_dir / "lessons.md"
            if lesson.exists():
                files.append(lesson)
    return files


def _filter_by_scope(files: list[Path], scope: str | None) -> list[Path]:
    if not scope or scope == "all":
        return files
    out: list[Path] = []
    s = scope.lower()
    for p in files:
        norm = str(p.resolve()).replace("\\", "/").lower()
        if s == "universal":
            if "/knowledge/universal/" in norm:
                out.append(p)
        else:
            if f"/knowledge/projects/{s}/" in norm:
                out.append(p)
    return out


def _is_under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _mtime_iso(p: Path) -> str:
    return datetime.fromtimestamp(p.stat().st_mtime, tz=timezone.utc).astimezone().isoformat()


def run_index(
    *,
    corpus_root: Path,
    jobs_root: Path,
    index_dir: Path,
    full: bool = False,
    scope: str | None = None,
    single_file: Path | None = None,
    model: str = DEFAULT_MODEL,
    host: str | None = None,
    print_progress: bool = True,
) -> dict:
    """Returns a summary dict (also useful for tests)."""
    t0 = time.monotonic()
    store = VectorStore(index_dir)
    if not full:
        store.load()

    if full:
        # Start from a clean slate
        store.vectors = store.vectors[:0] if store.vectors.size else store.vectors
        store.metadata = []
        store.manifest["source_mtimes"] = {}
        if model:
            store.manifest["model"] = model

    if single_file is not None:
        target = single_file.resolve()
        if not (_is_under(target, corpus_root) or _is_under(target, jobs_root)):
            raise ValueError(f"--file must be under {corpus_root} or {jobs_root}: {target}")
        all_files = [target] if target.exists() and target.is_file() else []
    else:
        all_files = _default_corpus_paths(corpus_root, jobs_root)
        all_files = _filter_by_scope(all_files, scope)
    current_paths = {str(p.resolve()) for p in all_files}
    tracked_paths = set(store.manifest.get("source_mtimes", {}).keys())

    # 1. Remove sources that no longer exist
    if single_file is not None:
        target_src = str(single_file.resolve())
        removed_sources = {target_src} if target_src in tracked_paths and target_src not in current_paths else set()
    else:
        removed_sources = tracked_paths - current_paths
    rows_removed = 0
    for src in removed_sources:
        rows_removed += store.remove_source(src)
        store.forget_source(src)

    # 2. Identify changed + new
    changed_files: list[Path] = []
    skipped = 0
    for p in all_files:
        src = str(p.resolve())
        cur_mtime = _mtime_iso(p)
        recorded = store.manifest.get("source_mtimes", {}).get(src)
        if recorded == cur_mtime and not full:
            skipped += 1
            continue
        changed_files.append(p)

    # 3. Re-chunk + re-embed each changed file
    total_chunks = 0
    embed_calls = 0
    files_indexed = 0
    embed_errors: list[str] = []
    extractor_skips = 0
    extractor_errors: list[str] = []
    for p in changed_files:
        src = str(p.resolve())
        # Drop any prior rows for this source before reinserting
        store.remove_source(src)
        try:
            chunks = chunk_file(p)
        except ExtractorUnavailable as e:
            extractor_skips += 1
            store.record_source_mtime(src, _mtime_iso(p))
            if print_progress:
                print(f"  ~ skipped (tool unavailable): {p.name} ({e})")
            continue
        except ExtractorError as e:
            extractor_errors.append(f"{src}: {e}")
            store.record_source_mtime(src, _mtime_iso(p))
            if print_progress:
                print(f"  ! extract failed for {src}: {e}", file=sys.stderr)
            continue
        if not chunks:
            store.record_source_mtime(src, _mtime_iso(p))
            continue
        try:
            vectors = embed([c.text for c in chunks], model=model, host=host) if host else embed([c.text for c in chunks], model=model)
        except EmbedError as e:
            embed_errors.append(f"{src}: {e}")
            if print_progress:
                print(f"  ! embed failed for {src}: {e}", file=sys.stderr)
            continue
        rows = [
            {
                "source": c.source,
                "span": list(c.span),
                "text": c.text,
                "section": c.section,
                "mtime": _mtime_iso(p),
            }
            for c in chunks
        ]
        store.upsert(rows, vectors)
        store.record_source_mtime(src, _mtime_iso(p))
        total_chunks += len(chunks)
        embed_calls += len(chunks)
        files_indexed += 1
        if print_progress:
            print(f"  + {p.name}  ({len(chunks)} chunks)")

    store.manifest["model"] = model
    store.save()

    elapsed = time.monotonic() - t0
    summary = {
        "files_seen": len(all_files),
        "files_indexed": files_indexed,
        "files_skipped": skipped,
        "files_removed": len(removed_sources),
        "chunks_added": total_chunks,
        "rows_removed": rows_removed,
        "embed_calls": embed_calls,
        "embed_errors": embed_errors,
        "extractor_skips": extractor_skips,
        "extractor_errors": extractor_errors,
        "elapsed_s": round(elapsed, 2),
        "total_rows": len(store.metadata),
    }
    if print_progress:
        print(
            f"\nIndexed {files_indexed}/{len(all_files)} files "
            f"({skipped} unchanged, {len(removed_sources)} removed). "
            f"{total_chunks} chunks added. Store now has {summary['total_rows']} rows. "
            f"{elapsed:.2f}s."
        )
        if embed_errors:
            print(f"  {len(embed_errors)} embed error(s) — see above.", file=sys.stderr)
    return summary


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="python -m kb.index")
    p.add_argument("--full", action="store_true", help="Rebuild from scratch (default: incremental)")
    p.add_argument("--scope", default=None, help="all | universal | <project-id>")
    p.add_argument("--file", default=None, help="Index exactly one changed file")
    p.add_argument("--corpus-root", default=str(Path.home() / ".claude" / "knowledge"))
    p.add_argument("--jobs-root", default=str(Path.home() / ".claude" / "jobs"))
    p.add_argument("--index-dir", default=str(Path.home() / ".claude" / "knowledge" / ".index"))
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--host", default=None)
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args(argv)
    if args.full and args.file:
        p.error("--file cannot be combined with --full")
    if args.scope and args.file:
        p.error("--file cannot be combined with --scope")
    summary = run_index(
        corpus_root=Path(args.corpus_root),
        jobs_root=Path(args.jobs_root),
        index_dir=Path(args.index_dir),
        full=args.full,
        scope=args.scope,
        single_file=Path(args.file) if args.file else None,
        model=args.model,
        host=args.host,
        print_progress=not args.quiet,
    )
    return 0 if not (summary["embed_errors"] or summary["extractor_errors"]) else 2


if __name__ == "__main__":
    raise SystemExit(main())
