---
description: Operate the tools registry (~/.claude/tools.yaml) — the non-LLM capability sibling of /fleet. `doctor` health-checks each tool, `list` shows the registry.
argument-hint: doctor | list
---

# /tools

Operate the tool registry defined in `~/.claude/tools.yaml` — declared, cost-tiered,
capability-tagged callable capabilities (e.g. Docling for `pdf-extract`), co-equal with
the models in `/fleet`.

## Steps

1. **Parse `$ARGUMENTS`.** The first whitespace-delimited token is the subcommand:
   `doctor` or `list`. If it's neither (or empty), print usage and stop:
   *"Usage: /tools doctor | list"*.

2. **Dispatch by subcommand** (run from the repo root so `python -m tools.*` resolves):

   **`doctor`** — run:

   ```powershell
   python -m tools.doctor
   ```

   Echo the table to the user. A non-zero exit means at least one enabled tool is
   unavailable (e.g. Docling not installed) — surface which.

   **`list`** — run:

   ```powershell
   python -m tools.list
   ```

   Echo the table.

3. **On any error** (missing `tools.yaml`, etc.), surface the message and suggest
   re-running `pwsh scripts\bootstrap.ps1 -Force` to deploy the registry seed.

## Arguments

$ARGUMENTS
