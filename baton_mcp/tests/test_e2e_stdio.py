"""End-to-end: real stdio server, real bridge, temp BATON_HOME fixtures.

Runs a full MCP stdio round-trip by spawning ``python -m baton_mcp`` as a
subprocess, connecting with the mcp SDK client, and exercising 3 tool calls.

Async body is driven with ``asyncio.run()`` inside a plain sync test so no
pytest-anyio / pytest-asyncio configuration is needed.  The test is skipped
entirely when ``pwsh`` is absent from PATH.
"""
from __future__ import annotations

import asyncio
import json
import os
import shutil
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent

# Skip the whole module if pwsh isn't on PATH — bridge won't work anyway.
pytestmark = pytest.mark.skipif(
    shutil.which("pwsh") is None,
    reason="pwsh is required for the MCP bridge",
)

# Fixture shapes taken verbatim from scripts/test-mcp-bridge.ps1
_FLEET_YAML = """\
research_default: [stub-local]
general_capabilities: [code-gen, reasoning]

providers:
  - name: stub-local
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'pwsh -NoProfile -Command "Write-Output hello"'
  - name: stub-paid
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'pwsh -NoProfile -Command "Write-Output hello"'
  - name: stub-disabled
    kind: cli
    enabled: false
    cost_tier: local
    command_template: 'pwsh -NoProfile -Command "Write-Output nope"'
"""

_TOOLS_YAML = """\
tools:
  - name: docling
    kind: python
    enabled: true
    cost_tier: local
    capability: pdf-extract
    module: docling.document_converter
  - name: git-commit-message
    kind: cli
    enabled: true
    cost_tier: local
    capability: commit-msg
    command_template: 'pwsh -NoProfile -Command "Write-Output hello"'
    stdin: true
"""

_EXPECTED_TOOLS = {
    "baton_capabilities",
    "baton_route",
    "baton_kb_search",
    "baton_job_status",
    "baton_job_list",
    "baton_fleet_list",
    "baton_fleet_doctor",
    "baton_fleet_test",
}


def _seed_baton_home(tmp_path: Path) -> Path:
    """Create a minimal BATON_HOME fixture dir and return it."""
    home = tmp_path / "baton"
    home.mkdir()
    (home / "fleet.yaml").write_text(_FLEET_YAML, encoding="utf-8")
    (home / "tools.yaml").write_text(_TOOLS_YAML, encoding="utf-8")
    return home


async def _run_e2e(home: Path) -> None:
    """Actual async logic — imported lazily so missing mcp client doesn't
    cause a module-level import error (which would turn skip into error)."""
    try:
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client
    except ImportError as exc:
        pytest.skip(f"mcp client not importable: {exc}")

    env = dict(os.environ)
    env["BATON_HOME"] = str(home)
    env["PYTHONPATH"] = str(REPO)
    # Pin the bridge so the test is isolated from the plugin cache path.
    env["BATON_MCP_BRIDGE"] = str(REPO / "scripts" / "mcp-bridge.ps1")

    params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "baton_mcp"],
        env=env,
    )

    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            # ── 1. list_tools: assert all 8 tool names present ──────────────
            tools_result = await session.list_tools()
            names = {t.name for t in tools_result.tools}
            missing = _EXPECTED_TOOLS - names
            assert not missing, f"Missing tools from MCP server: {missing}"

            # ── 2. baton_fleet_list: stub provider proves BATON_HOME is used ─
            fl_result = await session.call_tool("baton_fleet_list", {})
            assert fl_result.content, "baton_fleet_list returned no content"
            payload = json.loads(fl_result.content[0].text)
            assert payload.get("ok") is True, f"baton_fleet_list not ok: {payload}"
            providers = payload.get("providers", [])
            names_found = [p["name"] for p in providers]
            assert "stub-local" in names_found, (
                f"Expected 'stub-local' from fixture fleet.yaml; got {names_found}"
            )

            # ── 3. baton_capabilities: non-empty capabilities list ───────────
            cap_result = await session.call_tool("baton_capabilities", {})
            assert cap_result.content, "baton_capabilities returned no content"
            cap_payload = json.loads(cap_result.content[0].text)
            assert cap_payload.get("ok") is True, f"baton_capabilities not ok: {cap_payload}"
            caps = cap_payload.get("capabilities", [])
            assert len(caps) > 0, "baton_capabilities returned empty capabilities list"


def test_stdio_round_trip(tmp_path: Path) -> None:
    """Spawn the real MCP stdio server and verify list_tools + 2 tool calls."""
    home = _seed_baton_home(tmp_path)
    asyncio.run(_run_e2e(home))


async def _run_mcp_json_launch(home: Path, repo_root: Path) -> None:
    """Launch the server EXACTLY as .mcp.json specifies (the -c bootstrap),
    with no PYTHONPATH / BATON_MCP_BRIDGE and a neutral cwd — the runtime
    CLAUDE_PLUGIN_ROOT env var is the only locator, as under Claude Code.
    Regression for the live failure where ${CLAUDE_PLUGIN_ROOT} was NOT
    substituted in .mcp.json env values and the bridge got a literal template.
    """
    try:
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client
    except ImportError as exc:
        pytest.skip(f"mcp client not importable: {exc}")

    spec = json.loads((repo_root / ".mcp.json").read_text(encoding="utf-8"))
    server = spec["mcpServers"]["baton"]
    assert "env" not in server, ".mcp.json must not rely on env-value substitution"

    env = {k: v for k, v in os.environ.items()
           if k not in ("PYTHONPATH", "BATON_MCP_BRIDGE")}
    env["BATON_HOME"] = str(home)
    env["CLAUDE_PLUGIN_ROOT"] = str(repo_root)  # what Claude sets at runtime

    params = StdioServerParameters(
        command=sys.executable if server["command"] == "python" else server["command"],
        args=server["args"],
        env=env,
        cwd=str(home),  # NOT the repo — module must resolve via the bootstrap
    )

    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            fl_result = await session.call_tool("baton_fleet_list", {})
            payload = json.loads(fl_result.content[0].text)
            assert payload.get("ok") is True, f"baton_fleet_list not ok: {payload}"
            assert "stub-local" in [p["name"] for p in payload.get("providers", [])]


def test_mcp_json_bootstrap_launch(tmp_path: Path) -> None:
    """The .mcp.json -c bootstrap must work with runtime env discovery only."""
    home = _seed_baton_home(tmp_path)
    asyncio.run(_run_mcp_json_launch(home, REPO))
