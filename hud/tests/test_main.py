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
    import hud.__main__ as main_mod
    captured = {}

    def fake_uvicorn_run(app_path, host, port):
        captured["host"] = host
        captured["port"] = port

    monkeypatch.setattr(main_mod.uvicorn, "run", fake_uvicorn_run)
    monkeypatch.setattr(main_mod, "warn_if_unauthed_lan", lambda h: None)
    rc = main_mod.main(["--host", "0.0.0.0", "--port", "9999"])
    assert rc == 0
    assert captured == {"host": "0.0.0.0", "port": 9999}
