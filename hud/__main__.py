"""python -m hud → uvicorn hud.server:app --host $HUD_HOST --port $HUD_PORT."""
from __future__ import annotations

import argparse
import os

import uvicorn


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="hud", description="Baton HUD prototype")
    parser.add_argument(
        "--host",
        default=os.environ.get("HUD_HOST", "0.0.0.0"),
        help="bind host (env HUD_HOST, default 0.0.0.0)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("HUD_PORT", "8765")),
        help="bind port (env HUD_PORT, default 8765)",
    )
    args = parser.parse_args(argv)
    uvicorn.run("hud.server:app", host=args.host, port=args.port)


if __name__ == "__main__":
    main()
