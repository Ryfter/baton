# KB auto-index hook

`scripts/hooks/kb-autoindex.ps1` is a Claude Code `PostToolUse` hook for keeping
the embedding index current after knowledge-base edits.

When a `Write` or `Edit` tool call touches a file under `~/.claude/knowledge/`,
the hook starts the incremental indexer in the background, re-indexing only the
touched file:

```powershell
python -m kb.index --file <touched-path>
```

The `--file` path indexes exactly one file (validated to be under the corpus or
jobs root) instead of rescanning a whole scope, so the cost per edit is a single
chunk-and-embed rather than an mtime walk of the entire scope.

Paths outside `~/.claude/knowledge/` are ignored. The hook does not wait for the
indexer process, so editor writes are not blocked.

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
