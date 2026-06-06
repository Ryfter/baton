from __future__ import annotations

from datetime import datetime
from typing import Optional

from pydantic import BaseModel


class RunRecord(BaseModel):
    id: str
    name: str
    model: str
    status: str                      # queued | running | needs-you | idle | done | failed
    reasoning: Optional[str] = None
    project: Optional[str] = None
    tree: Optional[str] = None
    worktree: bool = False
    context_pct: Optional[int] = None
    cost_usd: float = 0.0
    tokens_in: int = 0
    tokens_out: int = 0
    files_touched: list[str] = []
    current_step: Optional[str] = None
    parked_question: Optional[str] = None
    started_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None


class RunEvent(BaseModel):
    ts: datetime
    kind: str                        # action | decision | question | result
    what: str
    why: Optional[str] = None
    status: Optional[str] = None


class RunDetail(BaseModel):
    record: RunRecord
    events: list[RunEvent] = []


class GlobalStrip(BaseModel):
    rate_limit_pct: Optional[int] = None
    rate_limit_resets_at: Optional[str] = None
    spend_today_usd: float = 0.0
    active_runs: int = 0
