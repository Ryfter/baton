from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Form, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from dashboard.readers.runs import (
    list_runs, read_run_detail, read_global_strip, write_run_answer,
)


def build_router(templates: Jinja2Templates) -> APIRouter:
    """Constructor pattern so the router shares templates with the main app."""
    router = APIRouter()

    def _runs_root(req: Request) -> Path:
        return getattr(req.app.state, "runs_root", Path.home() / ".claude" / "runs")

    @router.get("/partials/runs", response_class=HTMLResponse)
    async def partial_runs(request: Request) -> HTMLResponse:
        root = _runs_root(request)
        return templates.TemplateResponse("partials/runs_list.html", {
            "request": request,
            "runs": list_runs(root),
            "strip": read_global_strip(root),
        })

    @router.get("/runs/{run_id}", response_class=HTMLResponse)
    async def run_detail(run_id: str, request: Request) -> HTMLResponse:
        try:
            detail = read_run_detail(_runs_root(request), run_id)
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f"no such run: {run_id}")
        return templates.TemplateResponse("run_detail.html", {
            "request": request, "detail": detail,
        })

    @router.get("/partials/runs/{run_id}", response_class=HTMLResponse)
    async def partial_run_detail(run_id: str, request: Request) -> HTMLResponse:
        try:
            detail = read_run_detail(_runs_root(request), run_id)
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f"no such run: {run_id}")
        return templates.TemplateResponse("partials/run_detail_live.html", {
            "request": request, "detail": detail,
        })

    @router.post("/runs/{run_id}/answer", response_class=HTMLResponse)
    async def post_answer(run_id: str, request: Request, answer: str = Form(...)) -> HTMLResponse:
        try:
            write_run_answer(_runs_root(request), run_id, answer)
            detail = read_run_detail(_runs_root(request), run_id)
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f"no such run: {run_id}")
        return templates.TemplateResponse("partials/run_detail_live.html", {
            "request": request, "detail": detail,
        })

    return router
