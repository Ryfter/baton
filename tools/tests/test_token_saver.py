"""Tests for token-saver scripts bundled under tools/token_saver/."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TS = ROOT / "token_saver"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, *args],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def test_state_delta_save_and_packet(tmp_path: Path) -> None:
    state = tmp_path / "state.json"
    accepted = tmp_path / "accepted.md"
    accepted.write_text("hello world", encoding="utf-8")
    save = run(
        str(TS / "state_delta.py"),
        "save",
        "--state",
        str(state),
        "--accepted-file",
        str(accepted),
    )
    assert save.returncode == 0, save.stderr
    meta = json.loads(save.stdout)
    assert meta["accepted_result_bytes"] == 11

    out = tmp_path / "packet.txt"
    pkt = run(
        str(TS / "state_delta.py"),
        "packet",
        "--state",
        str(state),
        "--change",
        "make it bold",
        "--output",
        str(out),
    )
    assert pkt.returncode == 0, pkt.stderr
    body = out.read_text(encoding="utf-8")
    assert "hello world" in body
    assert "make it bold" in body


def test_select_context_on_small_tree(tmp_path: Path) -> None:
    src = tmp_path / "notes.txt"
    src.write_text(
        "Wednesday we decided to ship npm first.\n"
        "Thursday was about BookProfile hybrid surface.\n",
        encoding="utf-8",
    )
    out = tmp_path / "packet.txt"
    rep = tmp_path / "report.json"
    proc = run(
        str(TS / "select_context.py"),
        "--request",
        "What did we decide about npm?",
        "--source",
        str(src),
        "--max-packet-bytes",
        "8000",
        "--output",
        str(out),
        "--report",
        str(rep),
    )
    assert proc.returncode == 0, proc.stderr
    packet = out.read_text(encoding="utf-8")
    assert "npm" in packet.lower()
    report = json.loads(rep.read_text(encoding="utf-8"))
    assert report["selected_source_bytes"] > 0
