"""Per-project window economics — provider/model breakdown + policy C savings."""
from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from dashboard.models.events import OtelEntry
from dashboard.readers.gauges import (
    UNASSIGNED,
    _ensure_utc,
    _fmt_cost,
    _fmt_tokens,
    _in_window,
    build_job_project_map,
    resolve_window,
)
from dashboard.readers.journal import read_journal
from dashboard.readers.machines import default_fleet_path, parse_fleet_providers
from dashboard.readers.maestro_jobs import list_jobs, maestro_root

_RATES_PATH = Path(__file__).resolve().parents[1] / "data" / "api-rates.json"


def _load_rates() -> dict[str, Any]:
    try:
        return json.loads(_RATES_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"default": {"input_per_m": 3.0, "output_per_m": 15.0}, "models": {}}


def _fleet_index(baton_home: Path) -> dict[str, dict[str, str]]:
    fleet = default_fleet_path(baton_home)
    if not fleet.is_file():
        return {}
    try:
        rows = parse_fleet_providers(fleet.read_text(encoding="utf-8"))
    except OSError:
        return {}
    return {str(r.get("name") or ""): r for r in rows if r.get("name")}


def _model_rate(model: str, rates: dict[str, Any]) -> tuple[float, float]:
    models = rates.get("models") or {}
    spec = models.get(model) or models.get(model.split("/")[-1])
    if not spec:
        spec = rates.get("default") or {"input_per_m": 3.0, "output_per_m": 15.0}
    return float(spec.get("input_per_m", 3.0)), float(spec.get("output_per_m", 15.0))


def _line_api_cost(model: str, inp: int, out: int, rates: dict[str, Any]) -> float:
    inp_m, out_m = _model_rate(model, rates)
    return (inp / 1_000_000.0) * inp_m + (out / 1_000_000.0) * out_m


def _infer_provider(
    model: str,
    job_provider: Optional[str],
    fleet: dict[str, dict[str, str]],
) -> tuple[str, str]:
    if job_provider:
        return job_provider, str(fleet.get(job_provider, {}).get("cost_tier") or "paid")
    mlow = (model or "").lower()
    for name, row in fleet.items():
        md = str(row.get("model_default") or "").lower()
        if md and md in mlow:
            return name, str(row.get("cost_tier") or "paid")
        if name.lower() in mlow:
            return name, str(row.get("cost_tier") or "paid")
    if "ox-alpha" in mlow or "ox_alpha" in mlow:
        for name, row in fleet.items():
            if "ox-alpha" in name.lower() or "ox_alpha" in name.lower():
                return name, str(row.get("cost_tier") or "free")
    return "unknown", "unknown"


def _tier_label(tier: str) -> str:
    t = (tier or "").lower()
    if t == "free":
        return "FREE"
    if t == "local":
        return "LOCAL"
    if t == "paid":
        return "PAID"
    return ""


def _counterfactual_usd(
    tier: str,
    model: str,
    inp: int,
    out: int,
    actual: float,
    rates: dict[str, Any],
) -> Optional[float]:
    api = _line_api_cost(model, inp, out, rates)
    t = (tier or "").lower()
    if t == "free":
        return api
    if t == "local":
        return api
    if t == "paid":
        return api
    if t == "unknown":
        return None
    return api


def _job_providers(jobs_dir: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for job in list_jobs(jobs_dir):
        jid = str(job.get("id") or "")
        prov = str(job.get("provider") or "").strip()
        if jid and prov:
            out[jid] = prov
    return out


def economics_for_projects(
    *,
    journal_path: Path,
    baton_home: Path,
    jobs_root: Path,
    project_ids: Optional[set[str]] = None,
    now: Optional[datetime] = None,
) -> dict[str, dict[str, Any]]:
    clock = _ensure_utc(now or datetime.now(timezone.utc))
    window = resolve_window(baton_home, now=clock)
    start = window["start"]
    end = window["end"]
    mj_root = maestro_root(baton_home)
    job_projects = build_job_project_map(jobs_root, mj_root)
    job_providers = _job_providers(mj_root)
    fleet = _fleet_index(baton_home)
    rates = _load_rates()

    by_project: dict[str, dict[str, Any]] = defaultdict(
        lambda: {
            "rows": defaultdict(lambda: {"tokens": 0, "cost_usd": 0.0, "savings_usd": 0.0}),
            "total_tokens": 0,
            "total_cost_usd": 0.0,
            "total_savings_usd": 0.0,
        }
    )

    for entry in read_journal(journal_path):
        if not isinstance(entry, OtelEntry):
            continue
        if not _in_window(entry.timestamp, start, end):
            continue
        project_id = UNASSIGNED
        job_provider = None
        if entry.job_id and entry.job_id in job_projects:
            project_id = job_projects[entry.job_id]
            job_provider = job_providers.get(entry.job_id)
        if project_ids is not None and project_id not in project_ids and project_id != UNASSIGNED:
            continue
        tokens = entry.input_tokens + entry.output_tokens
        provider, tier = _infer_provider(entry.model, job_provider, fleet)
        key = (provider, entry.model)
        bucket = by_project[project_id]
        row = bucket["rows"][key]
        row["provider"] = provider
        row["model"] = entry.model
        row["tier"] = tier
        row["tokens"] += tokens
        row["cost_usd"] += entry.cost_usd
        bucket["total_tokens"] += tokens
        bucket["total_cost_usd"] += entry.cost_usd
        cf = _counterfactual_usd(tier, entry.model, entry.input_tokens, entry.output_tokens, entry.cost_usd, rates)
        if cf is not None:
            savings = max(0.0, cf - entry.cost_usd)
            row["savings_usd"] += savings
            bucket["total_savings_usd"] += savings

    out: dict[str, dict[str, Any]] = {}
    for pid, bucket in by_project.items():
        rows = list(bucket["rows"].values())
        rows.sort(key=lambda r: r["tokens"], reverse=True)
        total_tok = bucket["total_tokens"] or 1
        formatted_rows = []
        for r in rows:
            share = r["tokens"] / total_tok
            formatted_rows.append({
                "provider": r["provider"],
                "model": r["model"],
                "tier": _tier_label(r["tier"]),
                "tokens": r["tokens"],
                "tokens_display": _fmt_tokens(r["tokens"]),
                "cost_usd": round(r["cost_usd"], 4),
                "cost_display": _fmt_cost(r["cost_usd"]),
                "share_fill": share,
            })
        savings = bucket["total_savings_usd"]
        out[pid] = {
            "total_tokens": bucket["total_tokens"],
            "total_tokens_display": _fmt_tokens(bucket["total_tokens"]),
            "total_cost_usd": round(bucket["total_cost_usd"], 4),
            "total_cost_display": _fmt_cost(bucket["total_cost_usd"]),
            "savings_usd": round(savings, 2) if savings > 0.01 else None,
            "savings_display": f"Saved {_fmt_cost(savings)} vs policy API" if savings > 0.01 else None,
            "rows": formatted_rows,
        }
    return out
