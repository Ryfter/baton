"""Sanitize Maestro goals for card display — human intent, not parser junk."""
from __future__ import annotations

import re

_HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)
_PREAMBLE_RE = re.compile(
    r"^(?:Tonight\s+\d{4}-\d{2}-\d{2}\s*[—–-]\s*|Kevin:\s*|Repo:\s*|Worktree:\s*)+",
    re.IGNORECASE,
)
_REPO_LINE_RE = re.compile(r"\bRepo:\s*/[^\s]+", re.IGNORECASE)
_WORKTREE_RE = re.compile(r"\bWorktree:\s*/[^\s]+", re.IGNORECASE)


def sanitize_goal(text: str, *, max_len: int = 90) -> str:
    g = (text or "").strip()
    if not g:
        return ""
    g = _HTML_COMMENT_RE.sub("", g).strip()
    g = _REPO_LINE_RE.sub("", g)
    g = _WORKTREE_RE.sub("", g)
    while True:
        cleaned = _PREAMBLE_RE.sub("", g).strip()
        if cleaned == g:
            break
        g = cleaned
    g = " ".join(g.split())
    if len(g) <= max_len:
        return g
    return g[: max_len - 1].rstrip() + "…"
