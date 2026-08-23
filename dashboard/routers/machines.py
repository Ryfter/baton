"""Machines page — computers + what's installed (catalog stays collapsed)."""
from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from dashboard.paths import baton_home
from dashboard.readers.machines import default_fleet_path, read_machines
from dashboard.readers.stats import compute_stats


def build_router(templates: Jinja2Templates) -> APIRouter:
    router = APIRouter(tags=["machines"])

    def _home(req: Request) -> Path:
        return Path(getattr(req.app.state, "baton_home", None) or baton_home())

    @router.get("/machines", response_class=HTMLResponse)
    async def machines_page(request: Request) -> HTMLResponse:
        home = _home(request)
        journal = Path(getattr(request.app.state, "journal_path", None) or home / "model-routing-log.md")
        stats = compute_stats(journal)
        fleet = Path(getattr(request.app.state, "fleet_path", None) or default_fleet_path(home))
        inventory = home / "model-inventory.json"
        coordination = home / "coordination" / "config.json"
        payload = read_machines(
            fleet,
            inventory_path=inventory if inventory.is_file() else None,
            coordination_path=coordination if coordination.is_file() else None,
            loaded_lms=stats.lms_models,
        )
        return templates.TemplateResponse(
            request,
            "machines.html",
            {
                "stats": stats,
                "machines": payload["machines"],
                "fleet_path": payload["fleet_path"],
            },
        )

    return router
