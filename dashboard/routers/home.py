"""Home board routes — attention, capacity, project cards."""
from __future__ import annotations

from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from dashboard.paths import baton_home
from dashboard.readers.home_board import read_home_floor, read_home_header
from dashboard.readers.maestro_jobs import list_registry_projects, maestro_root
from dashboard.readers.stats import compute_stats


def build_router(templates: Jinja2Templates) -> APIRouter:
    router = APIRouter(tags=["home"])

    def _paths(req: Request) -> tuple[Path, Path, Path, Path]:
        home = Path(getattr(req.app.state, "baton_home", None) or baton_home())
        journal = Path(getattr(req.app.state, "journal_path", None) or home / "model-routing-log.md")
        jobs = Path(getattr(req.app.state, "jobs_root", None) or home / "jobs")
        runs = Path(getattr(req.app.state, "runs_root", None) or home / "runs")
        return home, journal, jobs, runs

    def _ctx(req: Request) -> dict:
        home, journal, _, _ = _paths(req)
        return {
            "stats": compute_stats(journal),
            "server_time": datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z"),
        }

    @router.get("/partials/home-header", response_class=HTMLResponse)
    async def home_header(request: Request) -> HTMLResponse:
        home, journal, jobs, runs = _paths(request)
        ctx = _ctx(request)
        ctx["board"] = read_home_header(
            baton_home=home,
            journal_path=journal,
            jobs_root=jobs,
            runs_root=runs,
        )
        return templates.TemplateResponse(request, "partials/home_header.html", ctx)

    @router.get("/partials/home-floor", response_class=HTMLResponse)
    async def home_floor(request: Request) -> HTMLResponse:
        home, journal, jobs, runs = _paths(request)
        ctx = _ctx(request)
        ctx["floor"] = read_home_floor(
            baton_home=home,
            journal_path=journal,
            jobs_root=jobs,
            runs_root=runs,
        )
        return templates.TemplateResponse(request, "partials/home_floor.html", ctx)

    @router.get("/api/home-board")
    async def home_board_api(request: Request) -> dict:
        home, journal, jobs, runs = _paths(request)
        return {
            "header": read_home_header(
                baton_home=home,
                journal_path=journal,
                jobs_root=jobs,
                runs_root=runs,
            ),
            "floor": read_home_floor(
                baton_home=home,
                journal_path=journal,
                jobs_root=jobs,
                runs_root=runs,
            ),
        }

    @router.get("/api/command-palette")
    async def command_palette_api(request: Request) -> dict:
        home, _, _, _ = _paths(request)
        projects = list_registry_projects(home)
        return {
            "projects": [
                {"id": p["id"], "name": p.get("name") or p["id"]}
                for p in projects
            ],
        }

    return router
