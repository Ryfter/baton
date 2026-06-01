# Decision Detection Stop Hook

`scripts/hooks/decision-detect.ps1` is a conservative Stop hook helper for catching decisions that were made in an assistant final response but not yet written into the decision log.

The hook reads the JSON payload from standard input. It looks for the assistant's final message text directly in the payload, or from `transcript_path` when present. If the final message contains a confident decision phrase, it writes a draft decision intake markdown file to the system temp directory and prints one line pointing to the draft.

Recognized patterns are intentionally narrow:

- `I'll go with X over Y`
- `chose X because ...`
- `decided to ... rather than ...`

When no confident match is found, the hook exits without output.

## Draft Format

The generated draft uses the `d###` intake shape:

```markdown
---
title: "Decision: ..."
confidence: medium
revisit-if: "New evidence changes the tradeoff, requirements shift, or the rejected alternative becomes materially cheaper."
---

## Chosen
...

## Alternatives
...

## Rationale
...
```

The hook does not submit the draft automatically. Review the temp file first, then run the suggested intake command:

```powershell
d### intake "C:\Users\you\AppData\Local\Temp\decision-intake-20260531-120000.md"
```

## Claude Code Wiring

Add this Stop hook to your Claude Code `settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/hooks/decision-detect.ps1"
          }
        ]
      }
    ]
  }
}
```

Use a repo-relative script path when Claude Code runs from the repository root. If your hook runs from another working directory, replace the script path with an absolute path.
