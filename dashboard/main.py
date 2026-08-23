# dashboard/main.py
from __future__ import annotations
import os
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from dashboard.paths import baton_home
from dashboard.readers.command_hero import read_command_hero
from dashboard.readers.stats import compute_stats
from dashboard.readers.ensembles import read_ensembles
from dashboard.routers.api import router as api_router
from dashboard.routers.controls import router as controls_router

JOURNAL_PATH = Path(
    os.environ.get("ROUTING_JOURNAL", "")
    or baton_home() / "model-routing-log.md"
)

JOBS_ROOT = Path(
    os.environ.get('ROUTING_JOBS_ROOT', '')
    or baton_home() / 'jobs'
)

KB_ROOT = Path(
    os.environ.get('ROUTING_KB_ROOT', '')
    or Path.home() / '.claude' / 'knowledge'
)

ENSEMBLES_ROOT = Path(
    os.environ.get('ROUTING_ENSEMBLES_ROOT', '')
    or baton_home() / 'ensembles'
)

RUNS_ROOT = Path(
    os.environ.get('ROUTING_RUNS_ROOT', '')
    or baton_home() / 'runs'
)

_HERE = Path(__file__).parent

app = FastAPI(title="Baton", version="2.1.0")
app.state.journal_path = JOURNAL_PATH
app.state.jobs_root = JOBS_ROOT
app.state.kb_root = KB_ROOT
app.state.ensembles_root = ENSEMBLES_ROOT
app.state.runs_root = RUNS_ROOT
app.state.baton_home = baton_home()

app.mount("/static", StaticFiles(directory=_HERE / "static"), name="static")
templates = Jinja2Templates(directory=str(_HERE / "templates"))

app.include_router(api_router)
app.include_router(controls_router)

from dashboard.routers.jobs import build_router as build_jobs_router
app.include_router(build_jobs_router(templates))

from dashboard.routers.projects import build_router as build_projects_router
app.include_router(build_projects_router(templates))

from dashboard.routers.kb import build_router as build_kb_router
app.include_router(build_kb_router(templates))

from dashboard.routers.runs import build_router as build_runs_router
app.include_router(build_runs_router(templates))

from dashboard.routers.maestro import build_router as build_maestro_router
app.include_router(build_maestro_router(templates))

from dashboard.routers.cockpit import build_router as build_cockpit_router
app.include_router(build_cockpit_router(templates))

from dashboard.routers.machines import build_router as build_machines_router
app.include_router(build_machines_router(templates))

from dashboard.routers.gauges import build_router as build_gauges_router
app.include_router(build_gauges_router(templates))

from dashboard.routers.home import build_router as build_home_router
app.include_router(build_home_router(templates))

from dashboard.routers.dark_factory import build_router as build_dark_factory_router
app.include_router(build_dark_factory_router(templates))

from dashboard.readers.home_board import read_home_floor, read_home_header
from dashboard.routers.mydashboard import build_router as build_mydashboard_router
app.include_router(build_mydashboard_router(templates))


def _ctx(request: Request) -> dict:
    stats = compute_stats(JOURNAL_PATH)
    return {
        "stats": stats,
        "server_time": datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z"),
    }


def _home_paths(request: Request) -> tuple[Path, Path, Path, Path]:
    home = Path(getattr(request.app.state, "baton_home", None) or baton_home())
    journal = Path(getattr(request.app.state, "journal_path", None) or JOURNAL_PATH)
    jobs = Path(getattr(request.app.state, "jobs_root", None) or JOBS_ROOT)
    runs = Path(getattr(request.app.state, "runs_root", None) or RUNS_ROOT)
    return home, journal, jobs, runs


@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    ctx = _ctx(request)
    home, journal, jobs, runs = _home_paths(request)
    ctx["board"] = read_home_header(
        baton_home=home, journal_path=journal, jobs_root=jobs, runs_root=runs,
    )
    ctx["floor"] = read_home_floor(
        baton_home=home, journal_path=journal, jobs_root=jobs, runs_root=runs,
    )
    return templates.TemplateResponse(request, "index.html", ctx)


@app.get("/partials/command-hero", response_class=HTMLResponse)
async def partial_command_hero(request: Request) -> HTMLResponse:
    ctx = _ctx(request)
    ctx["hero"] = read_command_hero(app.state.baton_home, JOURNAL_PATH)
    return templates.TemplateResponse(request, "partials/command_hero.html", ctx)


@app.get("/partials/spend", response_class=HTMLResponse)
async def partial_spend(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "partials/spend_today.html", _ctx(request))


@app.get("/partials/leaderboard", response_class=HTMLResponse)
async def partial_leaderboard(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "partials/leaderboard.html", _ctx(request))


@app.get("/partials/activity", response_class=HTMLResponse)
async def partial_activity(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "partials/activity_rows.html", _ctx(request))


@app.get("/partials/controls", response_class=HTMLResponse)
async def partial_controls(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "partials/controls.html", _ctx(request))


@app.get("/partials/fleet", response_class=HTMLResponse)
async def partial_fleet(request: Request) -> HTMLResponse:
    ctx = _ctx(request)
    ctx["fleet"] = read_ensembles(ENSEMBLES_ROOT)
    return templates.TemplateResponse(request, "partials/fleet_activity.html", ctx)


# Plan 7 portfolio partial wrapped here so it picks up _ctx and renders even when
# included on the home page; the dedicated router serves /projects and /partials/projects.
# (Intentionally a thin alias — kept for parity with other partials.)


if __name__ == "__main__":
    import uvicorn
    # Factory UI is used from the PC (droid:<port> / Tailscale), not just this box.
    uvicorn.run("dashboard.main:app", host="0.0.0.0", port=8765, reload=True)
