from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from dashboard.readers.jobs import list_job_summaries, read_job_detail


def build_router(templates: Jinja2Templates) -> APIRouter:
    """Constructor pattern so the router can share templates with the main app."""
    router = APIRouter()

    def _jobs_root(req: Request) -> Path:
        return getattr(
            req.app.state, 'jobs_root',
            Path.home() / '.claude' / 'jobs',
        )

    def _journal_path(req: Request) -> Path:
        return getattr(
            req.app.state, 'journal_path',
            Path.home() / '.claude' / 'model-routing-log.md',
        )

    @router.get('/partials/jobs', response_class=HTMLResponse)
    async def partial_jobs(request: Request) -> HTMLResponse:
        # Default filter shows active + recent done (last 10)
        active = list_job_summaries(_jobs_root(request), _journal_path(request), 'active')
        done = list_job_summaries(_jobs_root(request), _journal_path(request), 'done')[:10]
        return templates.TemplateResponse('partials/jobs_list.html', {
            'request': request,
            'active_jobs': active,
            'done_jobs': done,
        })

    @router.get('/jobs/{job_id}', response_class=HTMLResponse)
    async def job_detail(job_id: str, request: Request) -> HTMLResponse:
        try:
            detail = read_job_detail(_jobs_root(request), _journal_path(request), job_id)
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f'no such job: {job_id}')
        return templates.TemplateResponse('job_detail.html', {
            'request': request,
            'detail': detail,
        })

    return router
