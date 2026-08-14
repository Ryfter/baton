---
description: Portable session lifecycle for Codex, Grok, and other controllers.
---

# Portable controller lifecycle

Claude Code gets session markers from plugin hooks. Other controllers should use
the same neutral contract through the CLI runner:

```powershell
baton session start -Agent codex -SessionId <id> -Cwd (Get-Location)
baton session refresh -Agent codex -SessionId <id> -Cwd (Get-Location)
baton session stop -Agent codex -SessionId <id> -Cwd (Get-Location)
```

Use `grok`, `gemini`, `copilot`, or another stable label for `-Agent`. The start
call writes `$BATON_HOME/sessions/<id>.json`; stop clears it and records the
project resume pointer under `$BATON_HOME/projects/`. All calls emit one compact
JSON result, making them safe for a wrapper, shell, or broker to consume.
