from pathlib import Path
from subprocess import CompletedProcess

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from dashboard.routers.api import router as api_router
from dashboard.routers.controls import router as controls_router


@pytest.fixture
def app(journal_file: Path) -> FastAPI:
    app = FastAPI()
    app.state.journal_path = journal_file
    app.include_router(api_router)
    app.include_router(controls_router)
    return app


@pytest.fixture
def client(app: FastAPI) -> TestClient:
    return TestClient(app)


def test_api_stats_returns_stats(client: TestClient):
    response = client.get("/api/stats")
    assert response.status_code == 200
    data = response.json()
    assert data["total_otel_calls"] == 2
    assert len(data["models"]) == 2
    assert data["models"][0]["name"] == "claude-sonnet-4-6"
    assert len(data["recent_hooks"]) == 3
    assert data["ollama_models"] == []
    assert "last_updated" in data


def test_api_stats_uses_app_state_journal_path(tmp_path: Path):
    journal = tmp_path / "empty.md"
    journal.write_text("# empty\n", encoding="utf-8")
    app = FastAPI()
    app.state.journal_path = journal
    app.include_router(api_router)

    response = TestClient(app).get("/api/stats")

    assert response.status_code == 200
    assert response.json()["total_otel_calls"] == 0


def test_ollama_stop_all_stops_each_running_model(client: TestClient, monkeypatch):
    calls: list[list[str]] = []

    def fake_run(command, capture_output, text, timeout):
        calls.append(command)
        if command == ["ollama", "ps"]:
            return CompletedProcess(
                command,
                0,
                stdout=(
                    "NAME ID SIZE PROCESSOR UNTIL\n"
                    "devstral:24b abc123 14GB 100% GPU 4 minutes from now\n"
                    "llava:latest def456 4.7GB 100% GPU 4 minutes from now\n"
                ),
                stderr="",
            )
        return CompletedProcess(command, 0, stdout="", stderr="")

    monkeypatch.setattr("dashboard.routers.controls.subprocess.run", fake_run)

    response = client.post("/controls/ollama/stop-all")

    assert response.status_code == 200
    assert response.json() == {
        "stopped": ["devstral:24b", "llava:latest"],
        "count": 2,
    }
    assert calls == [
        ["ollama", "ps"],
        ["ollama", "stop", "devstral:24b"],
        ["ollama", "stop", "llava:latest"],
    ]


def test_ollama_stop_all_handles_no_running_models(client: TestClient, monkeypatch):
    calls: list[list[str]] = []

    def fake_run(command, capture_output, text, timeout):
        calls.append(command)
        return CompletedProcess(
            command,
            0,
            stdout="NAME ID SIZE PROCESSOR UNTIL\n",
            stderr="",
        )

    monkeypatch.setattr("dashboard.routers.controls.subprocess.run", fake_run)

    response = client.post("/controls/ollama/stop-all")

    assert response.status_code == 200
    assert response.json() == {"stopped": [], "count": 0}
    assert calls == [["ollama", "ps"]]
