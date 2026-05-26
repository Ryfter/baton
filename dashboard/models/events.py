from __future__ import annotations

from datetime import datetime
from typing import Optional

from pydantic import BaseModel


class HookEntry(BaseModel):
    timestamp: datetime
    target: str
    duration_s: int
    exit_code: int
    brief: Optional[str] = None
    job_id: Optional[str] = None
    phase: Optional[str] = None


class OtelEntry(BaseModel):
    timestamp: datetime
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float
    job_id: Optional[str] = None
    phase: Optional[str] = None


class NoteEntry(BaseModel):
    timestamp: datetime
    target: str
    text: str
    job_id: Optional[str] = None
    phase: Optional[str] = None


class LessonEntry(BaseModel):
    timestamp: datetime
    category: str
    text: str
    job_id: Optional[str] = None
    phase: Optional[str] = None


class OllamaModel(BaseModel):
    name: str
    status: str
    size: str


class LmStudioModel(BaseModel):
    id: str           # e.g. "lmstudio-community/Meta-Llama-3.1-8B-Instruct-GGUF"
    loaded: bool = True


class ModelStats(BaseModel):
    name: str
    calls: int
    cost_usd: float
    tokens_in: int
    tokens_out: int


# --- Plan 3: job models ---


class PhaseLogEntry(BaseModel):
    timestamp: datetime
    kind: str            # 'created' | 'transition' | 'loop-back'
    detail: str          # e.g. 'research → design'
    note: Optional[str] = None


class JobSummary(BaseModel):
    id: str
    title: str
    project: Optional[str] = None
    current_phase: str
    status: str          # 'active' | 'done' | 'abandoned'
    created_at: datetime
    sprint_count: int = 0
    cost_usd: float = 0.0


class JobDetail(BaseModel):
    summary: JobSummary
    brief: str
    phase_log: list[PhaseLogEntry]
    journal: list                          # HookEntry | OtelEntry | NoteEntry | LessonEntry (mixed)
    lessons: list[LessonEntry]
    cost_by_phase: dict[str, float]        # phase → cost_usd


class DashboardStats(BaseModel):
    today_cost_usd: float
    total_otel_calls: int
    models: list[ModelStats]
    recent_hooks: list[HookEntry]
    ollama_models: list[OllamaModel]
    lms_models: list[LmStudioModel] = []
    last_updated: datetime
