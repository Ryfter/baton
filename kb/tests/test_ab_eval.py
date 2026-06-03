"""Tests for kb.ab_eval metric helpers (#24) — pure, no Ollama required."""
from __future__ import annotations

from kb.ab_eval import rank_of, metrics, _winner, DEFAULT_QUERIES


def _hits(*sources: str) -> list[dict]:
    return [{"source": s, "score": 1.0} for s in sources]


def test_rank_of_finds_first_match() -> None:
    hits = _hits("/k/u/routing.md", "/k/p/x/decisions/d003-foo.md", "/k/p/x/decisions/d001-bar.md")
    assert rank_of(hits, "d003") == 2
    assert rank_of(hits, "d001") == 3
    assert rank_of(hits, "routing") == 1


def test_rank_of_missing_is_none() -> None:
    assert rank_of(_hits("/k/a.md", "/k/b.md"), "d999") is None
    assert rank_of([], "d001") is None


def test_rank_of_case_insensitive() -> None:
    assert rank_of(_hits("/K/P/X/Decisions/D007-Y.md"), "d007") == 1


def test_metrics_basic() -> None:
    # ranks: hit@1 x1 (rank 1), within k=3 x2 (ranks 1 and 3), one miss
    m = metrics([1, 3, None], k=3)
    assert m["n"] == 3
    assert m["hit@1"] == 1
    assert m["hit@3"] == 2
    # MRR = (1/1 + 1/3 + 0) / 3 = 0.4444
    assert abs(m["mrr"] - 0.4444) < 0.001


def test_metrics_empty() -> None:
    m = metrics([], k=3)
    assert m == {"n": 0, "hit@1": 0, "hit@3": 0, "mrr": 0.0}


def test_winner_prefers_higher_mrr() -> None:
    a = {"model": "A", "mean_query_s": 0.1, "metrics": {"n": 2, "hit@1": 1, "hit@3": 2, "mrr": 0.75}}
    b = {"model": "B", "mean_query_s": 0.1, "metrics": {"n": 2, "hit@1": 0, "hit@3": 2, "mrr": 0.40}}
    assert _winner([a, b])["model"] == "A"


def test_winner_breaks_tie_on_latency() -> None:
    slow = {"model": "slow", "mean_query_s": 0.9, "metrics": {"n": 1, "hit@1": 1, "hit@3": 1, "mrr": 1.0}}
    fast = {"model": "fast", "mean_query_s": 0.1, "metrics": {"n": 1, "hit@1": 1, "hit@3": 1, "mrr": 1.0}}
    assert _winner([slow, fast])["model"] == "fast"


def test_default_query_set_shape() -> None:
    assert len(DEFAULT_QUERIES) >= 8
    assert all("q" in it and "expect" in it for it in DEFAULT_QUERIES)
