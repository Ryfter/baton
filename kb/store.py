"""Flat-search vector store. Numpy .npz of vectors + JSON of metadata + manifest."""
from __future__ import annotations

import json
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import numpy as np

VECTORS_FILE = "vectors.npz"
METADATA_FILE = "metadata.json"
MANIFEST_FILE = "manifest.json"


@dataclass
class Hit:
    score: float
    source: str
    span: tuple[int, int]
    text: str
    section: Optional[str]


class VectorStore:
    """Single-directory flat-search store. Vectors are L2-normalised at upsert
    time (or assumed pre-normalised when written by the embedder), so cosine
    similarity reduces to a dot product."""

    def __init__(self, index_dir: Path):
        self.index_dir = Path(index_dir)
        self.vectors: np.ndarray = np.zeros((0, 0), dtype=np.float32)
        self.metadata: list[dict] = []
        self.manifest: dict = {
            "version": 1,
            "model": None,
            "dim": 0,
            "last_index_at": None,
            "source_mtimes": {},
        }

    # ---- IO ----

    def load(self) -> None:
        v_path = self.index_dir / VECTORS_FILE
        m_path = self.index_dir / METADATA_FILE
        f_path = self.index_dir / MANIFEST_FILE
        if v_path.exists():
            with np.load(v_path) as npz:
                self.vectors = npz["vectors"].astype(np.float32, copy=False)
        if m_path.exists():
            self.metadata = json.loads(m_path.read_text(encoding="utf-8"))
        if f_path.exists():
            self.manifest = json.loads(f_path.read_text(encoding="utf-8"))
        # Mutual consistency sanity (best-effort; don't crash on mismatch)
        if self.vectors.shape[0] != len(self.metadata):
            # Trust metadata — truncate vectors to match
            n = min(self.vectors.shape[0], len(self.metadata))
            self.vectors = self.vectors[:n]
            self.metadata = self.metadata[:n]

    def save(self) -> None:
        self.index_dir.mkdir(parents=True, exist_ok=True)
        v_path = self.index_dir / VECTORS_FILE
        m_path = self.index_dir / METADATA_FILE
        f_path = self.index_dir / MANIFEST_FILE
        if self.vectors.size:
            np.savez(v_path, vectors=self.vectors)
        else:
            # Save an empty matrix shape (0, dim) so dim survives reloads
            dim = self.manifest.get("dim", 0) or 0
            np.savez(v_path, vectors=np.zeros((0, dim), dtype=np.float32))
        m_path.write_text(json.dumps(self.metadata, indent=2), encoding="utf-8")
        self.manifest["last_index_at"] = datetime.now(timezone.utc).astimezone().isoformat()
        f_path.write_text(json.dumps(self.manifest, indent=2), encoding="utf-8")

    # ---- mutations ----

    def _row_key(self, row: dict) -> tuple[str, int, int]:
        return (row["source"], int(row["span"][0]), int(row["span"][1]))

    def upsert(self, rows: list[dict], vectors: np.ndarray) -> int:
        """Insert or replace rows by (source, span). Returns count added/replaced.

        `vectors` must have shape (len(rows), dim) and be L2-normalised already.
        """
        if vectors.shape[0] != len(rows):
            raise ValueError("upsert: vectors row count != rows count")
        if vectors.size == 0:
            return 0
        dim = vectors.shape[1]
        if self.manifest.get("dim", 0) == 0:
            self.manifest["dim"] = int(dim)
        elif dim != self.manifest["dim"]:
            raise ValueError(
                f"upsert: vector dim {dim} != store dim {self.manifest['dim']}"
            )

        # Build existing index by row key
        existing_keys: dict[tuple[str, int, int], int] = {
            self._row_key(r): i for i, r in enumerate(self.metadata)
        }
        # Apply
        new_rows: list[dict] = list(self.metadata)
        if self.vectors.size:
            new_vectors = self.vectors.copy()
        else:
            new_vectors = np.zeros((0, dim), dtype=np.float32)
        for i, row in enumerate(rows):
            key = self._row_key(row)
            vec = vectors[i:i + 1]
            if key in existing_keys:
                idx = existing_keys[key]
                new_rows[idx] = row
                new_vectors[idx] = vec[0]
            else:
                existing_keys[key] = len(new_rows)
                new_rows.append(row)
                new_vectors = np.concatenate([new_vectors, vec], axis=0)
        self.metadata = new_rows
        self.vectors = new_vectors
        return len(rows)

    def remove_source(self, source: str) -> int:
        """Drop all rows whose source matches. Returns count removed."""
        if not self.metadata:
            return 0
        keep_idx = [i for i, r in enumerate(self.metadata) if r["source"] != source]
        removed = len(self.metadata) - len(keep_idx)
        if removed == 0:
            return 0
        self.metadata = [self.metadata[i] for i in keep_idx]
        self.vectors = self.vectors[keep_idx] if self.vectors.size else self.vectors
        return removed

    def record_source_mtime(self, source: str, mtime_iso: str) -> None:
        self.manifest.setdefault("source_mtimes", {})[source] = mtime_iso

    def forget_source(self, source: str) -> None:
        """Remove a source from the mtime manifest (paired with remove_source)."""
        self.manifest.get("source_mtimes", {}).pop(source, None)

    # ---- query ----

    def search(
        self,
        query_vec: np.ndarray,
        k: int = 5,
        *,
        scope_filter: Optional[str] = None,
        active_project: Optional[str] = None,
        active_project_score_boost: float = 0.0,
    ) -> list[Hit]:
        """Return top-k Hit by cosine similarity. `query_vec` shape (D,) or (1, D)."""
        if self.vectors.size == 0:
            return []
        q = query_vec.reshape(-1)
        if q.shape[0] != self.vectors.shape[1]:
            raise ValueError(
                f"query_vec dim {q.shape[0]} != store dim {self.vectors.shape[1]}"
            )
        # Vectors and query are L2-normalised → cosine == dot product
        scores = self.vectors @ q
        if active_project and active_project_score_boost > 0:
            for i, row in enumerate(self.metadata):
                if _project_matches(row["source"], active_project):
                    scores[i] += active_project_score_boost
        # Apply scope filter
        if scope_filter:
            allowed = [
                i for i, r in enumerate(self.metadata)
                if _scope_matches(r["source"], scope_filter)
            ]
            if not allowed:
                return []
            allowed_arr = np.asarray(allowed)
            sub_scores = scores[allowed_arr]
            top = np.argsort(-sub_scores)[:k]
            picks = [(allowed_arr[i], float(sub_scores[i])) for i in top]
        else:
            top = np.argsort(-scores)[:k]
            picks = [(int(i), float(scores[i])) for i in top]
        hits: list[Hit] = []
        for idx, score in picks:
            row = self.metadata[idx]
            hits.append(Hit(
                score=score,
                source=row["source"],
                span=tuple(row["span"]),
                text=row.get("text", ""),
                section=row.get("section"),
            ))
        return hits


def _scope_matches(source: str, scope: str) -> bool:
    """A source matches scope='universal' if it sits under knowledge/universal/;
    matches scope=<project-id> if under knowledge/projects/<project-id>/;
    matches scope='all' or empty always."""
    if not scope or scope == "all":
        return True
    s = source.replace("\\", "/").lower()
    scope_l = scope.lower()
    if scope_l == "universal":
        return "/knowledge/universal/" in s
    return f"/knowledge/projects/{scope_l}/" in s


def _project_matches(source: str, project_id: str) -> bool:
    if not project_id:
        return False
    s = source.replace("\\", "/").lower()
    project_l = project_id.lower()
    return f"/knowledge/projects/{project_l}/" in s
