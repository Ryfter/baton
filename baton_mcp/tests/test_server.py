"""Tests for baton_mcp.server tool functions — run_op monkeypatched."""
from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _ok(**kwargs) -> dict:
    return {"ok": True, **kwargs}


def _fail(error: str = "boom") -> dict:
    return {"ok": False, "error": error}


# ---------------------------------------------------------------------------
# baton_capabilities
# ---------------------------------------------------------------------------

class TestBatonCapabilities:
    def test_delegates_to_capabilities_op(self, monkeypatch):
        import baton_mcp.server as srv
        calls: list = []

        def fake_run_op(op, args=None, **kw):
            calls.append((op, args))
            return _ok(capabilities=["code-gen"])

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        result = srv.baton_capabilities()
        assert calls == [("capabilities", None)]
        assert result["ok"] is True


# ---------------------------------------------------------------------------
# baton_route
# ---------------------------------------------------------------------------

class TestBatonRoute:
    def test_without_prompt_calls_route_select(self, monkeypatch):
        import baton_mcp.server as srv
        calls: list = []

        def fake_run_op(op, args=None, **kw):
            calls.append((op, args))
            return _ok(candidates=[])

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        result = srv.baton_route(capability="code-gen")
        assert len(calls) == 1
        op, args = calls[0]
        assert op == "route-select"
        assert args["capability"] == "code-gen"
        # no extra keys for judge/rank/timeout_s when defaults
        assert "judge" not in args
        assert "rank" not in args
        assert "timeout_s" not in args
        assert "prompt" not in args

    def test_without_prompt_with_max_tier(self, monkeypatch):
        import baton_mcp.server as srv
        calls: list = []

        def fake_run_op(op, args=None, **kw):
            calls.append((op, args))
            return _ok(candidates=[])

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        srv.baton_route(capability="code-gen", max_tier="free")
        op, args = calls[0]
        assert op == "route-select"
        assert args["max_tier"] == "free"

    def test_with_prompt_calls_route_dispatch(self, monkeypatch):
        import baton_mcp.server as srv
        calls: list = []

        def fake_run_op(op, args=None, **kw):
            calls.append((op, args))
            return _ok(status="ok", winner="stub", result="done")

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        result = srv.baton_route(capability="code-gen", prompt="write a sort function")
        assert len(calls) == 1
        op, args = calls[0]
        assert op == "route-dispatch"
        assert args["capability"] == "code-gen"
        assert args["prompt"] == "write a sort function"

    def test_with_prompt_judge_rank_timeout_included_when_set(self, monkeypatch):
        import baton_mcp.server as srv

        captured: list = []

        def fake_run_op(op, args=None, **kw):
            captured.append((op, args, kw))
            return _ok(status="ok")

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        timeout_s = 120
        srv.baton_route(
            capability="code-gen",
            prompt="hello",
            judge=True,
            rank=3,
            timeout_s=timeout_s,
        )
        op, args, kw = captured[0]
        assert op == "route-dispatch"
        assert args["judge"] is True
        assert args["rank"] == 3
        assert args["timeout_s"] == timeout_s
        # Verify the run_op timeout kwarg matches the formula: max(timeout_s + 60, 300)
        assert kw.get("timeout") == max(timeout_s + 60, 300)

    def test_with_prompt_judge_rank_timeout_omitted_when_default(self, monkeypatch):
        import baton_mcp.server as srv

        captured: list = []

        def fake_run_op(op, args=None, **kw):
            captured.append((op, args))
            return _ok(status="ok")

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        srv.baton_route(capability="code-gen", prompt="hello")
        op, args = captured[0]
        assert op == "route-dispatch"
        assert "judge" not in args
        assert "rank" not in args
        assert "timeout_s" not in args

    def test_local_only_passed_through(self, monkeypatch):
        import baton_mcp.server as srv

        captured: list = []

        def fake_run_op(op, args=None, **kw):
            captured.append((op, args))
            return _ok(candidates=[])

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        srv.baton_route(capability="code-gen", local_only=True)
        _, args = captured[0]
        assert args.get("local_only") is True


# ---------------------------------------------------------------------------
# baton_job_list
# ---------------------------------------------------------------------------

class TestBatonJobList:
    def test_passes_filter(self, monkeypatch):
        import baton_mcp.server as srv

        captured: list = []

        def fake_run_op(op, args=None, **kw):
            captured.append((op, args))
            return _ok(jobs=[])

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        srv.baton_job_list(filter="all")
        op, args = captured[0]
        assert op == "job-list"
        assert args == {"filter": "all"}

    def test_default_filter_is_active(self, monkeypatch):
        import baton_mcp.server as srv

        captured: list = []

        def fake_run_op(op, args=None, **kw):
            captured.append((op, args))
            return _ok(jobs=[])

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        srv.baton_job_list()
        _, args = captured[0]
        assert args == {"filter": "active"}


