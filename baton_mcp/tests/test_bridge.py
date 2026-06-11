"""Tests for baton_mcp.bridge — subprocess plumbing to mcp-bridge.ps1."""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_proc(stdout: str = "", returncode: int = 0) -> MagicMock:
    proc = MagicMock()
    proc.stdout = stdout
    proc.returncode = returncode
    proc.stderr = ""
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

        def fake_run(cmd, **kwargs):
            captured["cmd"] = cmd
            return _make_proc('{"ok": true}')

        monkeypatch.setattr(subprocess, "run", fake_run)
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

        def fake_run(cmd, **kwargs):
            captured["cmd"] = cmd
            # Simulate reading the args file before it gets deleted
            argspath_idx = cmd.index("-ArgsPath")
            captured["argsfile"] = cmd[argspath_idx + 1]
            captured["argsfile_content"] = Path(captured["argsfile"]).read_text(encoding="utf-8")
            return _make_proc('{"ok": true, "capabilities": ["code-gen"]}')

        monkeypatch.setattr(subprocess, "run", fake_run)
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

        def fake_run(cmd, **kwargs):
            if "-ArgsPath" in cmd:
                idx = cmd.index("-ArgsPath")
                captured_argspath.append(cmd[idx + 1])
            return _make_proc('{"ok": true}')

        monkeypatch.setattr(subprocess, "run", fake_run)
        monkeypatch.setattr(Path, "unlink", tracking_unlink)
        run_op("route-select", {"capability": "code-gen"})

        assert len(captured_argspath) == 1
        assert captured_argspath[0] in deleted_paths

    def test_args_file_deleted_even_on_exception(self, monkeypatch):
        from baton_mcp.bridge import run_op
        deleted_paths: list[str] = []
        original_unlink = Path.unlink
        captured_argspath: list[str] = []

        def tracking_unlink(self, missing_ok=False):
            deleted_paths.append(str(self))
            original_unlink(self, missing_ok=missing_ok)

        def fake_run(cmd, **kwargs):
            if "-ArgsPath" in cmd:
                idx = cmd.index("-ArgsPath")
                captured_argspath.append(cmd[idx + 1])
            raise subprocess.TimeoutExpired(cmd, 10)

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

        def fake_run(cmd, **kwargs):
            return _make_proc(
                "Verbose: dot-sourcing routing-lib.ps1\nDebug: loading tools.yaml\n"
                '{"ok": true, "capabilities": ["code-gen", "review"]}'
            )

        monkeypatch.setattr(subprocess, "run", fake_run)
        result = run_op("capabilities")
        assert result == {"ok": True, "capabilities": ["code-gen", "review"]}

    def test_empty_stdout_returns_ok_false(self, monkeypatch):
        from baton_mcp.bridge import run_op

        def fake_run(cmd, **kwargs):
            return _make_proc("")

        monkeypatch.setattr(subprocess, "run", fake_run)
        result = run_op("capabilities")
        assert result["ok"] is False
        assert "error" in result

    def test_non_json_stdout_returns_ok_false(self, monkeypatch):
        from baton_mcp.bridge import run_op

        def fake_run(cmd, **kwargs):
            return _make_proc("this is not json at all")

        monkeypatch.setattr(subprocess, "run", fake_run)
        result = run_op("capabilities")
        assert result["ok"] is False
        assert "error" in result

    def test_timeout_expired_returns_ok_false(self, monkeypatch):
        from baton_mcp.bridge import run_op

        def fake_run(cmd, **kwargs):
            raise subprocess.TimeoutExpired(cmd, 10)

        monkeypatch.setattr(subprocess, "run", fake_run)
        result = run_op("fleet-test", {"name": "stub", "prompt": "hi"}, timeout=10)
        assert result["ok"] is False
        assert "timed out" in result["error"].lower()

    def test_file_not_found_returns_ok_false(self, monkeypatch):
        from baton_mcp.bridge import run_op

        def fake_run(cmd, **kwargs):
            raise FileNotFoundError("pwsh not found")

        monkeypatch.setattr(subprocess, "run", fake_run)
        result = run_op("capabilities")
        assert result["ok"] is False
        assert "pwsh" in result["error"].lower() or "not found" in result["error"].lower()
