# Go-public hardening — instruction set (orchestrator + Grimdex)

Paste the block below into a fresh Claude Code (or any agent) session that has access to
**both** `D:\Dev\coding-agent-orchestrator` and `D:\Dev\Grimdex`. It covers (1) a
secret/PII history audit and (2) human-facing READMEs + MIT license. **Do not flip either
repo to public until Task 1 reports GO.**

⚠️ **Grimdex caution (read first):** Grimdex is a *multi-project* knowledge base — it hosts
decision records, lessons, ratings, and per-project tiers for EVERY project that uses it
(coding-agent-orchestrator, and any others: answerbot, canvas-toolchain, etc.). Making it
public exposes **all of them**, not just the orchestrator's. Before publishing, decide:
publish the whole KB, publish only a subset (e.g. the orchestrator tier + universal), or
sanitize first. Task 1 produces a content manifest to make that decision on.

---

You are hardening two repos for public release: `D:\Dev\coding-agent-orchestrator` (mostly
code) and `D:\Dev\Grimdex` (a personal/multi-project coding knowledge base, mostly prose).
Both are currently PRIVATE on GitHub under the `Ryfter` org. Honor my standing rules: back
everything up; 965-byte shell-arg limit; terse. **Hard gate: do not change either repo's
visibility — that's my manual action, and only after you report GO on Task 1.**

## Task 1 — Secret + PII history audit (BLOCKING)

Once a repo is public, its ENTIRE git history is public forever — scrubbing the current tree
is not enough. Audit **full history**, not just the working tree, in BOTH repos.

1. **Automated secret scan.** Prefer `gitleaks` (install via `winget install gitleaks` or
   download the release binary if absent; fall back to `trufflehog` or the manual grep below
   if neither installs). Run it against full history in each repo:
   - `gitleaks detect --source . --log-opts="--all" --no-banner -v`
   - Report every finding with file, commit, rule, and a redacted snippet.
2. **Manual cross-check (regardless of gitleaks result).** Search full history for these
   patterns in each repo (`git log -p --all | rg -n "<pattern>"`, or `git grep` across all
   refs):
   - Key/token shapes: `sk-ant-`, `sk-`, `ghp_`, `gho_`, `ghs_`, `github_pat_`, `AKIA`,
     `AIza`, `xox[baprs]-`, `-----BEGIN .*PRIVATE KEY-----`
   - Credential words near `=`/`:`: `password`, `secret`, `api[_-]?key`, `token`,
     `client_secret`, `connection.?string`
   - Files that should never be committed: `.env`, `*.pem`, `*.key`, `*.pfx`,
     `settings.local.json`, anything that looks like a deployed `~/.claude/` runtime file
     (credentials, cost data, raw journals with prompts).
3. **PII / leakage pass (report, don't auto-fix):**
   - Author emails in history (`git log --format='%ae' | sort -u`) — note them; I decide
     whether to keep `kevin.rank@gmail.com` public or rewrite to a noreply.
   - Absolute paths revealing the username (`C:\Users\krank\…`) — cosmetic; list count, don't
     rewrite unless I ask.
   - Orchestrator referencing private Grimdex content/paths that a public user can't reach.
4. **Grimdex content manifest (the big one — human judgment, not regex).** List every file
   under `D:\Dev\Grimdex`, grouped by `universal/` vs each `projects/<id>/`. For each, a
   one-line "what's in it + public-safe? (yes / review / no)" flag. Pay special attention to:
   `universal/user-prefs.md`, `mistakes.md`, `reasoning.md`, `winners.md`,
   `routing-ratings.jsonl`, the compact-state logs, and **every non-orchestrator project
   tier** (those may reference private/client work). Surface anything that names a client,
   business detail, person, credential, or that a stranger reading it would be a problem.
5. **Remediation guidance (do NOT execute history rewrites without my confirmation):**
   - Any live secret found in history → it is already compromised: I must **rotate it now**,
     then scrub history with `git filter-repo --replace-text` (or BFG) and force-push, BEFORE
     public.
   - Secret only in the working tree → remove + `.gitignore` + commit.
   - For Grimdex content flagged "no/review" → propose options: exclude that path, split the
     repo, or sanitize — I decide.
6. **Verdict.** End Task 1 with a clear **GO / NO-GO per repo**, the findings table, and the
   exact remediation commands (for me to run/approve). NO-GO if any secret is in history or any
   Grimdex tier is flagged "no" and unresolved.

## Task 2 — READMEs + MIT license

Only presentation; safe to do regardless of Task 1, but publish only after Task 1 = GO.

1. **`LICENSE` (MIT) in BOTH repos** — standard MIT text, `Copyright (c) 2026 Kevin Rank`.
2. **`README.md` for `coding-agent-orchestrator`** (human-facing — the current `CLAUDE.md` /
   `next-session.md` are agent-oriented). Cover, concisely:
   - What it is: a "Fleet Conductor" — a Claude Code-based orchestrator that routes coding
     work across multiple models + tools to cut cost, learns which to use, and shows what it's
     doing (autonomy + legibility + cost-optimization).
   - Headline features: capability-routing optimizer (selector → dispatch → learning →
     calibration), Cost-Optimization Engine (prime-hours rank gate + capacity surge), legibility
     dashboard, `/idea` front door, tools registry (Docling), Grimdex integration.
   - Requirements: Claude Code, PowerShell 7, Python 3.12+, `gh`, optionally Ollama (local
     models). Install/bootstrap: `pwsh scripts\bootstrap.ps1`. A quickstart (open in repo,
     `/route`, `/fleet doctor`, run the dashboard).
   - Grimdex relationship: optional dependency; graceful degradation — works without it.
   - Status: **early / experimental personal project**, current release `v1.2.0-rc1`. MIT.
   - Honest "not a turnkey product" tone; link `docs/releases/2026-06-10-v1.2.0-rc1.md`.
3. **`README.md` for `Grimdex`** (if/once it's cleared for public): what it is (a standalone,
   tool-agnostic coding knowledge base — the `GRIMDEX.md` convention), how it's structured
   (universal vs per-project tiers), that it's a *personal* KB so set expectations, MIT.
4. Leave internal handoff docs in place (`next-session.md`, `agent-handoffs.md`) — harmless;
   optionally add a one-line "internal working notes" header.

## After both tasks (my manual steps, for reference)

- Flip visibility: `gh repo edit Ryfter/coding-agent-orchestrator --visibility public` (and
  Grimdex, once its content is cleared).
- Promote the release: `v1.2.0-rc1` → `v1.2.0` (re-tag + `gh release edit v1.2.0 --prerelease=false`).
