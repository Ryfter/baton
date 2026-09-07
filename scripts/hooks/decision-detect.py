#!/usr/bin/env python3
# decision-detect.py -- Claude Code Stop hook: detect an explicit decision in the
# assistant's final response and drop a decision-intake draft in $TEMP.
#
# Non-blocking: prints one pointer line on a hit, exits 0 always. Ported from
# decision-detect.ps1 (2026-09-07) -- no lib deps, pure text/regex, so the port
# is 1:1 with an added fail-open wrapper.

import json
import os
import re
import sys
import tempfile
from datetime import datetime
from pathlib import Path

_TEXT_KEYS = ("text", "content", "message", "result", "response", "output")
_DIRECT_FIELDS = (
    "final_message", "finalMessage", "assistant_message", "assistantMessage",
    "message", "response", "output", "content", "text",
)
_PATTERNS = (
    ("over",
     r"\bI(?:'ll| will)\s+go with\s+(?P<chosen>[^.;:\r\n]{3,120}?)\s+over\s+(?P<alt>[^.;\r\n]{3,120})(?:[.;]|$)"),
    ("because",
     r"\b(?:I\s+)?chose\s+(?P<chosen>[^.;:\r\n]{3,140}?)\s+because\s+(?P<reason>[^.;\r\n]{8,240})(?:[.;]|$)"),
    ("rather-than",
     r"\b(?:I\s+)?decided\s+to\s+(?P<chosen>[^.;:\r\n]{3,160}?)\s+rather than\s+(?P<alt>[^.;\r\n]{3,160})(?:[.;]|$)"),
)


def to_plain_text(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, (list, tuple)):
        return "\n".join(p for p in (to_plain_text(v) for v in value) if p)
    if isinstance(value, dict):
        for name in _TEXT_KEYS:
            if name in value:
                text = to_plain_text(value[name])
                if text and text.strip():
                    return text
    return ""


def direct_assistant_text(payload):
    if not isinstance(payload, dict):
        return ""
    for field in _DIRECT_FIELDS:
        if field in payload:
            text = to_plain_text(payload[field])
            if text and text.strip():
                return text
    return ""


def transcript_assistant_text(path):
    if not path or not os.path.isfile(path):
        return ""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            tail = f.readlines()[-200:]
    except OSError:
        return ""
    last = ""
    for line in tail:
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except Exception:
            continue
        is_assistant = isinstance(entry, dict) and (
            entry.get("type") == "assistant"
            or entry.get("role") == "assistant"
            or (isinstance(entry.get("message"), dict) and entry["message"].get("role") == "assistant")
        )
        if not is_assistant:
            continue
        text = to_plain_text(entry)
        if text and text.strip():
            last = text
    return last


def _norm(text):
    return re.sub(r"\s+", " ", text).strip(" \t\r\n.;,:")


def decision_match(text):
    normalized = re.sub(r"\s+", " ", text)
    for kind, pattern in _PATTERNS:
        m = re.search(pattern, normalized, re.IGNORECASE)
        if not m:
            continue
        chosen = _norm(m.group("chosen"))
        gd = m.groupdict()
        alt = _norm(gd["alt"]) if gd.get("alt") else ""
        reason = _norm(gd["reason"]) if gd.get("reason") else ""
        if len(chosen) < 3:
            continue
        if kind != "because" and len(alt) < 3:
            continue
        if kind == "because" and len(reason) < 8:
            continue
        return {"chosen": chosen, "alt": alt, "reason": reason}
    return None


def _yaml(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> int:
    stdin = sys.stdin.read()
    if not stdin or not stdin.strip():
        return 0
    try:
        payload = json.loads(stdin)
    except Exception:
        return 0

    text = direct_assistant_text(payload)
    if (not text or not text.strip()) and isinstance(payload, dict):
        text = transcript_assistant_text(payload.get("transcript_path"))
    if not text or not text.strip():
        return 0

    d = decision_match(text)
    if d is None:
        return 0

    title = "Decision: " + d["chosen"]
    if len(title) > 90:
        title = title[:87].rstrip() + "..."
    alternative = d["alt"] or "Not captured from final response."
    rationale = d["reason"] or "The final response explicitly selected this option over an alternative."

    temp_root = os.environ.get("TEMP") or tempfile.gettempdir()
    draft_path = str(Path(temp_root) / ("decision-intake-%s.md" % datetime.now().strftime("%Y%m%d-%H%M%S")))
    markdown = "\n".join([
        "---",
        "title: %s" % _yaml(title),
        "confidence: medium",
        "revisit-if: %s" % _yaml("New evidence changes the tradeoff, requirements shift, "
                                 "or the rejected alternative becomes materially cheaper."),
        "---",
        "",
        "## Chosen", d["chosen"], "",
        "## Alternatives", alternative, "",
        "## Rationale", rationale, "",
    ])
    with open(draft_path, "w", encoding="utf-8") as f:
        f.write(markdown)
    print('Decision draft captured: %s. Suggested intake: d### intake "%s"' % (draft_path, draft_path))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
