"""Baton MCP server — cross-tool surface over the same BATON_HOME state.

Thin adapter per the Phase 3 spec: every tool shells into the existing
PowerShell libs via scripts/mcp-bridge.ps1, except baton_kb_search which calls
the kb package in-process (it is already Python).
"""
from __future__ import annotations

from pathlib import Path

from mcp.server.fastmcp import FastMCP

from baton_mcp.bridge import run_op

mcp = FastMCP("baton")

# Default KB index dir — matches kb/search.py CLI default
_DEFAULT_INDEX_DIR = Path.home() / ".claude" / "knowledge" / ".index"


@mcp.tool()
def baton_capabilities() -> dict:
    """List every capability the Baton router knows (tools.yaml + fleet general capabilities)."""
    return run_op("capabilities")


@mcp.tool()
def baton_route(capability: str, prompt: str = "", max_tier: str = "", local_only: bool = False,
                judge: bool = False, rank: int = 0, timeout_s: int = 0) -> dict:
    """Route a capability to the cheapest capable tool/model.

    Without prompt: returns the ranked candidate ladder (recommendation only).
    With prompt: dispatches up the ladder (cheapest first), verifies output, escalates
    on failure; returns winner + attempts. max_tier caps spend ('local'|'free'|'paid');
    rank (1-5) feeds the prime-hours paid gate; judge enables LLM-judge grading.
    """
    args: dict = {"capability": capability}
    if max_tier:
        args["max_tier"] = max_tier
    if local_only:
        args["local_only"] = True
    if prompt:
        args["prompt"] = prompt
        if judge:
            args["judge"] = True
        if rank:
            args["rank"] = rank
        if timeout_s:
            args["timeout_s"] = timeout_s
        return run_op("route-dispatch", args, timeout=max(timeout_s + 60, 300))
    return run_op("route-select", args)


@mcp.tool()
def baton_kb_search(query: str, k: int = 5, scope: str = "all") -> dict:
    """Semantic search over the shared knowledge base (decisions, lessons, specs).

    scope: 'all', 'universal', or a project id (e.g. 'baton')."""
    try:
        from kb.search import run_search  # in-process: kb IS the implementation
        # run_search requires index_dir as keyword-only; scope=None means all
        scope_arg = None if scope == "all" else scope
        hits = run_search(
            query,
            index_dir=_DEFAULT_INDEX_DIR,
            k=k,
            scope=scope_arg,
        )
        return {"ok": True, "hits": hits}
    except Exception as e:  # noqa: BLE001 — MCP tools return structured errors
        return {"ok": False, "error": str(e)}


@mcp.tool()
def baton_job_status() -> dict:
    """Show the active Baton job (id, phase, manifest) from BATON_HOME, if any."""
    return run_op("job-status")


@mcp.tool()
def baton_job_list(filter: str = "active") -> dict:
    """List Baton jobs. filter: 'active' (default), 'done', or 'all'."""
    return run_op("job-list", {"filter": filter})


@mcp.tool()
def baton_fleet_list() -> dict:
    """List the registered fleet providers (name, kind, enabled, cost tier)."""
    return run_op("fleet-list")


@mcp.tool()
def baton_fleet_doctor() -> dict:
    """Health-check every enabled fleet provider (PATH/HTTP reachability)."""
    return run_op("fleet-doctor")


@mcp.tool()
def baton_fleet_test(name: str, prompt: str, model: str = "") -> dict:
    """Dispatch one prompt to one named fleet provider and return stdout/exit/duration."""
    args = {"name": name, "prompt": prompt}
    if model:
        args["model"] = model
    return run_op("fleet-test", args, timeout=300)


def main() -> None:
    mcp.run()  # stdio transport


if __name__ == "__main__":
    main()
