"""Maestro HTTP — POST/GET /maestro/jobs, budget, hold (front-door slice 1)."""
from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates

from dashboard.paths import baton_home
from dashboard.readers.maestro_jobs import (
    budget_stub,
    create_job,
    hold_job,
    list_jobs,
    list_registry_projects,
    maestro_root,
    project_in_registry,
    read_job,
)


def build_router(templates: Jinja2Templates) -> APIRouter:
    router = APIRouter(prefix="/maestro", tags=["maestro"])

    def _home(req: Request) -> Path:
        return Path(getattr(req.app.state, "baton_home", None) or baton_home())

    def _root(req: Request) -> Path:
        override = getattr(req.app.state, "maestro_jobs_root", None)
        return Path(override) if override else maestro_root(_home(req))

    @router.get("/jobs")
    async def get_jobs(request: Request) -> JSONResponse:
        return JSONResponse({"jobs": list_jobs(_root(request))})

    @router.get("/budget")
    async def get_budget() -> JSONResponse:
        return JSONResponse(budget_stub())

    @router.get("/partials/status", response_class=HTMLResponse)
    async def partial_status(request: Request) -> HTMLResponse:
        jobs = list_jobs(_root(request))[:8]
        return templates.TemplateResponse(
            request,
            "partials/maestro_status.html",
            {
                "jobs": jobs,
                "job": jobs[0] if jobs else None,
                "budget": budget_stub(),
            },
        )

    @router.post("/jobs/{job_id}/hold")
    async def post_hold(job_id: str, request: Request):
        try:
            job = hold_job(_root(request), job_id)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f"no such job: {job_id}")

        hx = request.headers.get("hx-request")
        if hx:
            jobs = list_jobs(_root(request))[:8]
            return templates.TemplateResponse(
                request,
                "partials/maestro_status.html",
                {
                    "jobs": jobs,
                    "job": job,
                    "budget": budget_stub(),
                },
            )
        return JSONResponse(job)

    @router.post("/jobs")
    async def post_job(
        request: Request,
        project: str = Form(...),
        goal: str = Form(...),
        stakes: str = Form("standard"),
        source: str = Form("web"),
    ):
        home = _home(request)
        hx = request.headers.get("hx-request")

        def _reject(message: str):
            if hx:
                return templates.TemplateResponse(
                    request,
                    "partials/maestro_error.html",
                    {"error": message},
                    status_code=400,
                )
            raise HTTPException(status_code=400, detail=message)

        if not project_in_registry(home, project):
            return _reject(f"unknown project (not in Maestro registry): {project}")
        try:
            job = create_job(
                _root(request),
                project=project,
                goal=goal,
                stakes=stakes,
                source=source,
                status="admitted",
                provider=None,
            )
        except ValueError as exc:
            return _reject(str(exc))

        accept = (request.headers.get("accept") or "").lower()
        hx = request.headers.get("hx-request")
        if hx or ("text/html" in accept and "application/json" not in accept):
            jobs = list_jobs(_root(request))[:8]
            return templates.TemplateResponse(
                request,
                "partials/maestro_status.html",
                {
                    "jobs": jobs,
                    "job": job,
                    "budget": budget_stub(),
                },
            )
        return JSONResponse(job, status_code=201)

    @router.get("/partials/compose", response_class=HTMLResponse)
    async def partial_compose(request: Request) -> HTMLResponse:
        home = _home(request)
        projects = list_registry_projects(home)
        jobs = list_jobs(_root(request))[:8]
        return templates.TemplateResponse(
            request,
            "partials/maestro_compose.html",
            {
                "projects": projects,
                "jobs": jobs,
                "job": jobs[0] if jobs else None,
                "budget": budget_stub(),
            },
        )

    @router.get("/jobs/{job_id}")
    async def get_job(job_id: str, request: Request) -> JSONResponse:
        try:
            return JSONResponse(read_job(_root(request), job_id))
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f"no such job: {job_id}")

    return router
