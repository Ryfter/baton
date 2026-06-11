---
description: Append a one-line qualitative note about a model's recent performance to the routing journal. Use after a notable dispatch when the result deserves remembering ("devstral nailed the refactor style", "gemini bailed halfway through").
argument-hint: <model-or-target> <free-text observation>
---

# /baton:log-routing

You are appending a single qualitative note to the model routing journal at
`~/.claude/model-routing-log.md`. The format is:

```
<ISO-timestamp> | note | <model-or-target> | "<observation>"
```

## Steps

1. Parse the arguments. The first whitespace-delimited token is the model or
   target (e.g. `devstral:24b`, `gemini`, `codex`, `octopus-coder`). Everything
   after is the observation text. If arguments are empty, ask the user what they
   want to log and what model/target it applies to.

2. Construct the timestamp in ISO 8601 format with timezone:
   `Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'`

3. Append the line using PowerShell:

   ```powershell
   $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
   $target = '<first-token>'
   $obs = '<observation, with double quotes escaped>'
   $line = "$ts | note | $target | `"$obs`""
   Add-Content -Path "$HOME/.claude/model-routing-log.md" -Value $line
   ```

4. Confirm to the user: show the exact line that was appended.

## Arguments

$ARGUMENTS
