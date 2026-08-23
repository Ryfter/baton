"""Maestro HTTP — POST/GET /maestro/jobs, budget, hold (front-door slice 1)."""
from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates

from dashboard.paths import baton_home
from dashboard.readers.transcribe import engine_status, transcribe_bytes
from dashboard.readers.cockpit_grid import last_output_from_turns, turns_for_job
from dashboard.readers.maestro_jobs import (
    board_status,
    budget_for,
    create_job,
    hold_job,
    list_jobs,
    list_registry_projects,
    maestro_root,
    project_in_registry,
    read_job,
    release_job,
)


_FEATURE_RANK = {
    "running": 0,
    "admitted": 1,
    "waiting-quota": 2,
    "queued": 3,
    "held": 4,
    "done": 5,
}


def _featured_job(jobs: list, prefer: dict | None = None) -> dict | None:
    if prefer and any(j.get("id") == prefer.get("id") for j in jobs):
        return prefer
    if not jobs:
        return None
    return min(jobs, key=lambda j: _FEATURE_RANK.get(str(j.get("status") or ""), 9))


def _last_project(jobs: list, projects: list) -> str | None:
    known = {p["id"] for p in projects}
    for job in jobs:
        pid = job.get("project")
        if pid in known:
            return str(pid)
    return None


def build_router(templates: Jinja2Templates) -> APIRouter:
    router = APIRouter(prefix="/maestro", tags=["maestro"])

    def _home(req: Request) -> Path:
        return Path(getattr(req.app.state, "baton_home", None) or baton_home())

    def _root(req: Request) -> Path:
        override = getattr(req.app.state, "maestro_jobs_root", None)
        return Path(override) if override else maestro_root(_home(req))

    def _status_ctx(req: Request, prefer: dict | None = None) -> dict:
        board = board_status(_root(req), baton_home=_home(req))
        all_jobs = list_jobs(_root(req))
        # Live work first (running → admitted → … → done), newest within a status.
        ranked = sorted(all_jobs, key=lambda j: j.get("created_at") or "", reverse=True)
        ranked = sorted(
            ranked, key=lambda j: _FEATURE_RANK.get(str(j.get("status") or ""), 9)
        )
        featured = _featured_job(all_jobs, prefer)
        runs_root = Path(getattr(req.app.state, "runs_root", None) or _home(req) / "runs")
        turns = turns_for_job(
            _root(req),
            featured.get("id") if featured else None,
            runs_root,
            featured.get("run_id") if featured else None,
        )
        return {
            "jobs": ranked[:12],
            "job": featured,
            "budget": board["budget"],
            "status_line": board.get("status_line"),
            "counts": board.get("counts") or {},
            "job_turns": turns,
            "job_last_output": last_output_from_turns(turns),
        }

    def _compose_ctx(req: Request) -> dict:
        home = _home(req)
        projects = list_registry_projects(home)
        ctx = _status_ctx(req)
        ctx["projects"] = projects
        ctx["last_project"] = _last_project(ctx["jobs"], projects)
        ctx["stt"] = engine_status()
        return ctx

    @router.get("/status")
    async def get_status(request: Request) -> JSONResponse:
        return JSONResponse(board_status(_root(request), baton_home=_home(request)))

    @router.get("/jobs")
    async def get_jobs(request: Request) -> JSONResponse:
        return JSONResponse({"jobs": list_jobs(_root(request))})

    @router.get("/budget")
    async def get_budget(request: Request) -> JSONResponse:
        return JSONResponse(budget_for(_home(request)))

    @router.get("/stt")
    async def get_stt() -> JSONResponse:
        return JSONResponse(engine_status())

    @router.post("/transcribe")
    async def post_transcribe(audio: UploadFile = File(...)) -> JSONResponse:
        data = await audio.read()
        try:
            text = transcribe_bytes(data, filename=audio.filename or "clip.webm")
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        except RuntimeError as exc:
            raise HTTPException(status_code=503, detail=str(exc))
        return JSONResponse({"text": text, "engine": "mlx_whisper", "target": "droid"})

    @router.get("/partials/status", response_class=HTMLResponse)
    async def partial_status(request: Request) -> HTMLResponse:
        return templates.TemplateResponse(
            request,
            "partials/maestro_status.html",
            _status_ctx(request),
        )

    @router.post("/jobs/{job_id}/release")
    async def post_release(job_id: str, request: Request):
        try:
            job = release_job(_root(request), job_id)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f"no such job: {job_id}")

        hx = request.headers.get("hx-request")
        if hx:
            return templates.TemplateResponse(
                request,
                "partials/maestro_status.html",
                _status_ctx(request, prefer=job),
            )
        return JSONResponse(job)

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
            return templates.TemplateResponse(
                request,
                "partials/maestro_status.html",
                _status_ctx(request, prefer=job),
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
                status="queued",
                provider=None,
            )
        except ValueError as exc:
            return _reject(str(exc))

        accept = (request.headers.get("accept") or "").lower()
        hx = request.headers.get("hx-request")
        if hx or ("text/html" in accept and "application/json" not in accept):
            return templates.TemplateResponse(
                request,
                "partials/maestro_status.html",
                _status_ctx(request, prefer=job),
            )
        return JSONResponse(job, status_code=201)

    @router.get("/partials/compose", response_class=HTMLResponse)
    async def partial_compose(request: Request) -> HTMLResponse:
        ctx = _compose_ctx(request)
        compact = request.query_params.get("compact") in {"1", "true", "yes"}
        ctx["compact"] = compact
        projects = ctx.get("projects") or []
        ctx["visible_projects"] = projects[:5] if compact else projects
        ctx["overflow_projects"] = projects[5:] if compact else []
        return templates.TemplateResponse(
            request,
            "partials/maestro_compose.html",
            ctx,
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
