"""python -m hud [serve|status|install-service|rebuild] -- see `python -m hud --help`."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

_KNOWN_COMMANDS = {"serve", "status", "install-service", "rebuild"}
_REPO_ROOT = Path(__file__).resolve().parent.parent


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="hud", description="Baton HUD")
    sub = parser.add_subparsers(dest="command")

    serve_p = sub.add_parser("serve", help="run the HUD server (default)")
    serve_p.add_argument("--host", default=os.environ.get("HUD_HOST", "127.0.0.1"))
    serve_p.add_argument("--port", type=int, default=int(os.environ.get("HUD_PORT", "8765")))

    status_p = sub.add_parser("status", help="query a running HUD's /healthz")
    status_p.add_argument("--host", default=os.environ.get("HUD_HOST", "127.0.0.1"))
    status_p.add_argument("--port", type=int, default=int(os.environ.get("HUD_PORT", "8765")))
    status_p.add_argument("--token", default=os.environ.get("HUD_TOKEN", ""))

    install_p = sub.add_parser("install-service", help="install the platform service unit (macOS: launchd)")
    # Default matches `serve`'s own default: loopback-only. A LAN-bound service
    # is opt-in via an explicit --host 0.0.0.0, exactly like `serve`.
    install_p.add_argument("--host", default=os.environ.get("HUD_HOST", "127.0.0.1"))
    install_p.add_argument("--port", type=int, default=int(os.environ.get("HUD_PORT", "8765")))

    sub.add_parser("rebuild", help="WAL checkpoint + integrity check (+ sessions rebuild from M4)")

    return parser


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] not in _KNOWN_COMMANDS:
        argv = ["serve"] + argv
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "serve":
        import uvicorn
        from hud.server import warn_if_unauthed_lan

        os.environ["HUD_HOST"] = args.host
        warn_if_unauthed_lan(args.host)
        uvicorn.run("hud.server:app", host=args.host, port=args.port)
        return 0

    if args.command == "status":
        from hud import servicectl
        result = servicectl.status_summary(args.host, args.port, token=args.token)
        print(json.dumps(result, indent=2))
        return 0 if result.get("reachable") else 1

    if args.command == "install-service":
        from hud import servicectl
        try:
            path = servicectl.install_service(_REPO_ROOT, host=args.host, port=args.port)
        except servicectl.UnsupportedPlatform as exc:
            print(str(exc), file=sys.stderr)
            return 1
        print("installed: %s" % path)
        return 0

    if args.command == "rebuild":
        from hud import servicectl
        result = servicectl.rebuild_db()
        print(json.dumps(result, indent=2))
        return 0 if result.get("integrity_ok") else 1

    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
