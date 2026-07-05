---
description: Project registry command center — list projects by lifecycle and edit the registry.
---

# /baton:project

The multi-project command center. From the `D:\dev` home base, see every
project grouped **Active / Inactive / Archived** and edit its registry entry.

Run the CLI:

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/fleet-project.ps1" <subcommand> [args]
```

Subcommands:

- `list [--json]` — roster grouped by lifecycle. *Active* = a session is
  currently open in the folder; *Inactive* = registered, no open session
  (may be `[resumable]`); *Archived* = done with it.
- `archive <slug>` / `unarchive <slug>` — move a project in/out of the
  Archived group.
- `hide <slug>` — drop a `.git` folder that isn't really a project.
- `set-blurb <slug> "<text>"` — hand-write the one-line description.

Projects are discovered by scanning `D:\dev` (override with
`$env:BATON_PROJECTS_ROOT`); a folder counts if it has a `.git` dir or a
`CHARTER.md`. To start work on one, use `/baton:go --<slug> <goal>`.

State is box-private under `$BATON_HOME/projects/`.
