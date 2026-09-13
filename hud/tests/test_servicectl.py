import platform
from pathlib import Path

import pytest

from hud import servicectl


def test_render_launchd_plist_contains_env_and_paths(tmp_path):
    xml = servicectl.render_launchd_plist("/usr/bin/python3", tmp_path, host="0.0.0.0", port=8765)
    assert "dev.baton.hud" in xml
    assert "/usr/bin/python3" in xml
    assert str(tmp_path) in xml
    assert "<key>RunAtLoad</key>" in xml
    assert "<true/>" in xml
    assert "HUD_HOST" in xml and "0.0.0.0" in xml
    assert "HUD_PORT" in xml and "8765" in xml


@pytest.mark.skipif(platform.system() != "Darwin", reason="launchd is macOS-only")
def test_install_macos_service_writes_and_loads(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(servicectl.subprocess, "run",
                         lambda *a, **k: calls.append(a) or servicectl._FakeCompleted())
    dest = tmp_path / "LaunchAgents"
    monkeypatch.setattr(servicectl, "_launch_agents_dir", lambda: dest)
    path = servicectl.install_macos_service(tmp_path, host="0.0.0.0", port=8765)
    assert path == dest / "dev.baton.hud.plist"
    assert path.is_file()
    assert any("launchctl" in str(c) for c in calls)


def test_render_launchd_plist_default_host_is_loopback():
    """Minor item 1: the keyword default was stale (0.0.0.0), inconsistent
    with the only caller's (install_macos_service) 127.0.0.1 default --
    dead today, but exactly the kind of stale default that caused C1."""
    xml = servicectl.render_launchd_plist("/usr/bin/python3", Path("/tmp/repo"))
    assert "<key>HUD_HOST</key><string>127.0.0.1</string>" in xml


@pytest.mark.skipif(platform.system() != "Darwin", reason="launchd is macOS-only")
def test_install_macos_service_raises_on_launchctl_load_failure(tmp_path, monkeypatch):
    """Minor item 5: install_macos_service previously printed "installed: ..."
    even when `launchctl load` failed -- check its returncode and don't
    silently claim success."""
    class _FailedLoad:
        returncode = 1
        stderr = b"launchctl: some failure\n"

    def fake_run(args, **kwargs):
        if args[:2] == ["launchctl", "load"]:
            return _FailedLoad()
        return servicectl._FakeCompleted()

    monkeypatch.setattr(servicectl.subprocess, "run", fake_run)
    dest = tmp_path / "LaunchAgents"
    monkeypatch.setattr(servicectl, "_launch_agents_dir", lambda: dest)
    with pytest.raises(servicectl.ServiceLoadError, match="launchctl load failed"):
        servicectl.install_macos_service(tmp_path, host="127.0.0.1", port=8765)
    # The plist is still written to disk (install got as far as writing it,
    # just the load step failed) -- callers can inspect/retry it.
    assert (dest / servicectl.PLIST_NAME).is_file()


def test_install_service_on_non_macos_is_a_clear_refusal(monkeypatch, tmp_path):
    monkeypatch.setattr(servicectl.platform, "system", lambda: "Linux")
    with pytest.raises(servicectl.UnsupportedPlatform, match="M2"):
        servicectl.install_service(tmp_path)


def test_rebuild_db_reports_counts(isolated_state):
    from hud import store
    store.insert_event({"schema": "hud.event/v1", "ts": "2026-09-12T00:00:00Z", "session_id": "s",
                         "source": "claude-hook", "kind": "stop", "agent": "main", "machine": "m",
                         "payload": {}})
    result = servicectl.rebuild_db()
    assert result["integrity_ok"] is True
    assert result["events"] == 1


def test_status_summary_reachable(live_server):
    from hud import servicectl

    result = servicectl.status_summary("127.0.0.1", live_server["port"])
    assert result["reachable"] is True
    assert "events" in result
    assert "migration_version" in result


def test_status_summary_unreachable_reports_error():
    from hud import servicectl

    result = servicectl.status_summary("127.0.0.1", 1)  # port 1: nothing listens there
    assert result["reachable"] is False
    assert "error" in result
