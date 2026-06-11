"""Plan 7: project list + drill-in HTTP routes."""
from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from dashboard.paths import baton_home
from dashboard.readers.projects import discover_projects, read_project_detail


def build_router(templates: Jinja2Templates) -> APIRouter:
    router = APIRouter()

    def _kb_root(req: Request) -> Path:
        return getattr(
            req.app.state, 'kb_root',
            Path.home() / '.claude' / 'knowledge',
        )

    def _jobs_root(req: Request) -> Path:
        return getattr(
            req.app.state, 'jobs_root',
            baton_home() / 'jobs',
        )

    def _journal_path(req: Request) -> Path:
        return getattr(
            req.app.state, 'journal_path',
            baton_home() / 'model-routing-log.md',
        )

    @router.get('/projects', response_class=HTMLResponse)
    async def projects_list(request: Request) -> HTMLResponse:
        projects = discover_projects(_kb_root(request), _jobs_root(request), _journal_path(request))
        return templates.TemplateResponse(request, 'projects_list.html', {
            'projects': projects,
        })

    @router.get('/projects/{project_id}', response_class=HTMLResponse)
    async def project_detail(project_id: str, request: Request) -> HTMLResponse:
        try:
            detail = read_project_detail(
                _kb_root(request), project_id,
                _jobs_root(request), _journal_path(request),
            )
        except FileNotFoundError:
            raise HTTPException(status_code=404, detail=f'no such project: {project_id}')
        return templates.TemplateResponse(request, 'project_detail.html', {
            'detail': detail,
        })

    @router.get('/partials/projects', response_class=HTMLResponse)
    async def partial_projects(request: Request) -> HTMLResponse:
        projects = discover_projects(_kb_root(request), _jobs_root(request), _journal_path(request))
        return templates.TemplateResponse(request, 'partials/projects_list.html', {
            'projects': projects,
        })

    return router
