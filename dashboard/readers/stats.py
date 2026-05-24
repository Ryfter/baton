from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime
from pathlib import Path

try:
    import httpx as _httpx
    _HTTPX_AVAILABLE = True
except ImportError:
    _HTTPX_AVAILABLE = False

from dashboard.models.events import DashboardStats, HookEntry, LmStudioModel, ModelStats, OtelEntry
from dashboard.readers.journal import read_journal

LMS_API = "http://localhost:1234/v1/models"


def _get_lms_models() -> list[LmStudioModel]:
    """Query LM Studio OpenAI-compat API for loaded models. Returns [] if unreachable."""
    if not _HTTPX_AVAILABLE:
        return []
    try:
        resp = _httpx.get(LMS_API, timeout=1.5)
        if resp.status_code == 200:
            return [
                LmStudioModel(id=m["id"])
                for m in resp.json().get("data", [])
            ]
    except Exception:
        pass
    return []


def compute_stats(journal_path: Path) -> DashboardStats:
    entries = read_journal(journal_path)
    today = date.today()

    otel_entries = [entry for entry in entries if isinstance(entry, OtelEntry)]
    hook_entries = [entry for entry in entries if isinstance(entry, HookEntry)]

    today_cost = sum(
        entry.cost_usd for entry in otel_entries if entry.timestamp.date() == today
    )

    model_totals: dict[str, dict[str, int | float]] = defaultdict(
        lambda: {"calls": 0, "cost_usd": 0.0, "tokens_in": 0, "tokens_out": 0}
    )
    for entry in otel_entries:
        totals = model_totals[entry.model]
        totals["calls"] += 1
        totals["cost_usd"] += entry.cost_usd
        totals["tokens_in"] += entry.input_tokens
        totals["tokens_out"] += entry.output_tokens

    models = [
        ModelStats(
            name=name,
            calls=int(totals["calls"]),
            cost_usd=float(totals["cost_usd"]),
            tokens_in=int(totals["tokens_in"]),
            tokens_out=int(totals["tokens_out"]),
        )
        for name, totals in model_totals.items()
    ]
    models.sort(key=lambda model: model.cost_usd, reverse=True)

    return DashboardStats(
        today_cost_usd=today_cost,
        total_otel_calls=len(otel_entries),
        models=models,
        recent_hooks=hook_entries[-20:],
        ollama_models=[],
        lms_models=_get_lms_models(),
        last_updated=datetime.now().astimezone(),
    )
