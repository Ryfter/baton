"""Ollama HTTP embedder. Returns L2-normalised float32 vectors."""
from __future__ import annotations

import os
from typing import Iterable

import httpx
import numpy as np

DEFAULT_MODEL = "nomic-embed-text"
EMBED_PATH = "/api/embeddings"


def _normalize_host(raw: str | None) -> str:
    """Accept any of: 'http://host:port', 'host:port', 'host', '0.0.0.0',
    or unset → return a fully-qualified base URL.

    The OLLAMA_HOST env var is sometimes set to the server's bind address
    (e.g. '0.0.0.0' or '127.0.0.1') without a scheme, which httpx rejects."""
    v = (raw or "").strip()
    if not v:
        return "http://localhost:11434"
    if v.startswith("http://") or v.startswith("https://"):
        return v
    # Bare host or host:port — assume http
    if ":" not in v:
        v = f"{v}:11434"
    # 0.0.0.0 means "listen on any" server-side — useless as a client target,
    # so resolve to localhost for outbound requests.
    if v.startswith("0.0.0.0"):
        v = "127.0.0.1" + v[len("0.0.0.0"):]
    return f"http://{v}"


DEFAULT_HOST = _normalize_host(os.environ.get("OLLAMA_HOST"))


class EmbedError(RuntimeError):
    """Raised when the Ollama embeddings call fails."""


def embed(
    texts: Iterable[str],
    *,
    model: str = DEFAULT_MODEL,
    host: str = DEFAULT_HOST,
    timeout: float = 30.0,
) -> np.ndarray:
    """Embed each text via Ollama; return (N, D) float32 L2-normalised matrix.

    Empty inputs raise; whitespace-only items embed as zeros (and stay zero).
    """
    items = list(texts)
    if not items:
        raise EmbedError("embed() called with no texts.")
    vectors: list[np.ndarray] = []
    base = _normalize_host(host).rstrip("/")
    with httpx.Client(timeout=timeout) as client:
        for t in items:
            payload = {"model": model, "prompt": t if t.strip() else " "}
            try:
                r = client.post(base + EMBED_PATH, json=payload)
                r.raise_for_status()
            except httpx.HTTPError as e:
                raise EmbedError(f"Ollama embed call failed: {e}") from e
            data = r.json()
            v = data.get("embedding")
            if not v or not isinstance(v, list):
                raise EmbedError(f"Ollama returned no 'embedding' field for input (len {len(t)}).")
            vectors.append(np.asarray(v, dtype=np.float32))

    dim = vectors[0].shape[0]
    if any(v.shape[0] != dim for v in vectors):
        raise EmbedError("Embedding dimension changed mid-batch — model misconfiguration?")

    mat = np.stack(vectors, axis=0).astype(np.float32, copy=False)
    # L2-normalise so search reduces to a dot product
    norms = np.linalg.norm(mat, axis=1, keepdims=True)
    norms = np.where(norms == 0, 1.0, norms)
    mat = mat / norms
    return mat
