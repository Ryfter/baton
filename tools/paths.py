"""Resolve Baton's state root. State lives under BATON_HOME (default ~/.baton);
the knowledge base stays under ~/.claude/knowledge and is NOT Baton state."""
from __future__ import annotations
import os
from pathlib import Path


def baton_home() -> Path:
    return Path(os.environ.get("BATON_HOME", "") or Path.home() / ".baton")
