# KB auto-index hook

`scripts/hooks/kb-autoindex.ps1` is a Claude Code `PostToolUse` hook for keeping
the embedding index current after knowledge-base edits.

When a `Write` or `Edit` tool call touches a file under `~/.claude/knowledge/`,
the hook derives the smallest supported index scope and starts the incremental
indexer in the background:

```powershell
python -m kb.index --scope <derived>
```

Derived scopes:

- `~/.claude/knowledge/universal/...` -> `universal`
- `~/.claude/knowledge/projects/<project-id>/...` -> `<project-id>`
- any other path under `~/.claude/knowledge/` -> `all`

Paths outside `~/.claude/knowledge/` are ignored. The hook does not wait for the
indexer process, so editor writes are not blocked. Incremental indexing is the
default behavior in `kb.index`; unchanged files in the selected scope are skipped.

## Claude Code settings

Add this `PostToolUse` entry to `~/.claude/settings.json`. Use the absolute path
to this repository checkout:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -File \"D:\\Dev\\coding-agent-orchestrator\\scripts\\hooks\\kb-autoindex.ps1\""
          }
        ]
      }
    ]
  }
}
```

If the hook is copied outside the repository, set `CAO_REPO_ROOT` to the
`coding-agent-orchestrator` repo root so `python -m kb.index` can import the
`kb` package.
