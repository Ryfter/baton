from __future__ import annotations

import subprocess

from fastapi import APIRouter, Query

router = APIRouter()


@router.post("/controls/ollama/stop-all")
async def ollama_stop_all() -> dict[str, list[str] | int]:
    result = subprocess.run(
        ["ollama", "ps"],
        capture_output=True,
        text=True,
        timeout=10,
    )

    stopped: list[str] = []
    for line in result.stdout.strip().splitlines()[1:]:
        parts = line.split()
        if not parts:
            continue

        model_name = parts[0]
        subprocess.run(
            ["ollama", "stop", model_name],
            capture_output=True,
            text=True,
            timeout=10,
        )
        stopped.append(model_name)

    return {"stopped": stopped, "count": len(stopped)}


@router.post("/controls/lmstudio/load")
async def lmstudio_load(model: str = Query(..., description="Model identifier to load")) -> dict:
    """Load a model in LM Studio via `lms load <model> --gpu max`."""
    result = subprocess.run(
        ["lms", "load", model, "--gpu", "max"],
        capture_output=True, text=True, timeout=120,
    )
    return {
        "success": result.returncode == 0,
        "model": model,
        "output": (result.stdout or result.stderr or "").strip(),
    }


@router.post("/controls/lmstudio/unload")
async def lmstudio_unload(model: str = Query(..., description="Model identifier to unload")) -> dict:
    """Unload a model from LM Studio via `lms unload <model>`."""
    result = subprocess.run(
        ["lms", "unload", model],
        capture_output=True, text=True, timeout=30,
    )
    return {
        "success": result.returncode == 0,
        "model": model,
        "output": (result.stdout or result.stderr or "").strip(),
    }


@router.post("/controls/lmstudio/server/stop")
async def lmstudio_server_stop() -> dict:
    """Stop the LM Studio local server via `lms server stop`."""
    result = subprocess.run(
        ["lms", "server", "stop"],
        capture_output=True, text=True, timeout=15,
    )
    return {
        "success": result.returncode == 0,
        "output": (result.stdout or result.stderr or "").strip(),
    }
