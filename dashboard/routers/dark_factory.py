"""Dark factory dashboard panel."""
from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates

from dashboard.paths import baton_home
from dashboard.readers.dark_factory import read_dark_factory_board


def build_router(templates: Jinja2Templates) -> APIRouter:
    router = APIRouter(prefix="/dark-factory", tags=["dark-factory"])

    def _home(req: Request) -> Path:
        return Path(getattr(req.app.state, "baton_home", None) or baton_home())

    @router.get("/status")
    async def get_status(request: Request) -> JSONResponse:
        return JSONResponse(read_dark_factory_board(_home(request)))

    @router.get("/partials/panel", response_class=HTMLResponse)
    async def partial_panel(request: Request) -> HTMLResponse:
        board = read_dark_factory_board(_home(request))
        return templates.TemplateResponse(
            request,
            "partials/dark_factory_panel.html",
            {"board": board},
        )

    return router
