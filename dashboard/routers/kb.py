"""Plan 8: GET /kb/search?q=... endpoint + small search panel on the home page.

Plan 8.3 (#18): decision-record hits in the search panel are click-through — the
GET /partials/decision route renders a decision markdown file into a detail panel,
restricted to actual decision records under the knowledge root.
"""
from __future__ import annotations

import html
import re
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates

from kb.embedder import EmbedError
from kb.search import run_search

# A decision record: lives in a `decisions` directory and is named d<...>.md.
_DECISION_NAME_RE = re.compile(r"^d.*\.md$", re.IGNORECASE)


def is_decision_path(path: str) -> bool:
    """True when `path` looks like a decision record (decisions/ dir + d*.md name)."""
    if not path:
        return False
    p = Path(path)
    parts = [seg.lower() for seg in p.parts]
    return "decisions" in parts and bool(_DECISION_NAME_RE.match(p.name))


def _render_markdown(text: str) -> str:
    """Render markdown to HTML; fall back to an escaped <pre> if no lib is present.
    Source is a trusted, path-restricted KB file, so the result is rendered as-is."""
    try:
        import markdown  # optional dependency
        return markdown.markdown(text, extensions=["fenced_code", "tables"])
    except Exception:
        return "<pre class=\"decision-raw\">" + html.escape(text) + "</pre>"


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

    @router.get("/partials/decision", response_class=HTMLResponse)
    async def decision_detail(request: Request, path: str = "") -> HTMLResponse:
        """Render a decision record into the detail panel. Hardened: only serves a
        file that resolves to inside the knowledge root, sits in a `decisions` dir,
        and is named d*.md — so an arbitrary ?path= cannot read other files."""
        kb_root = getattr(request.app.state, "kb_root", Path.home() / ".claude" / "knowledge")
        name = ""
        body_html = ""
        error: Optional[str] = None
        try:
            root = Path(kb_root).resolve()
            target = Path(path).resolve()
            under_root = root == target or root in target.parents
            if not (path and under_root and is_decision_path(str(target)) and target.is_file()):
                error = "Not a valid decision record."
            else:
                name = target.name
                body_html = _render_markdown(target.read_text(encoding="utf-8"))
        except Exception as e:  # pragma: no cover - defensive
            error = f"Could not open decision: {e}"
        return templates.TemplateResponse(request, "partials/decision_detail.html", {
            "name": name,
            "body_html": body_html,
            "error": error,
        })

    return router
