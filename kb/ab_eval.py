"""A/B evaluation of embedding models for KB retrieval (Plan / issue #24).

Builds a FULL index per candidate model into an isolated temp dir, runs a labeled
query set against each, and reports hit@1 / hit@k / MRR + latency — so the decision
to keep or swap the default embedding model is data-driven rather than a guess.

Pure metric helpers (`rank_of`, `metrics`) take plain hit dicts and need no Ollama,
so they are unit-tested directly. `eval_model` does the live indexing/search.

CLI:
    python -m kb.ab_eval --models nomic-embed-text mxbai-embed-large --k 3
"""
from __future__ import annotations

import argparse
import json
import statistics
import tempfile
import time
from pathlib import Path

from kb.embedder import DEFAULT_MODEL
from kb.index import run_index
from kb.search import run_search

# Labeled query set keyed to this repo's KB (decision records, cost, routing).
# `expect` is a case-insensitive substring expected in a relevant hit's source path.
DEFAULT_QUERIES: list[dict] = [
    {"q": "per-project cost ledger with a slash command", "expect": "d001"},
    {"q": "six thinking hats parallel role dispatch preset", "expect": "d002"},
    {"q": "llm council two rounds peer critique quorum", "expect": "d003"},
    {"q": "code phase worktree isolation cherry-pick merge", "expect": "d004"},
    {"q": "read-only multi-project command center dashboard", "expect": "d005"},
    {"q": "local ollama embeddings numpy flat search", "expect": "d006"},
    {"q": "fleet model performance bench tracking on the board", "expect": "d007"},
    {"q": "hard merge gate worktree isolation unattended dispatch", "expect": "d008"},
    {"q": "only agentic CLIs drive implementation text models review", "expect": "d009"},
    {"q": "development branches merge back to main gemini design reviewer", "expect": "d010"},
]


def rank_of(hits: list[dict], expect: str) -> int | None:
    """1-based rank of the first hit whose source contains `expect`, else None."""
    for i, h in enumerate(hits, 1):
        if expect.lower() in str(h.get("source", "")).lower():
            return i
    return None


def metrics(ranks: list[int | None], k: int) -> dict:
    """Aggregate retrieval metrics over per-query ranks (None = not in top-k)."""
    n = len(ranks)
    found = [r for r in ranks if r is not None]
    hit1 = sum(1 for r in found if r == 1)
    hitk = sum(1 for r in found if r <= k)
    mrr = (sum(1.0 / r for r in found) / n) if n else 0.0
    return {
        "n": n,
        "hit@1": hit1,
        f"hit@{k}": hitk,
        "mrr": round(mrr, 4),
    }


def eval_model(
    model: str,
    *,
    corpus_root: Path,
    jobs_root: Path,
    queries: list[dict],
    k: int,
    host: str | None = None,
) -> dict:
    """Build a full index with `model`, run every query, collect ranks + latency."""
    with tempfile.TemporaryDirectory(prefix=f"kb-ab-{model.replace('/', '_')}-") as td:
        index_dir = Path(td) / "index"
        t0 = time.monotonic()
        run_index(
            corpus_root=corpus_root, jobs_root=jobs_root, index_dir=index_dir,
            full=True, model=model, host=host, print_progress=False,
        )
        build_s = time.monotonic() - t0

        per_query: list[dict] = []
        latencies: list[float] = []
        for item in queries:
            t1 = time.monotonic()
            hits = run_search(item["q"], index_dir=index_dir, k=k, model=model, host=host)
            latencies.append(time.monotonic() - t1)
            per_query.append({
                "q": item["q"],
                "expect": item["expect"],
                "rank": rank_of(hits, item["expect"]),
                "top_source": (Path(hits[0]["source"]).name if hits else None),
            })

    ranks = [r["rank"] for r in per_query]
    return {
        "model": model,
        "build_s": round(build_s, 2),
        "mean_query_s": round(statistics.mean(latencies), 3) if latencies else 0.0,
        "metrics": metrics(ranks, k),
        "per_query": per_query,
    }


def _winner(results: list[dict]) -> dict:
    """Pick the best model by (MRR, then hit@k, then lower mean query latency)."""
    def key(r):
        m = r["metrics"]
        hitk = next(v for kk, v in m.items() if kk.startswith("hit@") and kk != "hit@1")
        return (m["mrr"], hitk, -r["mean_query_s"])
    return max(results, key=key)


def run_ab(models: list[str], *, corpus_root: Path, jobs_root: Path,
           queries: list[dict], k: int, host: str | None = None) -> dict:
    results = [
        eval_model(m, corpus_root=corpus_root, jobs_root=jobs_root,
                   queries=queries, k=k, host=host)
        for m in models
    ]
    return {"k": k, "n_queries": len(queries), "results": results,
            "winner": _winner(results)["model"]}


def _print_report(report: dict) -> None:
    k = report["k"]
    print(f"\nEmbedding A/B — {report['n_queries']} labeled queries, k={k}\n")
    hdr = f"{'model':24} {'hit@1':>6} {'hit@'+str(k):>6} {'MRR':>7} {'build_s':>8} {'q_s':>7}"
    print(hdr); print("-" * len(hdr))
    for r in report["results"]:
        m = r["metrics"]
        hitk = next(v for kk, v in m.items() if kk.startswith("hit@") and kk != "hit@1")
        print(f"{r['model'][:24]:24} {m['hit@1']:>6} {hitk:>6} {m['mrr']:>7.4f} "
              f"{r['build_s']:>8.2f} {r['mean_query_s']:>7.3f}")
    print(f"\nWinner (MRR, then hit@{k}, then latency): {report['winner']}")
    # Per-query rank detail for the top two models
    print("\nper-query rank (lower is better, '-' = missed):")
    qs = [it["q"][:34] for it in report["results"][0]["per_query"]]
    line = f"{'query':36}" + "".join(f"{r['model'][:14]:>15}" for r in report["results"])
    print(line); print("-" * len(line))
    for i, q in enumerate(qs):
        cells = "".join(
            f"{(str(r['per_query'][i]['rank']) if r['per_query'][i]['rank'] else '-'):>15}"
            for r in report["results"]
        )
        print(f"{q:36}{cells}")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="python -m kb.ab_eval", description="A/B embedding-model retrieval eval")
    p.add_argument("--models", nargs="+", default=[DEFAULT_MODEL, "mxbai-embed-large"])
    p.add_argument("--k", type=int, default=3)
    p.add_argument("--corpus-root", default=str(Path.home() / ".claude" / "knowledge"))
    p.add_argument("--jobs-root", default=str(Path.home() / ".claude" / "jobs"))
    p.add_argument("--queries-file", default=None, help="JSON: [{q, expect}, ...] (overrides default set)")
    p.add_argument("--json", action="store_true", help="Emit raw JSON instead of a table")
    args = p.parse_args(argv)

    queries = DEFAULT_QUERIES
    if args.queries_file:
        queries = json.loads(Path(args.queries_file).read_text(encoding="utf-8"))

    report = run_ab(
        args.models, corpus_root=Path(args.corpus_root), jobs_root=Path(args.jobs_root),
        queries=queries, k=args.k,
    )
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        _print_report(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
