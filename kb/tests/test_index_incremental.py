from __future__ import annotations

import os
import time
from pathlib import Path

from kb.index import run_index
from kb.store import VectorStore


def _setup_corpus(tmp_path: Path) -> dict[str, Path]:
    kb = tmp_path / "knowledge"
    jobs = tmp_path / "jobs"
    (kb / "universal").mkdir(parents=True)
    (kb / "projects" / "alpha").mkdir(parents=True)
    (kb / "universal" / "routing.md").write_text(
        "# Routing\n\nAlpha rules for routing.", encoding="utf-8"
    )
    (kb / "projects" / "alpha" / "decision-guidance.md").write_text(
        "# Alpha\n\nUse Rust for speed-sensitive paths.", encoding="utf-8"
    )
    return {"kb": kb, "jobs": jobs}


def test_initial_full_index_records_mtimes(tmp_path: Path) -> None:
    paths = _setup_corpus(tmp_path)
    idx = tmp_path / "index"
    summary = run_index(
        corpus_root=paths["kb"], jobs_root=paths["jobs"], index_dir=idx,
        full=True, print_progress=False,
    )
    assert summary["files_indexed"] == 2
    assert summary["chunks_added"] >= 2
    st = VectorStore(idx); st.load()
    assert len(st.manifest["source_mtimes"]) == 2


def test_incremental_unchanged_corpus_is_noop(tmp_path: Path) -> None:
    paths = _setup_corpus(tmp_path)
    idx = tmp_path / "index"
    run_index(corpus_root=paths["kb"], jobs_root=paths["jobs"], index_dir=idx,
              full=True, print_progress=False)
    summary2 = run_index(
        corpus_root=paths["kb"], jobs_root=paths["jobs"], index_dir=idx,
        full=False, print_progress=False,
    )
    assert summary2["files_indexed"] == 0
    assert summary2["embed_calls"] == 0
    assert summary2["files_skipped"] == 2


def test_incremental_picks_up_changed_file(tmp_path: Path) -> None:
    paths = _setup_corpus(tmp_path)
    idx = tmp_path / "index"
    run_index(corpus_root=paths["kb"], jobs_root=paths["jobs"], index_dir=idx,
              full=True, print_progress=False)
    # Modify one file — bump mtime explicitly to guarantee detection on FAT-precision filesystems
    target = paths["kb"] / "universal" / "routing.md"
    target.write_text("# Routing\n\nNEW content for Alpha routing rules.", encoding="utf-8")
    future = time.time() + 5
    os.utime(target, (future, future))
    summary = run_index(
        corpus_root=paths["kb"], jobs_root=paths["jobs"], index_dir=idx,
        full=False, print_progress=False,
    )
    assert summary["files_indexed"] == 1
    assert summary["files_skipped"] == 1


def test_incremental_drops_deleted_file(tmp_path: Path) -> None:
    paths = _setup_corpus(tmp_path)
    idx = tmp_path / "index"
    run_index(corpus_root=paths["kb"], jobs_root=paths["jobs"], index_dir=idx,
              full=True, print_progress=False)
    # Delete one file
    (paths["kb"] / "universal" / "routing.md").unlink()
    summary = run_index(
        corpus_root=paths["kb"], jobs_root=paths["jobs"], index_dir=idx,
        full=False, print_progress=False,
    )
    assert summary["files_removed"] == 1
    assert summary["rows_removed"] >= 1
    st = VectorStore(idx); st.load()
    sources = {r["source"] for r in st.metadata}
    assert all("routing.md" not in s for s in sources)


def test_scope_filter_universal_excludes_projects(tmp_path: Path) -> None:
    paths = _setup_corpus(tmp_path)
    idx = tmp_path / "index"
    summary = run_index(
        corpus_root=paths["kb"], jobs_root=paths["jobs"], index_dir=idx,
        full=True, scope="universal", print_progress=False,
    )
    assert summary["files_indexed"] == 1
    st = VectorStore(idx); st.load()
    sources = {r["source"] for r in st.metadata}
    assert all("/universal/" in s.replace("\\", "/") for s in sources)
