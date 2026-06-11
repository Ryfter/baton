# Baton Rebrand + Plugin Shell (Phase R + Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebrand `coding-agent-orchestrator` → **Baton** everywhere, and package the repo as a Claude Code plugin + marketplace so all commands surface as `/baton:<command>`.

**Architecture:** The repo root becomes the plugin root (`.claude-plugin/plugin.json` with `name: "baton"`; existing `commands/` auto-discovered). The same repo carries `.claude-plugin/marketplace.json` (marketplace `ryfter`), so install is `claude plugin marketplace add` + `claude plugin install baton@ryfter`. Bootstrap stops flat-copying commands and instead installs the plugin and removes legacy flat copies. Scripts keep deploying to `~/.claude/scripts` in Phase 1 (commands still reference them there); state re-rooting is Phase 2.

**Tech Stack:** Claude Code plugin spec (verified 2026-06-11 against code.claude.com docs), PowerShell 7, gh CLI.

**Spec:** `docs/superpowers/specs/2026-06-11-baton-rebrand-and-packaging-design.md`

**Rebrand rule (applies to every task):** identity surfaces get the new name; historical artifacts (docs/superpowers/plans/*, docs/superpowers/specs/* dated before 2026-06-11, docs/releases/*, docs/DECISIONS.md entries, decision records, compact logs) KEEP the old name. Never edit historical files except where a task explicitly says so.

---

### Task 1: Plugin manifest + marketplace

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Create `.claude-plugin/plugin.json`** with exactly:

```json
{
  "name": "baton",
  "displayName": "Baton",
  "version": "1.2.0-rc.1",
  "description": "Pass the baton. Conduct the fleet. Claude Code as command-and-control for a fleet of coding LLMs — capability routing, cost engine, jobs, decisions, and a knowledge base.",
  "author": { "name": "Kevin Rank", "url": "https://github.com/Ryfter" },
  "repository": "https://github.com/Ryfter/baton",
  "license": "MIT",
  "keywords": ["orchestration", "multi-agent", "fleet", "routing", "cost", "mcp"]
}
```

Note: no `hooks`, no `mcpServers`, no `dependencies` — those are Phase 2/3. octo is a documented companion, NOT a dependency (cross-marketplace resolution is unreliable). The empty `agents/` dir is harmless; do not reference it.

- [ ] **Step 2: Create `.claude-plugin/marketplace.json`** with exactly:

```json
{
  "name": "ryfter",
  "owner": { "name": "Kevin Rank" },
  "plugins": [
    {
      "name": "baton",
      "source": "./",
      "description": "Conduct a fleet of coding agents — routing, cost engine, jobs, decisions, knowledge base."
    }
  ]
}
```

- [ ] **Step 3: Verify install end-to-end (local marketplace)**

Run:
```powershell
claude plugin marketplace add D:\Dev\coding-agent-orchestrator
claude plugin install baton@ryfter
claude plugin list
```
Expected: `baton` listed as installed, version `1.2.0-rc.1`. (Temporary coexistence with old flat `/fleet` etc. is expected until Task 2.)

- [ ] **Step 4: Commit**

```powershell
git add .claude-plugin
git commit -m "feat(plugin): baton plugin manifest + ryfter marketplace (Phase 1 shell)"
```

---

### Task 2: Bootstrap installs the plugin instead of flat-copying commands

**Files:**
- Modify: `scripts/bootstrap.ps1:226-241` (Step 5 block)
- Modify: `scripts/test-bootstrap.ps1:22`

- [ ] **Step 1: Replace bootstrap Step 5.** Replace the block at `scripts/bootstrap.ps1:226-241` (from `# --- Step 5: Deploy slash commands ---` through the closing `}` of the foreach) with:

```powershell
# --- Step 5: Install the Baton plugin (replaces legacy flat command copies) ---
Write-Step "Installing Baton plugin"
# Remove legacy flat copies so /fleet and /baton:fleet don't coexist.
foreach ($cmd in @(
    'log-routing.md','consolidate-routing.md',
    'job-start.md','job-status.md','job-list.md','job-phase.md',
    'job-resume.md','job-lesson.md','consolidate-lessons.md',
    'fleet.md','ensemble.md','research.md','six-hats.md','council.md','idea.md','tools.md','route.md',
    'code-decompose.md','code-parallel.md','code-merge.md',
    'kb-index.md','kb-search.md',
    'decision-feedback.md','consolidate-decisions.md','project-init.md',
    'cost.md'
)) {
    $dst = Join-Path $claudeDir "commands\$cmd"
    if (Test-Path $dst) {
        if ($DryRun) { Write-Ok "[dry-run] would remove legacy flat command: $cmd" }
        else { Remove-Item -Force $dst; Write-Ok "removed legacy flat command: $cmd" }
    }
}
if ($DryRun) {
    Write-Ok "[dry-run] would register marketplace 'ryfter' and install plugin baton@ryfter"
} else {
    $mkts = & claude plugin marketplace list 2>$null
    if ($mkts -match 'ryfter') { & claude plugin marketplace update ryfter }
    else { & claude plugin marketplace add $repoRoot }
    & claude plugin install baton@ryfter
    Write-Ok "Baton plugin installed — commands are /baton:<name>"
}
```

Leave Step 5b (lib scripts → `~/.claude/scripts`), 5b2, and 5b3 untouched — commands still call deployed scripts in Phase 1.

- [ ] **Step 2: Update the bootstrap test assertion.** In `scripts/test-bootstrap.ps1:22`, change:

```powershell
Assert "mentions slash commands"         ($out -match 'slash commands')
```
to:
```powershell
Assert "mentions Baton plugin"           ($out -match 'Baton plugin')
```

- [ ] **Step 3: Run the bootstrap test**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: all assertions pass (it exercises `-DryRun`).

- [ ] **Step 4: Commit**

```powershell
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1
git commit -m "feat(bootstrap): install baton plugin + remove legacy flat commands"
```

---

### Task 3: Namespace sweep — `/cmd` → `/baton:cmd` in commands and user-facing docs

**Files:**
- Modify: all 26 files in `commands/`, plus `README.md`, `docs/GUIDE.md`, `docs/COMMANDS.md`, `docs/getting-started.md`, `docs/agent-handoffs.md`, `docs/next-session.md`, `.cursorrules`, `.github/copilot-instructions.md`

- [ ] **Step 1: Scripted replace.** Run this from repo root:

```powershell
$names = 'code-decompose','code-merge','code-parallel','consolidate-decisions',
  'consolidate-lessons','consolidate-routing','cost','council','decision-feedback',
  'ensemble','fleet','idea','job-lesson','job-list','job-phase','job-resume',
  'job-start','job-status','kb-index','kb-search','log-routing','project-init',
  'research','route','six-hats','tools'
$pattern = '(?<![\w:`/])/(' + ($names -join '|') + ')\b'
$targets = @(Get-ChildItem commands -Filter *.md | ForEach-Object FullName) + @(
  'README.md','docs/GUIDE.md','docs/COMMANDS.md','docs/getting-started.md',
  'docs/agent-handoffs.md','docs/next-session.md','.cursorrules',
  '.github/copilot-instructions.md' | Where-Object { Test-Path $_ })
foreach ($f in $targets) {
  $txt = Get-Content $f -Raw
  $new = [regex]::Replace($txt, $pattern, '/baton:$1')
  if ($new -ne $txt) { Set-Content $f $new -NoNewline; Write-Host "updated $f" }
}
```

- [ ] **Step 2: Review the diff for false positives.** Run `git diff --stat` then `git diff` and check: no URL paths, no file paths (e.g. `scripts/fleet`), no already-namespaced refs got mangled. Fix any by hand. Specifically verify `commands/fleet.md`, `commands/route.md`, `commands/idea.md` read correctly.

- [ ] **Step 3: Commit**

```powershell
git add -A
git commit -m "refactor: namespace all command cross-references to /baton:*"
```

---

### Task 4: Identity-doc rebrand

**Files:**
- Modify: `README.md`, `docs/GUIDE.md`, `docs/COMMANDS.md`, `docs/getting-started.md`, `docs/roadmap.md`, `docs/next-session.md`, `docs/agent-handoffs.md`, `.cursorrules`, `.github/copilot-instructions.md`, `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `dashboard/templates/` (page titles, if any carry the old name)

- [ ] **Step 1: README header.** Replace the first two paragraphs of `README.md` (the `# coding-agent-orchestrator` heading and intro) with:

```markdown
# Baton

**Pass the baton. Conduct the fleet.**

Baton turns Claude Code into the conductor of a fleet of coding LLMs — paid cloud
CLIs, free CLIs, and local models on your own machines. You hand each task to the
right agent (pass the baton), and Baton tracks what they did, what it cost, what
you decided, and what you learned. Built on
[claude-octopus](https://github.com/nyldn/claude-octopus) as the dispatch layer
(recommended companion plugin, not a hard dependency).
```

Keep the Status line, but change the repo references: clone URL becomes `https://github.com/Ryfter/baton`. Add an install section near the top:

```markdown
### Install (Claude Code plugin)

```
claude plugin marketplace add Ryfter/baton
claude plugin install baton@ryfter
```

Commands surface as `/baton:<command>` — e.g. `/baton:fleet doctor`, `/baton:route`, `/baton:idea`.
```

- [ ] **Step 2: Global name sweep on identity surfaces.** In each of: `docs/GUIDE.md`, `docs/COMMANDS.md`, `docs/getting-started.md`, `docs/roadmap.md`, `docs/next-session.md`, `docs/agent-handoffs.md`, `.cursorrules`, `.github/copilot-instructions.md`, `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`: replace the literal `coding-agent-orchestrator` with `baton` when it's a repo/URL/identity reference, and prose phrases like "the orchestrator" stay readable — where a sentence introduces the project, use "Baton (the orchestrator)". Do NOT touch files under `docs/superpowers/plans/`, `docs/superpowers/specs/` (except today's), `docs/releases/`, `docs/DECISIONS.md`.
- [ ] **Step 3: Grep check**

Run: `git grep -li "coding-agent-orchestrator" -- . ':!docs/superpowers' ':!docs/releases' ':!docs/DECISIONS.md' ':!docs/assets'`
Expected: only `scripts/`, `commands/idea.md`, `dashboard/tests/conftest.py` remain (handled in Task 5). `docs/assets/architecture.svg` may keep the old title (regenerating the SVG is out of scope — note it in next-session.md as a nice-to-have).

- [ ] **Step 4: Commit**

```powershell
git add -A
git commit -m "docs: rebrand identity surfaces to Baton"
```

---

### Task 5: Functional renames in scripts + tests, then full test suites

**Files:**
- Modify: `scripts/kb-lib.ps1:13,32,34`, `scripts/run-backlog.ps1:22`, `scripts/fleet-runs-bridge.ps1:15`, `scripts/bootstrap.ps1:4`, `commands/idea.md:99`, `dashboard/tests/conftest.py:46,74,122,138`, `scripts/test-fleet-runs-bridge.ps1:54`, `scripts/test-idea-lib.ps1:87`, `scripts/test-jobs.ps1:42`, `scripts/test-runs-lib.ps1:67`, `scripts/test-statusline-feed.ps1:12`

- [ ] **Step 1: kb-lib repo discovery.** In `scripts/kb-lib.ps1`: change the fallback path at line 32 from `'D:\Dev\coding-agent-orchestrator'` to `'D:\Dev\baton'`; support the new env var while keeping the old one working — the resolution order becomes `$env:BATON_REPO_ROOT`, then `$env:CAO_REPO_ROOT` (legacy), then the `D:\Dev\baton` fallback; update the comment at line 13 and the error message at line 34 to say `baton` and mention `BATON_REPO_ROOT`. NOTE: until Task 8 renames the folder, the fallback path won't exist — set `BATON_REPO_ROOT=D:\Dev\coding-agent-orchestrator` is NOT needed because `CAO_REPO_ROOT`/cwd discovery still work; the kb-lib tests must pass before AND after Task 8 (they use cwd discovery).
- [ ] **Step 2: Default identifiers.** `scripts/run-backlog.ps1:22` default `-RepoRoot` → `'D:\Dev\baton'`; `scripts/fleet-runs-bridge.ps1:15` default `-Project` → `'baton'`; `scripts/bootstrap.ps1:4` comment → "Bootstraps Baton (the orchestrator observation layer) into ~/.claude/."; `commands/idea.md:99` example `-Project 'coding-agent-orchestrator'` → `-Project 'baton'`.
- [ ] **Step 3: Test fixtures.** Update the five test files and `dashboard/tests/conftest.py` occurrences of `coding-agent-orchestrator` → `baton`, and in `scripts/test-idea-lib.ps1:87` the fixture URL → `'https://github.com/Ryfter/baton/issues/123'`; in `scripts/test-statusline-feed.ps1:12` the path fixture → `"D:/Dev/baton"`.
- [ ] **Step 4: Run the full PowerShell suite**

Run:
```powershell
Get-ChildItem scripts/test-*.ps1 | ForEach-Object { pwsh -NoProfile -File $_.FullName; if ($LASTEXITCODE -ne 0) { Write-Error "FAILED: $($_.Name)" } }
```
Expected: all 30 suites pass.

- [ ] **Step 5: Run the Python suite**

Run: `python -m pytest dashboard kb -q`
Expected: 176 passed (deprecation warnings OK).

- [ ] **Step 6: Commit**

```powershell
git add -A
git commit -m "refactor: rename functional defaults/fixtures to baton (BATON_REPO_ROOT, project id)"
```

---

### Task 6: Push, rename the GitHub repo, verify remote

- [ ] **Step 1: Push everything so far**

Run: `git push origin master`
Expected: clean push to `Ryfter/coding-agent-orchestrator`.

- [ ] **Step 2: Rename on GitHub (run INSIDE the repo so the local remote is updated too)**

Run: `gh repo rename baton --yes`
Expected: output confirms `Ryfter/baton`; old URLs redirect automatically.

- [ ] **Step 3: Verify**

Run: `git remote -v` then `git pull`
Expected: remote URL contains `Ryfter/baton`; pull is a no-op. Also `gh repo view Ryfter/baton --json name,visibility` shows `baton`, `PUBLIC`.

---

### Task 7: Knowledge base, Grimdex, deployed-file, and memory migrations

**Files (outside repo):**
- Move: `~/.claude/knowledge/projects/coding-agent-orchestrator/` → `~/.claude/knowledge/projects/baton/`
- Move: `D:\Dev\Grimdex\projects\coding-agent-orchestrator\` → `D:\Dev\Grimdex\projects\baton\`
- Modify: `~/.claude/projects/D--Dev-coding-agent-orchestrator/memory/MEMORY.md`, Grimdex `GRIMDEX.md` (if it lists tiers), repo `CLAUDE.md` (Grimdex tier path), any KB registry files
- Modify: any files under `~/.claude/hooks/`, `~/.claude/scripts/`, `~/.claude/settings.json` that hardcode the old repo path

- [ ] **Step 1: Move the KB project dir**

```powershell
Move-Item "$HOME\.claude\knowledge\projects\coding-agent-orchestrator" "$HOME\.claude\knowledge\projects\baton"
```

- [ ] **Step 2: Update KB registry/index references (NOT historical records).** Run `Get-ChildItem "$HOME\.claude\knowledge" -Recurse -File | Select-String -List 'coding-agent-orchestrator' | Select-Object Path` — update registry/index/config files (e.g. a projects registry, universal guidance indexes) to `baton`; leave decision-record bodies and compact-log history untouched.
- [ ] **Step 3: Move the Grimdex tier + update its docs**

```powershell
Move-Item "D:\Dev\Grimdex\projects\coding-agent-orchestrator" "D:\Dev\Grimdex\projects\baton"
```
Then grep `D:\Dev\Grimdex` (GRIMDEX.md, KNOWLEDGE.md, config/) for `coding-agent-orchestrator`, update tier listings to `baton`, and commit+push the Grimdex repo: `git -C D:\Dev\Grimdex add -A; git -C D:\Dev\Grimdex commit -m "rename tier: coding-agent-orchestrator -> baton"; git -C D:\Dev\Grimdex push`.

- [ ] **Step 4: Repo CLAUDE.md Grimdex pointer.** In `CLAUDE.md`, change the Grimdex tier reference `projects/coding-agent-orchestrator/` → `projects/baton/` (if Task 4 didn't already), commit with message `docs: point Grimdex tier at projects/baton`.
- [ ] **Step 5: Deployed-file sweep.** Run:

```powershell
Get-ChildItem "$HOME\.claude\hooks","$HOME\.claude\scripts" -Recurse -File -ErrorAction SilentlyContinue |
  Select-String -List 'coding-agent-orchestrator' | Select-Object Path
Select-String -Path "$HOME\.claude\settings.json" -Pattern 'coding-agent-orchestrator' -ErrorAction SilentlyContinue
```
For each hit: update the path to `D:\Dev\baton` ONLY if it's a repo-path reference that Task 8 will break; redeploy from repo if the file is a stale copy of a repo script.

- [ ] **Step 6: Memory index + memory note.** In `~/.claude/projects/D--Dev-coding-agent-orchestrator/memory/MEMORY.md`, fix the compact-log link to `../../../knowledge/projects/baton/compact-state-log.md`. Write a new memory file `project_baton_rename.md` (frontmatter type: project) recording: renamed to Baton 2026-06-11, repo `Ryfter/baton`, plugin invoker `/baton:*`, KB id `baton`, Grimdex tier `projects/baton/`, state-root move to `BATON_HOME` is Phase 2. Add its line to MEMORY.md.
- [ ] **Step 7: Reindex the KB** (paths changed): run the kb-index flow per `scripts/kb-lib.ps1` (the `/baton:kb-index --full` command flow) scoped `all`, or note in next-session.md if the Python env isn't available in this shell.
- [ ] **Step 8: Push the knowledge repo** per the standing backup order: `git -C "$HOME\.claude\knowledge" add -A; git -C "$HOME\.claude\knowledge" commit -m "rename project tier: coding-agent-orchestrator -> baton"; git -C "$HOME\.claude\knowledge" push`.

---

### Task 8: Handoff docs + final push, then local folder rename (LAST)

**Files:**
- Modify: `docs/agent-handoffs.md`, `docs/next-session.md`

- [ ] **Step 1: Record the rebrand in `docs/agent-handoffs.md`** — short entry: project renamed Baton (2026-06-11), repo `Ryfter/baton` (redirects active), plugin install flow (`claude plugin marketplace add Ryfter/baton` + `claude plugin install baton@ryfter`), commands now `/baton:*`, KB id + Grimdex tier renamed `baton`, local folder becomes `D:\Dev\baton`, Phase 2 (hooks.json + BATON_HOME state re-root) and Phase 3 (MCP server) are next per the spec.
- [ ] **Step 2: Update `docs/next-session.md`** — orient a cold pickup at `D:\Dev\baton`, note Phase 2/3 backlog, note the architecture.svg title nice-to-have.
- [ ] **Step 3: Commit + push**

```powershell
git add docs/agent-handoffs.md docs/next-session.md
git commit -m "docs(handoffs): Baton rebrand executed; Phase 2/3 queued"
git push origin master
```

- [ ] **Step 4: Rename the local folder + repair worktrees + migrate the auto-memory dir.** Run from OUTSIDE the repo (`Set-Location D:\Dev` first — Windows can't rename a process's cwd):

```powershell
Set-Location D:\Dev
git -C D:\Dev\coding-agent-orchestrator worktree list   # note any active worktrees
Rename-Item D:\Dev\coding-agent-orchestrator D:\Dev\baton
git -C D:\Dev\baton worktree repair
Copy-Item "$HOME\.claude\projects\D--Dev-coding-agent-orchestrator" "$HOME\.claude\projects\D--Dev-baton" -Recurse
```
(Copy, not move, for the memory dir — old session transcripts stay keyed to the old path.) If `Rename-Item` fails with "in use", every step before this is already safe — leave the one-liner for Kevin to run after closing the session.

- [ ] **Step 5: Tell Kevin to restart the session in `D:\Dev\baton`** — the live session's cwd is stale after the rename; the marketplace entry registered from the local path in Task 1 should be re-pointed: `claude plugin marketplace remove ryfter; claude plugin marketplace add Ryfter/baton` (GitHub source from now on), then `claude plugin install baton@ryfter`.

---

## Verification (whole plan)

- `claude plugin list` shows `baton`; `/baton:fleet`, `/baton:route`, `/baton:job-status` resolve in a fresh session; old flat `/fleet` is gone after bootstrap ran.
- `git grep -li coding-agent-orchestrator` returns only historical docs (plans/specs/releases/DECISIONS) + `docs/assets/architecture.svg`.
- All 30 PS suites + 176 Python tests green.
- `gh repo view Ryfter/baton` resolves; KB and Grimdex pushed; memory updated.
