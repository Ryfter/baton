from __future__ import annotations

import json
from pathlib import Path

from kb.search import _active_job_project_id


def test_active_job_project_id_reads_current_job_project_id(tmp_path: Path) -> None:
    current_job = tmp_path / "current-job.json"
    current_job.write_text(json.dumps({"project_id": "alpha"}), encoding="utf-8")

    assert _active_job_project_id(current_job) == "alpha"


def test_active_job_project_id_missing_file_is_noop(tmp_path: Path) -> None:
    assert _active_job_project_id(tmp_path / "missing.json") is None
