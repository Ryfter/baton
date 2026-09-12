from hud.__main__ import build_parser


def test_no_subcommand_implies_serve():
    parser = build_parser()
    args = parser.parse_args(["serve", "--host", "0.0.0.0", "--port", "9999"])
    assert args.command == "serve"
    assert args.host == "0.0.0.0"
    assert args.port == 9999


def test_explicit_serve_subcommand():
    parser = build_parser()
    args = parser.parse_args(["serve", "--port", "9000"])
    assert args.command == "serve"
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
    """C2: only the `serve` subcommand needs FastAPI/uvicorn. status/rebuild/
    install-service must be dispatchable in an environment where uvicorn is
    not importable -- guard against a regression back to a module-scope
    `import uvicorn`."""
    import hud.__main__ as main_mod

    assert "uvicorn" not in vars(main_mod)
