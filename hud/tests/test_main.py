import json
import os
from pathlib import Path

from hud.__main__ import build_parser


def test_explicit_serve_subcommand():
    """Covers explicit `serve` subcommand parsing, both --host and --port.
    (Consolidated with the former test_no_subcommand_implies_serve, which --
    despite its name -- also passed an explicit "serve" argv and was a
    near-duplicate of this test; the actual "no subcommand" backward-compat
    behavior is covered separately by
    test_main_prepends_serve_when_no_known_subcommand below.)"""
    parser = build_parser()
    args = parser.parse_args(["serve", "--host", "0.0.0.0", "--port", "9000"])
    assert args.command == "serve"
    assert args.host == "0.0.0.0"
    assert args.port == 9000


def test_status_subcommand_parses():
    parser = build_parser()
    args = parser.parse_args(["status"])
    assert args.command == "status"


def test_rebuild_subcommand_parses():
    parser = build_parser()
    args = parser.parse_args(["rebuild"])
    assert args.command == "rebuild"


def test_install_service_subcommand_parses():
    parser = build_parser()
    args = parser.parse_args(["install-service"])
    assert args.command == "install-service"


def test_main_prepends_serve_when_no_known_subcommand(monkeypatch):
    import uvicorn

    import hud.__main__ as main_mod
    import hud.server as server_mod
    captured = {}

    def fake_uvicorn_run(app_path, host, port):
        captured["host"] = host
        captured["port"] = port

    # uvicorn is lazily imported inside main()'s serve branch (C2 fix), so
    # patch the real module -- the lazy `import uvicorn` binds to the same
    # cached module object.
    monkeypatch.setattr(uvicorn, "run", fake_uvicorn_run)
    monkeypatch.setattr(server_mod, "warn_if_unauthed_lan", lambda h: None)
    # main()'s serve branch sets os.environ["HUD_HOST"] directly (correct --
    # serve needs it in the real process environment) rather than through
    # monkeypatch, so monkeypatch's own undo log has no record of it. Prime
    # monkeypatch with a throwaway setenv first: its teardown restores
    # whatever HUD_HOST's value (or absence) truly was before this test,
    # no matter what main() does to it in between -- this is what fixes the
    # "0.0.0.0" leaking into the rest of the test session.
    monkeypatch.setenv("HUD_HOST", os.environ.get("HUD_HOST", "unset-before-test"))
    rc = main_mod.main(["--host", "0.0.0.0", "--port", "9999"])
    assert rc == 0
    assert captured == {"host": "0.0.0.0", "port": 9999}


def test_install_service_subcommand_has_host_port_flags():
    parser = build_parser()
    args = parser.parse_args(["install-service", "--host", "0.0.0.0", "--port", "18765"])
    assert args.command == "install-service"
    assert args.host == "0.0.0.0"
    assert args.port == 18765


def test_install_service_defaults_to_loopback(monkeypatch):
    # HUD_HOST is deliberately cleared: an earlier test in this session may
    # have set it via a real main() serve-branch call (os.environ, not
    # monkeypatch-scoped there), and this test asserts the *default* --
    # i.e. what happens with no HUD_HOST override at all.
    monkeypatch.delenv("HUD_HOST", raising=False)
    monkeypatch.delenv("HUD_PORT", raising=False)
    parser = build_parser()
    args = parser.parse_args(["install-service"])
    assert args.host == "127.0.0.1"
    assert args.port == 8765


def test_main_module_namespace_has_no_eager_uvicorn_import():
    """C2 (narrow/fast check): guards specifically against a regression back
    to a module-scope `import uvicorn` in hud/__main__.py. This does NOT
    catch a regression via a *different* eager import that transitively
    pulls in FastAPI/uvicorn (e.g. re-adding
    `from hud.server import warn_if_unauthed_lan` at module scope) -- see
    test_status_subcommand_works_without_uvicorn_or_fastapi_importable below
    for the real regression-class test."""
    import hud.__main__ as main_mod

    assert "uvicorn" not in vars(main_mod)


_BLOCKER_PREAMBLE = (
    "import sys\n"
    "class _Blocker:\n"
    "    def find_spec(self, name, path=None, target=None):\n"
    "        if name in ('uvicorn', 'fastapi') or name.startswith(('uvicorn.', 'fastapi.')):\n"
    "            raise ModuleNotFoundError('blocked for test: ' + name)\n"
    "        return None\n"
    "sys.meta_path.insert(0, _Blocker())\n"
)


def _run_hud_main_with_fastapi_blocked(argv, repo_root, extra_preamble=""):
    """Shared helper (I-1): run `python -m hud <argv>` as a real subprocess,
    using the SAME interpreter as sys.executable, with a meta path finder
    that makes uvicorn/fastapi raise ModuleNotFoundError if anything tries to
    import them anywhere in the call chain -- the actual regression class C2
    (and its I-1 recurrence, via `install-service`) needs to be caught by."""
    import subprocess
    import sys

    script = (
        _BLOCKER_PREAMBLE
        + extra_preamble
        + "sys.argv = ['hud'] + %r\n" % (argv,)
        + "import runpy\n"
        "runpy.run_module('hud.__main__', run_name='__main__')\n"
    )
    return subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        timeout=10,
        cwd=str(repo_root),
        env={**os.environ, "PYTHONPATH": str(repo_root)},
    )


def test_status_subcommand_works_without_uvicorn_or_fastapi_importable(tmp_path):
    """C2, strengthened: `status` (and rebuild/install-service) must not need
    uvicorn or FastAPI importable AT ALL -- not just absent from
    hud.__main__'s own namespace. Pointed at a port nothing listens on, a
    clean `{"reachable": false, ...}` JSON reply (not a traceback) proves no
    ModuleNotFoundError occurred anywhere in the import chain."""
    repo_root = Path(__file__).resolve().parents[2]
    result = _run_hud_main_with_fastapi_blocked(
        ["status", "--host", "127.0.0.1", "--port", "1"], repo_root
    )
    assert "Traceback" not in result.stderr, result.stderr
    assert "ModuleNotFoundError" not in result.stderr, result.stderr
    body = json.loads(result.stdout)
    assert body["reachable"] is False
    assert result.returncode == 1  # status's own exit code for "not reachable"


def test_install_service_subcommand_works_without_uvicorn_or_fastapi_importable(tmp_path):
    """I-1 regression test: minor item 6 of the M1 cleanup pass reintroduced
    the C2 bug specifically for `install-service`, by adding
    `from hud.server import warn_if_unauthed_lan` (hud/server.py imports
    FastAPI/starlette at module scope) into that branch. Forces
    platform.system() to report a non-Darwin platform BEFORE importing
    hud.__main__, so `install_service()` hits its `UnsupportedPlatform`
    refusal path -- which doesn't need FastAPI either, and (unlike the real
    Darwin path) never shells out to real `launchctl` or writes a real
    launchd plist, so this is safe to run on any host including this dev
    Mac. A clean, traceback-free refusal message proves the import chain
    (including the module-scope `from hud.servicectl import
    warn_if_unauthed_lan`) doesn't crash before ever reaching that check."""
    repo_root = Path(__file__).resolve().parents[2]
    result = _run_hud_main_with_fastapi_blocked(
        ["install-service", "--host", "127.0.0.1", "--port", "1"],
        repo_root,
        extra_preamble="import platform\nplatform.system = lambda: 'Linux'\n",
    )
    assert "Traceback" not in result.stderr, result.stderr
    assert "ModuleNotFoundError" not in result.stderr, result.stderr
    assert "M2" in result.stderr  # UnsupportedPlatform's message
    assert result.returncode == 1
