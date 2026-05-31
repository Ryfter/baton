"""Shared test fixtures for kb/."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest


@pytest.fixture(autouse=True)
def _no_network(monkeypatch):
    """Default: any test calling kb.embedder.embed without overriding hits a
    fake that returns deterministic dummy vectors. Tests can override by
    monkey-patching their own fake in.

    The fake returns vectors whose first dim is the text length (mod 17)
    and the rest are deterministic — enough variation that distinct texts
    get distinct vectors, but no network needed."""
    def fake_embed(texts, *, model="x", host=None, timeout=30.0):
        out = []
        for t in texts:
            v = np.zeros(8, dtype=np.float32)
            for i, c in enumerate(t[:8]):
                v[i] = (ord(c) % 17) / 17.0
            v[0] = (len(t) % 17) / 17.0
            n = float(np.linalg.norm(v))
            if n == 0:
                v[0] = 1.0
                n = 1.0
            out.append(v / n)
        return np.stack(out, axis=0).astype(np.float32)

    import kb.embedder
    monkeypatch.setattr(kb.embedder, "embed", fake_embed)
    # Also patch the references already imported into index/search at module load
    import kb.index
    import kb.search
    monkeypatch.setattr(kb.index, "embed", fake_embed)
    monkeypatch.setattr(kb.search, "embed", fake_embed)
    yield
