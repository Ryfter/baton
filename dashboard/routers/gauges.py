"""Gauges page — live 5h burn + cap instruments."""
from __future__ import annotations

from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from dashboard.paths import baton_home
from dashboard.readers.gauges import read_gauges
from dashboard.readers.maestro_jobs import maestro_root
from dashboard.readers.stats import compute_stats


def build_router(templates: Jinja2Templates) -> APIRouter:
    router = APIRouter(tags=["gauges"])

    def _paths(req: Request) -> tuple[Path, Path, Path, Path]:
        home = Path(getattr(req.app.state, "baton_home", None) or baton_home())
        journal = Path(
            getattr(req.app.state, "journal_path", None) or home / "model-routing-log.md"
        )
        jobs = Path(getattr(req.app.state, "jobs_root", None) or home / "jobs")
        maestro = Path(getattr(req.app.state, "maestro_jobs_root", None) or maestro_root(home))
        return home, journal, jobs, maestro

    def _payload(req: Request) -> dict:
        home, journal, jobs, maestro = _paths(req)
        return read_gauges(
            journal_path=journal,
            baton_home=home,
            jobs_root=jobs,
            maestro_jobs_root=maestro,
        )

    def _ctx(req: Request) -> dict:
        home, journal, _, _ = _paths(req)
        stats = compute_stats(journal)
        return {
            "stats": stats,
            "server_time": datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z"),
            "gauges": _payload(req),
        }

    @router.get("/gauges", response_class=HTMLResponse)
    async def gauges_page(request: Request) -> HTMLResponse:
        return templates.TemplateResponse(request, "gauges.html", _ctx(request))

    @router.get("/partials/gauges", response_class=HTMLResponse)
    async def gauges_partial(request: Request) -> HTMLResponse:
        ctx = _ctx(request)
        return templates.TemplateResponse(request, "partials/gauges_board.html", ctx)

    @router.get("/api/gauges")
    async def gauges_api(request: Request) -> dict:
        return _payload(request)

    return router
