"""MyDashboard intel radar — embedded in Baton command center."""
from __future__ import annotations

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates

from dashboard.readers.mydashboard_intel import read_mydashboard_intel


def build_router(templates: Jinja2Templates) -> APIRouter:
    router = APIRouter(prefix="/mydashboard", tags=["mydashboard"])

    @router.get("/status")
    async def get_status() -> JSONResponse:
        return JSONResponse(read_mydashboard_intel())

    @router.get("/partials/intel", response_class=HTMLResponse)
    async def partial_intel(request: Request) -> HTMLResponse:
        intel = read_mydashboard_intel()
        return templates.TemplateResponse(
            request,
            "partials/mydashboard_intel.html",
            {"intel": intel},
        )

    return router
