"""Sanitize Maestro goals for card display — human intent, not parser junk."""
from __future__ import annotations

import re

_NOISE_PATTERNS = [
    re.compile(r"<!--.*?-->", re.DOTALL),
    re.compile(r"^Tonight\s+\d{4}-\d{2}-\d{2}\s*[—–-]\s*", re.IGNORECASE),
    re.compile(r"^Kevin:\s*", re.IGNORECASE),
    re.compile(r"\bWorktree(?:\s+preferred)?:\s*(?:/[^\s]+|\S+)", re.IGNORECASE),
    re.compile(r"\bWork\s+only\s+in:\s*(?:/[^\s]+|\S+)", re.IGNORECASE),
    re.compile(r"\bRepo:\s*(?:/[^\s]+|\S+)", re.IGNORECASE),
    re.compile(r"\bBranch:\s*[\w.\-/]+", re.IGNORECASE),
    re.compile(r"/(?:Users|home|var|tmp)/[\w.\-/]+", re.IGNORECASE),
    re.compile(r"\bDo\s+NOT\b.*?(?=\.|$)", re.IGNORECASE),
]


def sanitize_goal(text: str, *, max_len: int = 90) -> str:
    g = (text or "").strip()
    if not g:
        return ""
    changed = True
    while changed:
        changed = False
        for pattern in _NOISE_PATTERNS:
            cleaned = pattern.sub("", g).strip()
            if cleaned != g:
                g = cleaned
                changed = True
    g = " ".join(g.split())
    if len(g) <= max_len:
        return g
    return g[: max_len - 1].rstrip() + "…"
