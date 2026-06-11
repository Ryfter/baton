"""Tests for baton_mcp.bridge — subprocess plumbing to mcp-bridge.ps1."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_popen(stdout: str = "", returncode: int = 0, stderr: str = "") -> MagicMock:
    """Return a fake Popen object whose communicate() returns (stdout, stderr)."""
    proc = MagicMock()
    proc.pid = 12345
    proc.returncode = returncode
    proc.communicate.return_value = (stdout, stderr)
    return proc


def _make_popen_timeout(cmd_placeholder=None) -> MagicMock:
    """Return a fake Popen whose first communicate() raises TimeoutExpired; drain returns ('','')."""
    proc = MagicMock()
    proc.pid = 12345
    proc.returncode = -1
    # side_effect as a list: first call raises, second (drain) returns normally
    proc.communicate.side_effect = [
        subprocess.TimeoutExpired(cmd_placeholder or ["pwsh"], 10),
        ("", ""),
    ]
    return proc


# ---------------------------------------------------------------------------
# bridge_script()
# ---------------------------------------------------------------------------

class TestBridgeScript:
    def test_default_resolves_relative_to_package(self):
        from baton_mcp.bridge import bridge_script
        p = bridge_script()
        assert p.name == "mcp-bridge.ps1"
        assert p.parent.name == "scripts"

    def test_env_override_is_respected(self, monkeypatch):
        import importlib
        import os
        from baton_mcp import bridge as bridge_mod

        custom = os.path.normpath("/custom/path/bridge.ps1")
        monkeypatch.setenv("BATON_MCP_BRIDGE", custom)
        importlib.reload(bridge_mod)
        p = bridge_mod.bridge_script()
        assert str(p) == custom
        # clean up: restore by reloading without env var
        monkeypatch.delenv("BATON_MCP_BRIDGE", raising=False)
        importlib.reload(bridge_mod)


# ---------------------------------------------------------------------------
# run_op() — command shape
# ---------------------------------------------------------------------------

class TestRunOpCommandShape:
    def test_no_args_omits_argspath(self, monkeypatch):
        from baton_mcp.bridge import run_op
        captured = {}

        def fake_popen(cmd, **kwargs):
            captured["cmd"] = cmd
            return _make_popen('{"ok": true}')

        monkeypatch.setattr(subprocess, "Popen", fake_popen)
        run_op("capabilities")
        cmd = captured["cmd"]
        assert cmd[0] == "pwsh"
        assert "-NoProfile" in cmd
        assert "-File" in cmd
        # bridge script comes right after -File
        file_idx = cmd.index("-File")
        assert cmd[file_idx + 1].endswith("mcp-bridge.ps1")
        assert "-Op" in cmd
        op_idx = cmd.index("-Op")
        assert cmd[op_idx + 1] == "capabilities"
        assert "-ArgsPath" not in cmd

    def test_with_args_includes_argspath(self, monkeypatch):
        from baton_mcp.bridge import run_op
        captured = {}

        def fake_popen(cmd, **kwargs):
            captured["cmd"] = cmd
            # Simulate reading the args file before it gets deleted
            argspath_idx = cmd.index("-ArgsPath")
            captured["argsfile"] = cmd[argspath_idx + 1]
            captured["argsfile_content"] = Path(captured["argsfile"]).read_text(encoding="utf-8")
            return _make_popen('{"ok": true, "capabilities": ["code-gen"]}')

        monkeypatch.setattr(subprocess, "Popen", fake_popen)
        run_op("route-select", {"capability": "code-gen"})

        cmd = captured["cmd"]
        assert "-ArgsPath" in cmd
        # Args file content round-trips
        payload = json.loads(captured["argsfile_content"])
        assert payload == {"capability": "code-gen"}

    def test_args_file_is_deleted_after_call(self, monkeypatch):
        from baton_mcp.bridge import run_op
        deleted_paths: list[str] = []
        original_unlink = Path.unlink

        def tracking_unlink(self, missing_ok=False):
            deleted_paths.append(str(self))
            original_unlink(self, missing_ok=missing_ok)

        captured_argspath: list[str] = []

        def fake_popen(cmd, **kwargs):
            if "-ArgsPath" in cmd:
                idx = cmd.index("-ArgsPath")
                captured_argspath.append(cmd[idx + 1])
            return _make_popen('{"ok": true}')

        monkeypatch.setattr(subprocess, "Popen", fake_popen)
        monkeypatch.setattr(Path, "unlink", tracking_unlink)
        run_op("route-select", {"capability": "code-gen"})

        assert len(captured_argspath) == 1
        assert captured_argspath[0] in deleted_paths

    def test_args_file_deleted_even_on_timeout(self, monkeypatch):
        from baton_mcp.bridge import run_op
        deleted_paths: list[str] = []
        original_unlink = Path.unlink
        captured_argspath: list[str] = []

        def tracking_unlink(self, missing_ok=False):
            deleted_paths.append(str(self))
            original_unlink(self, missing_ok=missing_ok)

        def fake_popen(cmd, **kwargs):
            if "-ArgsPath" in cmd:
                idx = cmd.index("-ArgsPath")
                captured_argspath.append(cmd[idx + 1])
            return _make_popen_timeout(cmd)

        # Suppress taskkill/kill side-effects
        def fake_run(cmd, **kwargs):
            return MagicMock(returncode=0)

        monkeypatch.setattr(subprocess, "Popen", fake_popen)
        monkeypatch.setattr(subprocess, "run", fake_run)
        monkeypatch.setattr(Path, "unlink", tracking_unlink)
        result = run_op("fleet-test", {"name": "stub", "prompt": "hi"}, timeout=10)
        assert result["ok"] is False
        # File should still be cleaned up
        assert len(captured_argspath) == 1
        assert captured_argspath[0] in deleted_paths


# ---------------------------------------------------------------------------
# run_op() — stdout parsing
# ---------------------------------------------------------------------------

class TestRunOpStdoutParsing:
    def test_parses_last_line_as_json(self, monkeypatch):
        """Multi-line stdout: chatter before the JSON envelope is ignored."""
        from baton_mcp.bridge import run_op

        def fake_popen(cmd, **kwargs):
            return _make_popen(
                "Verbose: dot-sourcing routing-lib.ps1\nDebug: loading tools.yaml\n"
                '{"ok": true, "capabilities": ["code-gen", "review"]}'
            )

        monkeypatch.setattr(subprocess, "Popen", fake_popen)
        result = run_op("capabilities")
        assert result == {"ok": True, "capabilities": ["code-gen", "review"]}

    def test_empty_stdout_returns_ok_false(self, monkeypatch):
        from baton_mcp.bridge import run_op

        def fake_popen(cmd, **kwargs):
            return _make_popen("")

        monkeypatch.setattr(subprocess, "Popen", fake_popen)
        result = run_op("capabilities")
        assert result["ok"] is False
        assert "error" in result

    def test_non_json_stdout_returns_ok_false(self, monkeypatch):
        from baton_mcp.bridge import run_op

        def fake_popen(cmd, **kwargs):
            return _make_popen("this is not json at all")

        monkeypatch.setattr(subprocess, "Popen", fake_popen)
        result = run_op("capabilities")
        assert result["ok"] is False
        assert "error" in result

    def test_timeout_expired_returns_ok_false(self, monkeypatch):
        from baton_mcp.bridge import run_op

        def fake_popen(cmd, **kwargs):
            return _make_popen_timeout(cmd)

        def fake_run(cmd, **kwargs):
            return MagicMock(returncode=0)

        monkeypatch.setattr(subprocess, "Popen", fake_popen)
        monkeypatch.setattr(subprocess, "run", fake_run)
        result = run_op("fleet-test", {"name": "stub", "prompt": "hi"}, timeout=10)
        assert result["ok"] is False
        assert "timed out" in result["error"].lower()

    def test_file_not_found_returns_ok_false(self, monkeypatch):
        from baton_mcp.bridge import run_op

        def fake_popen(cmd, **kwargs):
            raise FileNotFoundError("pwsh not found")

        monkeypatch.setattr(subprocess, "Popen", fake_popen)
        result = run_op("capabilities")
        assert result["ok"] is False
        assert "pwsh" in result["error"].lower() or "not found" in result["error"].lower()


# ---------------------------------------------------------------------------
# run_op() — TimeoutExpired path attempts taskkill on win32
# ---------------------------------------------------------------------------

class TestTimeoutKill:
    def test_timeout_attempts_taskkill_on_win32(self, monkeypatch):
        """On TimeoutExpired the bridge should call taskkill /PID <pid> /T /F on win32."""
        from baton_mcp import bridge as bridge_mod

        taskkill_calls: list[list] = []

        def fake_popen(cmd, **kwargs):
            proc = _make_popen_timeout(cmd)
            proc.pid = 99999
            return proc

        def fake_run(cmd, **kwargs):
            taskkill_calls.append(list(cmd))
            return MagicMock(returncode=0)

        monkeypatch.setattr(subprocess, "Popen", fake_popen)
        monkeypatch.setattr(subprocess, "run", fake_run)
        monkeypatch.setattr(bridge_mod.sys, "platform", "win32")

        result = bridge_mod.run_op("capabilities", timeout=5)
        assert result["ok"] is False
        assert "timed out" in result["error"].lower()
        # taskkill must have been called with the proc's PID
        assert any(
            "taskkill" in str(c[0]).lower() and "99999" in c
            for c in taskkill_calls
        ), f"expected taskkill call with PID 99999, got: {taskkill_calls}"

    def test_timeout_uses_kill_on_non_win32(self, monkeypatch):
        """On non-win32 the bridge falls back to proc.kill() instead of taskkill."""
        from baton_mcp import bridge as bridge_mod

        taskkill_calls: list[list] = []
        kill_called = []

        def fake_popen(cmd, **kwargs):
            proc = _make_popen_timeout(cmd)
            proc.pid = 88888
            proc.kill = lambda: kill_called.append(True)
            return proc

        def fake_run(cmd, **kwargs):
            taskkill_calls.append(list(cmd))
            return MagicMock(returncode=0)

        monkeypatch.setattr(subprocess, "Popen", fake_popen)
        monkeypatch.setattr(subprocess, "run", fake_run)
        monkeypatch.setattr(bridge_mod.sys, "platform", "linux")

        result = bridge_mod.run_op("capabilities", timeout=5)
        assert result["ok"] is False
        assert "timed out" in result["error"].lower()
        assert kill_called, "proc.kill() should have been called on non-win32"
        assert not any("taskkill" in str(c[0]).lower() for c in taskkill_calls), \
            "taskkill should NOT be called on non-win32"
