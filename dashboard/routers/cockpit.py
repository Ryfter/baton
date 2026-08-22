"""Cockpit grid — OctoAlly-shaped active sessions + WebSocket live tails."""
from __future__ import annotations

import asyncio
import json
from pathlib import Path

from fastapi import APIRouter, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from dashboard.paths import baton_home
from dashboard.readers.cockpit_grid import read_cockpit_grid

router = APIRouter(tags=["cockpit"])


def _baton_home(req: Request) -> Path:
    return Path(getattr(req.app.state, "baton_home", None) or baton_home())


def _runs_root(req: Request) -> Path:
    return Path(getattr(req.app.state, "runs_root", None) or baton_home() / "runs")


def build_router(templates: Jinja2Templates) -> APIRouter:
    @router.get("/partials/cockpit-grid", response_class=HTMLResponse)
    async def partial_cockpit_grid(request: Request) -> HTMLResponse:
        grid = read_cockpit_grid(_baton_home(request), _runs_root(request))
        return templates.TemplateResponse(
            request,
            "partials/cockpit_grid.html",
            {"grid": grid},
        )

    @router.get("/api/cockpit-grid")
    async def api_cockpit_grid(request: Request):
        return read_cockpit_grid(_baton_home(request), _runs_root(request))

    @router.websocket("/ws/cockpit")
    async def ws_cockpit(websocket: WebSocket):
        await websocket.accept()
        home = Path(getattr(websocket.app.state, "baton_home", None) or baton_home())
        runs_root = Path(getattr(websocket.app.state, "runs_root", None) or home / "runs")
        last_payload = ""
        try:
            while True:
                payload = read_cockpit_grid(home, runs_root)
                blob = json.dumps(payload, sort_keys=True)
                if blob != last_payload:
                    await websocket.send_json(payload)
                    last_payload = blob
                else:
                    # heartbeat so clients know the socket is alive
                    await websocket.send_json({"schema": 1, "heartbeat": True, "updated_at": payload["updated_at"]})
                await asyncio.sleep(2)
        except WebSocketDisconnect:
            return
        except Exception:
            await websocket.close()

    return router
