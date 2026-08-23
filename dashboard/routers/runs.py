from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Form, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from dashboard.paths import baton_home
from dashboard.readers.runs import (
    list_runs, read_run_detail, read_global_strip, write_run_answer, read_assignments,
)


def build_router(templates: Jinja2Templates) -> APIRouter:
    """Constructor pattern so the router shares templates with the main app."""
    router = APIRouter()

    def _runs_root(req: Request) -> Path:
        return getattr(req.app.state, "runs_root", baton_home() / "runs")

    @router.get("/partials/runs", response_class=HTMLResponse)
    async def partial_runs(request: Request) -> HTMLResponse:
        root = _runs_root(request)
        return templates.TemplateResponse(request, "partials/runs_list.html", {
            "runs": list_runs(root),
            "strip": read_global_strip(root),
        })

    @router.get("/partials/assignments", response_class=HTMLResponse)
    async def partial_assignments(request: Request) -> HTMLResponse:
        root = _runs_root(request)
        return templates.TemplateResponse(request, "partials/assignments.html", {
            "lanes": read_assignments(root),
        })

    @router.get("/runs/{run_id}", response_class=HTMLResponse)
    async def run_detail(run_id: str, request: Request) -> HTMLResponse:
        try:
            detail = read_run_detail(_runs_root(request), run_id)
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f"no such run: {run_id}")
        return templates.TemplateResponse(request, "run_detail.html", {
            "detail": detail,
        })

    @router.get("/partials/runs/{run_id}", response_class=HTMLResponse)
    async def partial_run_detail(run_id: str, request: Request) -> HTMLResponse:
        try:
            detail = read_run_detail(_runs_root(request), run_id)
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f"no such run: {run_id}")
        return templates.TemplateResponse(request, "partials/run_detail_live.html", {
            "detail": detail,
        })

    @router.post("/runs/{run_id}/answer", response_class=HTMLResponse)
    async def post_answer(run_id: str, request: Request, answer: str = Form(...)) -> HTMLResponse:
        try:
            write_run_answer(_runs_root(request), run_id, answer)
            detail = read_run_detail(_runs_root(request), run_id)
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f"no such run: {run_id}")
        return templates.TemplateResponse(request, "partials/run_detail_live.html", {
            "detail": detail,
        })

    return router
