"""Tests for dashboard/routers/kb.py."""
from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import numpy as np
from fastapi.testclient import TestClient

from dashboard.main import app
from kb.store import VectorStore


def _seed_index(tmp_path: Path) -> Path:
    """Build a tiny index by direct VectorStore upsert (skip live Ollama)."""
    idx = tmp_path / "kb" / ".index"
    st = VectorStore(idx)
    rows = [
        {"source": "/k/u/routing.md", "span": [0, 10], "text": "routing rules", "section": "Routing"},
        {"source": "/k/p/x/decisions/d001.md", "span": [0, 10], "text": "cost ledger", "section": "Cost"},
    ]
    vecs = np.array([[1.0, 0.0], [0.0, 1.0]], dtype=np.float32)
    norms = np.linalg.norm(vecs, axis=1, keepdims=True)
    vecs = vecs / np.where(norms == 0, 1.0, norms)
    st.manifest["dim"] = 2
    st.manifest["model"] = "fake"
    st.upsert(rows, vecs)
    st.save()
    return tmp_path / "kb"


def _fake_embed(texts, *, model="x", host=None, timeout=30.0):
    """Return a unit vector pointing along axis 0 — so query matches the
    'routing rules' row best."""
    out = np.zeros((len(list(texts)), 2), dtype=np.float32)
    out[:, 0] = 1.0
    return out


def test_kb_search_json_empty_query(tmp_path: Path) -> None:
    app.state.kb_root = _seed_index(tmp_path)
    client = TestClient(app)
    r = client.get("/kb/search")
    assert r.status_code == 200
    body = r.json()
    assert body["hits"] == []
    assert body["query"] == ""


def test_kb_search_json_with_query(tmp_path: Path) -> None:
    app.state.kb_root = _seed_index(tmp_path)
    with patch("kb.search.embed", side_effect=_fake_embed):
        client = TestClient(app)
        r = client.get("/kb/search?q=routing&k=2")
        assert r.status_code == 200
        body = r.json()
        assert body["error"] is None
        assert len(body["hits"]) == 2
        assert body["hits"][0]["text"] == "routing rules"


def test_kb_search_partial_renders(tmp_path: Path) -> None:
    app.state.kb_root = _seed_index(tmp_path)
    with patch("kb.search.embed", side_effect=_fake_embed):
        client = TestClient(app)
        r = client.get("/partials/kb-search?q=routing&k=2")
        assert r.status_code == 200
        assert "routing rules" in r.text
        assert "KB Search" in r.text


def test_kb_search_partial_empty_query_initial(tmp_path: Path) -> None:
    app.state.kb_root = _seed_index(tmp_path)
    client = TestClient(app)
    r = client.get("/partials/kb-search")
    assert r.status_code == 200
    assert "Type a query above" in r.text


def test_home_page_renders_with_kb_panel(tmp_path: Path) -> None:
    """Sanity: home page still renders 200 after adding the KB include."""
    app.state.kb_root = _seed_index(tmp_path)
    client = TestClient(app)
    r = client.get("/")
    assert r.status_code == 200
    assert "KB Search" in r.text


# --- Plan 8.3 (#18): decision click-through ---

from dashboard.routers.kb import is_decision_path


def test_is_decision_path() -> None:
    assert is_decision_path("/k/p/x/decisions/d001-foo.md")
    assert is_decision_path("C:\\k\\p\\x\\decisions\\d007.md")
    assert not is_decision_path("/k/universal/routing.md")
    assert not is_decision_path("/k/p/x/decisions/notes.md")  # not d*.md
    assert not is_decision_path("")


def _write_decision(kb_root: Path) -> Path:
    d = kb_root / "projects" / "x" / "decisions"
    d.mkdir(parents=True, exist_ok=True)
    f = d / "d001-cost-ledger.md"
    f.write_text("# Decision d001\n\n**Chosen:** per-project cost.md\n", encoding="utf-8")
    return f


def test_decision_detail_renders_valid(tmp_path: Path) -> None:
    app.state.kb_root = tmp_path
    f = _write_decision(tmp_path)
    client = TestClient(app)
    r = client.get("/partials/decision", params={"path": str(f)})
    assert r.status_code == 200
    assert "d001-cost-ledger.md" in r.text
    assert "per-project cost.md" in r.text


def test_decision_detail_rejects_out_of_scope(tmp_path: Path) -> None:
    app.state.kb_root = tmp_path / "kb_root"
    (tmp_path / "kb_root").mkdir()
    # A real file that is OUTSIDE the kb_root and not a decision record.
    outside = tmp_path / "secret.md"
    outside.write_text("top secret", encoding="utf-8")
    client = TestClient(app)
    r = client.get("/partials/decision", params={"path": str(outside)})
    assert r.status_code == 200
    assert "Not a valid decision record" in r.text
    assert "top secret" not in r.text
