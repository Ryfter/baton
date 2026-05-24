from __future__ import annotations

import subprocess

from fastapi import APIRouter

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
