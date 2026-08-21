# Layer LM seating — Ox Alpha / Opus / Fable

**Date:** 2026-08-21  
**Status:** approved by Kevin (session) — implements `baton-d124`  
**Extends:** `baton-d108`, `baton-d111`, `baton-d119`  
**Does not reopen:** Maestro stays deterministic for admission; no Gantt; no merge without Kevin.

## Picture

```
Kevin
  └─ Mouth / Composer ………… Ox Alpha (free, converse)
        └─ Maestro ………………… deterministic code only
              └─ Conductor ………… Ox Alpha (thin, free)
                    └─ Orchestrator (per project) … Opus
                          ├─ plan / sprint-review … Fable
                          └─ Instruments …………… Ox Alpha + Codex/Grok/Kiro/Cursor
```

## Capability claims (fleet.yaml)

| Capability | Who claims it | Router rule |
|---|---|---|
| `converse` | `openrouter-ox-alpha` (and healthy Opencode Ox twin) | local/free only auto (`d119`) |
| `orchestrate` | Opus seat (`cursor-opus` / claude-opus class) | paid OK |
| `sprint-review` | Fable seat (`cursor-fable`) | paid/promo; end of sprint + plan once-over |
| `plan-review` | Fable (+ Codex peer when staffing a panel) | ≥2 unique providers (`d118`) |
| `code-gen` / `code-transform` | Ox Alpha `diff_apply`, Codex, Grok, Kiro, Cursor | cost-ordered failover |

## Operator verbs (Cursor + Claude Code)

- `/baton:fleet doctor|list|test|dispatch|status|stop`
- `/baton:go` — Conductor front door (engine unchanged)
- Skills under `.cursor/skills/baton-*` teach Cursor the same mouth

## Privacy

Ox Alpha (OpenRouter stealth + Opencode Zen) retains prompts at the provider. Keep Grimdex/Grimlore private KB off those paths unless Kevin opts in (`baton-d119` trust bound: propose → code disposes → Kevin confirms spend/write).
