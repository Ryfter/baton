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


class OtelEntry(BaseModel):
    timestamp: datetime
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float


class NoteEntry(BaseModel):
    timestamp: datetime
    target: str
    text: str


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


class DashboardStats(BaseModel):
    today_cost_usd: float
    total_otel_calls: int
    models: list[ModelStats]
    recent_hooks: list[HookEntry]
    ollama_models: list[OllamaModel]
    lms_models: list[LmStudioModel] = []
    last_updated: datetime