# ---------------------------------------------------------------------------
# baton_fleet_test
# ---------------------------------------------------------------------------

class TestBatonFleetTest:
    def test_passes_name_and_prompt(self, monkeypatch):
        import baton_mcp.server as srv

        captured: list = []

        def fake_run_op(op, args=None, **kw):
            captured.append((op, args))
            return _ok(stdout="hi", exit_code=0)

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        srv.baton_fleet_test(name="stub", prompt="ping")
        op, args = captured[0]
        assert op == "fleet-test"
        assert args["name"] == "stub"
        assert args["prompt"] == "ping"

    def test_model_included_when_set(self, monkeypatch):
        import baton_mcp.server as srv

        captured: list = []

        def fake_run_op(op, args=None, **kw):
            captured.append((op, args))
            return _ok(stdout="hi", exit_code=0)

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        srv.baton_fleet_test(name="stub", prompt="ping", model="llama3")
        _, args = captured[0]
        assert args["model"] == "llama3"

    def test_model_omitted_when_empty(self, monkeypatch):
        import baton_mcp.server as srv

        captured: list = []

        def fake_run_op(op, args=None, **kw):
            captured.append((op, args))
            return _ok(stdout="hi", exit_code=0)

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        srv.baton_fleet_test(name="stub", prompt="ping", model="")
        _, args = captured[0]
        assert "model" not in args


# ---------------------------------------------------------------------------
# baton_kb_search
# ---------------------------------------------------------------------------

class TestBatonKbSearch:
    def test_calls_run_search_and_wraps_hits(self, monkeypatch):
        import baton_mcp.server as srv
        import kb.search as kb_search_mod

        fake_hits = [
            {"score": 0.9, "source": "d001-test.md", "text": "some text",
             "span_start": 0, "span_end": 100, "section": "intro"}
        ]

        def fake_run_search(query, *, index_dir, k=5, scope=None, **kw):
            return fake_hits

        monkeypatch.setattr(kb_search_mod, "run_search", fake_run_search)
        # server imports run_search at call time (inside try block) — patch where it's used
        import importlib
        # Patch in the kb.search module (server does: from kb.search import run_search inside func)
        result = srv.baton_kb_search(query="decisions", k=3, scope="baton")
        assert result["ok"] is True
        assert result["hits"] == fake_hits

    def test_returns_ok_false_when_run_search_raises(self, monkeypatch):
        import baton_mcp.server as srv
        import kb.search as kb_search_mod

        def exploding_run_search(query, *, index_dir, k=5, scope=None, **kw):
            raise RuntimeError("embed server offline")

        monkeypatch.setattr(kb_search_mod, "run_search", exploding_run_search)
        result = srv.baton_kb_search(query="anything")
        assert result["ok"] is False
        assert "error" in result


# ---------------------------------------------------------------------------
# baton_job_status / baton_fleet_list / baton_fleet_doctor
# ---------------------------------------------------------------------------

class TestPassThroughOps:
    def test_job_status_delegates(self, monkeypatch):
        import baton_mcp.server as srv

        captured: list = []

        def fake_run_op(op, args=None, **kw):
            captured.append(op)
            return _ok(active=False)

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        srv.baton_job_status()
        assert captured == ["job-status"]

    def test_fleet_list_delegates(self, monkeypatch):
        import baton_mcp.server as srv

        captured: list = []

        def fake_run_op(op, args=None, **kw):
            captured.append(op)
            return _ok(providers=[])

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        srv.baton_fleet_list()
        assert captured == ["fleet-list"]

    def test_fleet_doctor_delegates(self, monkeypatch):
        import baton_mcp.server as srv

        captured: list = []

        def fake_run_op(op, args=None, **kw):
            captured.append(op)
            return _ok(healthy=True, rows=[])

        monkeypatch.setattr(srv, "run_op", fake_run_op)
        srv.baton_fleet_doctor()
        assert captured == ["fleet-doctor"]


# ---------------------------------------------------------------------------
# FastMCP object importable
# ---------------------------------------------------------------------------

class TestMcpObject:
    def test_mcp_is_fastmcp_instance(self):
        from baton_mcp.server import mcp
        from mcp.server.fastmcp import FastMCP
        assert isinstance(mcp, FastMCP)
