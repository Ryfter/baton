"""CLI entry: python -m kb.search "<query>" [--k N] [--scope ...] [--json]"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path

from kb.embedder import DEFAULT_MODEL, embed, EmbedError
from kb.store import VectorStore


def run_search(
    query: str,
    *,
    index_dir: Path,
    k: int = 5,
    scope: str | None = None,
    model: str = DEFAULT_MODEL,
    host: str | None = None,
) -> list[dict]:
    store = VectorStore(index_dir)
    store.load()
    if store.vectors.size == 0:
        return []
    if not query.strip():
        return []
    qvec = embed([query], model=model, host=host) if host else embed([query], model=model)
    hits = store.search(qvec[0], k=k, scope_filter=scope)
    return [
        {
            "score": round(h.score, 4),
            "source": h.source,
            "span_start": h.span[0],
            "span_end": h.span[1],
            "section": h.section,
            "text": h.text,
        }
        for h in hits
    ]


def _print_pretty(hits: list[dict], snippet_chars: int = 200) -> None:
    if not hits:
        print("(no hits)")
        return
    for h in hits:
        head = f"[{h['score']:.3f}]  {h['source']}  ({h['span_start']}-{h['span_end']})"
        if h.get("section"):
            head += f"  § {h['section']}"
        print(head)
        snippet = (h["text"] or "").strip().replace("\n", " ")
        if len(snippet) > snippet_chars:
            snippet = snippet[:snippet_chars] + "…"
        print(f"   {snippet}\n")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="python -m kb.search")
    p.add_argument("query", help="Search query (quote it)")
    p.add_argument("--k", type=int, default=5)
    p.add_argument("--scope", default=None, help="all | universal | <project-id>")
    p.add_argument("--index-dir", default=str(Path.home() / ".claude" / "knowledge" / ".index"))
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--host", default=None)
    p.add_argument("--json", action="store_true", help="Emit JSON array (for /research)")
    p.add_argument("--snippet-chars", type=int, default=200)
    args = p.parse_args(argv)

    try:
        hits = run_search(
            args.query,
            index_dir=Path(args.index_dir),
            k=args.k,
            scope=args.scope,
            model=args.model,
            host=args.host,
        )
    except EmbedError as e:
        print(f"embed failed: {e}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(hits, indent=2))
    else:
        _print_pretty(hits, snippet_chars=args.snippet_chars)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
