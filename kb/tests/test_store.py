from __future__ import annotations

from pathlib import Path

import numpy as np

from kb.store import VectorStore, Hit


def _norm(v: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(v, axis=1, keepdims=True)
    n = np.where(n == 0, 1.0, n)
    return v / n


def test_upsert_save_load_roundtrip(tmp_path: Path) -> None:
    st = VectorStore(tmp_path)
    rows = [
        {"source": "/a.md", "span": [0, 10], "text": "hello", "section": None},
        {"source": "/a.md", "span": [10, 20], "text": "world", "section": "intro"},
    ]
    vecs = _norm(np.array([[1, 0, 0, 0], [0, 1, 0, 0]], dtype=np.float32))
    st.upsert(rows, vecs)
    st.save()

    st2 = VectorStore(tmp_path)
    st2.load()
    assert len(st2.metadata) == 2
    assert st2.vectors.shape == (2, 4)
    assert st2.metadata[0]["text"] == "hello"


def test_upsert_idempotent_on_key(tmp_path: Path) -> None:
    st = VectorStore(tmp_path)
    rows = [{"source": "/a.md", "span": [0, 10], "text": "v1", "section": None}]
    v1 = _norm(np.array([[1, 0, 0, 0]], dtype=np.float32))
    st.upsert(rows, v1)
    # Re-upsert same key with new text + new vector
    rows2 = [{"source": "/a.md", "span": [0, 10], "text": "v2", "section": None}]
    v2 = _norm(np.array([[0, 1, 0, 0]], dtype=np.float32))
    st.upsert(rows2, v2)
    assert len(st.metadata) == 1
    assert st.metadata[0]["text"] == "v2"


def test_remove_source(tmp_path: Path) -> None:
    st = VectorStore(tmp_path)
    rows = [
        {"source": "/a.md", "span": [0, 10], "text": "a1", "section": None},
        {"source": "/a.md", "span": [10, 20], "text": "a2", "section": None},
        {"source": "/b.md", "span": [0, 10], "text": "b1", "section": None},
    ]
    vecs = _norm(np.eye(3, 4, dtype=np.float32))
    st.upsert(rows, vecs)
    removed = st.remove_source("/a.md")
    assert removed == 2
    assert len(st.metadata) == 1
    assert st.metadata[0]["source"] == "/b.md"
    assert st.vectors.shape == (1, 4)


def test_search_returns_topk_sorted(tmp_path: Path) -> None:
    st = VectorStore(tmp_path)
    # Vectors aligned to a clear preference axis
    vecs = _norm(np.array([
        [1.0, 0.0],
        [0.9, 0.1],
        [0.0, 1.0],
        [-1.0, 0.0],
    ], dtype=np.float32))
    rows = [
        {"source": "/a.md", "span": [0, 1], "text": "best", "section": None},
        {"source": "/b.md", "span": [0, 1], "text": "second", "section": None},
        {"source": "/c.md", "span": [0, 1], "text": "off-axis", "section": None},
        {"source": "/d.md", "span": [0, 1], "text": "opposite", "section": None},
    ]
    st.upsert(rows, vecs)
    q = np.array([1.0, 0.0], dtype=np.float32)
    hits = st.search(q, k=3)
    assert [h.text for h in hits] == ["best", "second", "off-axis"]
    assert hits[0].score > hits[1].score > hits[2].score


def test_search_scope_filter_universal_vs_project(tmp_path: Path) -> None:
    st = VectorStore(tmp_path)
    rows = [
        {"source": "/home/u/.claude/knowledge/universal/routing.md", "span": [0, 5], "text": "uni", "section": None},
        {"source": "/home/u/.claude/knowledge/projects/myproj/decisions/d001.md", "span": [0, 5], "text": "proj", "section": None},
    ]
    vecs = _norm(np.array([[1, 0], [0.99, 0.1]], dtype=np.float32))
    st.upsert(rows, vecs)
    q = np.array([1, 0], dtype=np.float32)
    hits = st.search(q, k=5, scope_filter="universal")
    assert len(hits) == 1
    assert hits[0].text == "uni"
    hits2 = st.search(q, k=5, scope_filter="myproj")
    assert len(hits2) == 1
    assert hits2[0].text == "proj"


def test_empty_store_search(tmp_path: Path) -> None:
    st = VectorStore(tmp_path)
    q = np.array([1.0, 0.0], dtype=np.float32)
    assert st.search(q, k=3) == []
