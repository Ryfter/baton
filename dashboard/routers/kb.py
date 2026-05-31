"""Plan 8: GET /kb/search?q=... endpoint + small search panel on the home page."""
from __future__ import annotations

from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates

from kb.embedder import EmbedError
from kb.search import run_search


def build_router(templates: Jinja2Templates) -> APIRouter:
    router = APIRouter()

    def _index_dir(req: Request) -> Path:
        kb_root = getattr(
            req.app.state, "kb_root",
            Path.home() / ".claude" / "knowledge",
        )
        return kb_root / ".index"

    @router.get("/kb/search")
    async def kb_search_json(
        request: Request,
        q: str = "",
        k: int = 5,
        scope: Optional[str] = None,
    ) -> JSONResponse:
        if not q.strip():
            return JSONResponse({"hits": [], "error": None, "query": q})
        try:
            hits = run_search(q, index_dir=_index_dir(request), k=k, scope=scope)
            return JSONResponse({"hits": hits, "error": None, "query": q})
        except EmbedError as e:
            return JSONResponse({"hits": [], "error": str(e), "query": q})

    @router.get("/partials/kb-search", response_class=HTMLResponse)
    async def kb_search_partial(
        request: Request,
        q: str = "",
        k: int = 5,
    ) -> HTMLResponse:
        hits: list[dict] = []
        error: Optional[str] = None
        if q.strip():
            try:
                hits = run_search(q, index_dir=_index_dir(request), k=k)
            except EmbedError as e:
                error = str(e)
        return templates.TemplateResponse(request, "partials/kb_search.html", {
            "hits": hits,
            "error": error,
            "query": q,
        })

    return router
