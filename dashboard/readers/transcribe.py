"""Factory STT (path C) — mlx_whisper on the Mac mini.

Browser-side path A does not come through here. Spike model is whisper-tiny
so the first listen is fast; seated production model is large-v3-turbo (baton-d129).
"""
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any

MLX_BIN = "mlx_whisper"
FFMPEG_BIN = "ffmpeg"
SPIKE_MODEL = "mlx-community/whisper-tiny"
MAX_BYTES = 8 * 1024 * 1024
ALLOWED_SUFFIX = {".webm", ".wav", ".mp3", ".m4a", ".ogg", ".mp4", ".mpeg"}


def engine_status() -> dict[str, Any]:
    mlx = shutil.which(MLX_BIN)
    ffmpeg = shutil.which(FFMPEG_BIN)
    return {
        "schema": 1,
        "factory": {
            "id": "droid",
            "engine": "mlx_whisper",
            "available": bool(mlx and ffmpeg),
            "mlx": mlx,
            "ffmpeg": ffmpeg,
            "model": SPIKE_MODEL,
            "note": "spike model (tiny). Seated model is large-v3-turbo.",
        },
        "this_computer": {
            "id": "browser",
            "engine": "Web Speech API",
            "available": None,
            "note": "Runs in the browser on the machine you are sitting at.",
        },
    }


def transcribe_bytes(data: bytes, filename: str = "clip.webm") -> str:
    if not data:
        raise ValueError("empty audio")
    if len(data) > MAX_BYTES:
        raise ValueError(f"audio too large ({len(data)} bytes)")
    status = engine_status()["factory"]
    if not status["available"]:
        raise RuntimeError("factory STT unavailable — need mlx_whisper and ffmpeg on PATH")

    suffix = Path(filename).suffix.lower() or ".webm"
    if suffix not in ALLOWED_SUFFIX:
        suffix = ".webm"

    with tempfile.TemporaryDirectory(prefix="baton-stt-") as td:
        raw = Path(td) / f"in{suffix}"
        wav = Path(td) / "in.wav"
        out_dir = Path(td) / "out"
        out_dir.mkdir()
        raw.write_bytes(data)
        ffmpeg = status["ffmpeg"]
        mlx = status["mlx"]
        assert ffmpeg and mlx
        conv = subprocess.run(
            [ffmpeg, "-y", "-i", str(raw), "-ac", "1", "-ar", "16000", str(wav)],
            capture_output=True,
            timeout=30,
            check=False,
        )
        if conv.returncode != 0 or not wav.is_file():
            err = (conv.stderr or b"").decode("utf-8", "replace")[-400:]
            raise RuntimeError(f"ffmpeg could not decode audio: {err}")
        run = subprocess.run(
            [
                mlx,
                str(wav),
                "--model",
                SPIKE_MODEL,
                "--output-dir",
                str(out_dir),
                "--output-format",
                "txt",
                "--verbose",
                "False",
                "--language",
                "en",
            ],
            capture_output=True,
            timeout=90,
            check=False,
        )
        if run.returncode != 0:
            err = (run.stderr or b"").decode("utf-8", "replace")[-400:]
            raise RuntimeError(f"mlx_whisper failed: {err}")
        texts = sorted(out_dir.glob("*.txt"))
        if not texts:
            raise RuntimeError("mlx_whisper wrote no transcript")
        return texts[0].read_text(encoding="utf-8").strip()
