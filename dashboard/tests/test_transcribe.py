"""Factory STT reader — mocked engines, no live mlx."""
from __future__ import annotations

from unittest.mock import patch

from dashboard.readers import transcribe as tr


def test_engine_status_shape():
    status = tr.engine_status()
    assert status["schema"] == 1
    assert "available" in status["factory"]
    assert status["this_computer"]["engine"] == "Web Speech API"


def test_transcribe_rejects_empty():
    try:
        tr.transcribe_bytes(b"")
        assert False, "expected ValueError"
    except ValueError as exc:
        assert "empty" in str(exc)


def test_transcribe_rejects_huge():
    try:
        tr.transcribe_bytes(b"x" * (tr.MAX_BYTES + 1))
        assert False, "expected ValueError"
    except ValueError as exc:
        assert "too large" in str(exc)


def test_transcribe_success_mocked(tmp_path, monkeypatch):
    def fake_which(name):
        return f"/bin/{name}"

    class Result:
        def __init__(self, code=0, stderr=b""):
            self.returncode = code
            self.stderr = stderr

    def fake_run(cmd, **kwargs):
        # ffmpeg writes wav; mlx writes txt — create whichever the cmd implies
        if cmd and str(cmd[0]).endswith("ffmpeg"):
            Path_wav = None
            for part in cmd:
                if str(part).endswith(".wav"):
                    Path_wav = part
            if Path_wav:
                from pathlib import Path
                Path(Path_wav).write_bytes(b"RIFF")
            return Result(0)
        if cmd and "mlx_whisper" in str(cmd[0]):
            from pathlib import Path
            out = None
            for i, part in enumerate(cmd):
                if part == "--output-dir":
                    out = Path(cmd[i + 1])
            if out:
                (out / "in.txt").write_text("ship the front door\n", encoding="utf-8")
            return Result(0)
        return Result(1, b"unknown")

    monkeypatch.setattr(tr.shutil, "which", fake_which)
    monkeypatch.setattr(tr.subprocess, "run", fake_run)
    text = tr.transcribe_bytes(b"not-really-audio", filename="clip.webm")
    assert text == "ship the front door"
