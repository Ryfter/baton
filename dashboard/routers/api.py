from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Request

from dashboard.models.events import DashboardStats
from dashboard.readers.stats import compute_stats

router = APIRouter()


def _journal_path(request: Request) -> Path:
    return getattr(
        request.app.state,
        "journal_path",
        Path.home() / ".claude" / "model-routing-log.md",
    )


@router.get("/api/stats", response_model=DashboardStats)
async def get_stats(request: Request) -> DashboardStats:
    return compute_stats(_journal_path(request))
