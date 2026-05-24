# dashboard/main.py
from __future__ import annotations
import os
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from dashboard.readers.stats import compute_stats
from dashboard.routers.api import router as api_router
from dashboard.routers.controls import router as controls_router

JOURNAL_PATH = Path(
    os.environ.get("ROUTING_JOURNAL", "")
    or Path.home() / ".claude" / "model-routing-log.md"
)

_HERE = Path(__file__).parent

app = FastAPI(title="Routing Dashboard", version="2.0.0")
app.state.journal_path = JOURNAL_PATH

app.mount("/static", StaticFiles(directory=_HERE / "static"), name="static")
templates = Jinja2Templates(directory=str(_HERE / "templates"))

app.include_router(api_router)
app.include_router(controls_router)


def _ctx(request: Request) -> dict:
    stats = compute_stats(JOURNAL_PATH)
    return {
        "stats": stats,
        "server_time": datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z"),
    }


@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "index.html", _ctx(request))


@app.get("/partials/spend", response_class=HTMLResponse)
async def partial_spend(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "partials/spend_today.html", _ctx(request))


@app.get("/partials/leaderboard", response_class=HTMLResponse)
async def partial_leaderboard(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "partials/leaderboard.html", _ctx(request))


@app.get("/partials/activity", response_class=HTMLResponse)
async def partial_activity(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "partials/activity_rows.html", _ctx(request))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("dashboard.main:app", host="127.0.0.1", port=8765, reload=True)
