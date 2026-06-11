# Go-public hardening — instruction set (orchestrator + Grimdex)

> **STATUS (2026-06-11): Grimdex side DONE.** The Grimdex home thread executed Task 2 via
> **rename** (not the fresh-migration sketched below): the combined repo became private
> **`Ryfter/grimdex-know`** (data, full history, `pre-split-backup` tag); a fresh-history engine
> repo **`Ryfter/Grimdex`** was built, audited, and is **now PUBLIC** (MIT). The steps below are
> retained as the historical plan. **Still open — owned by THIS (orchestrator) thread:** the
> orchestrator repo's own secret/PII audit + a human-facing `README.md` + `LICENSE` (MIT) before
> `Ryfter/coding-agent-orchestrator` itself is made public (Task 1 scoped to this repo, Task 3).


Paste the block below into a fresh Claude Code (or any agent) session that has access to
**both** `D:\Dev\coding-agent-orchestrator` and `D:\Dev\Grimdex`. It covers (1) a
secret/PII history audit and (2) human-facing READMEs + MIT license. **Do not flip either
repo to public until Task 1 reports GO.**

⚠️ **Grimdex plan (read first) — engine/data split, not a single public repo.** Grimdex is
a *multi-project* knowledge base: it hosts decision records, lessons, ratings, and per-project
tiers for EVERY project that uses it (coding-agent-orchestrator, answerbot, canvas-toolchain,
the grimdex tier). The decision (Kevin, 2026-06-10): **split the engine from the data.**
- **Public `Ryfter/Grimdex`** = the *tool/framework* (scripts, the `GRIMDEX.md` convention,
  setup/wire/sweep, docs) + an empty `universal/` skeleton + a few curated exemplar records.
- **Private `Ryfter/grimdex-know`** = the *data* (his accumulated knowledge: `universal/`
  content + all `projects/` tiers). This stays private and remains his knowledge backup.

His knowledge is ALREADY fully backed up in the current private `Ryfter/Grimdex` repo — that
repo stays untouched as the pre-split backup until both new repos are verified. **Task 2 does
the split; do it AFTER the Task 1 audit (the audit's content manifest drives the
classification).**

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

## Task 2 — Grimdex engine/data split (do AFTER Task 1 = GO)

Split the current combined `D:\Dev\Grimdex` into a public *engine* repo and a private *data*
repo. **Critical:** the data is in the current repo's HISTORY, so it must be excised from
history for the public repo — do NOT just `git rm` and push. Recommended approach below uses a
**fresh-history public repo** (simplest, zero risk of a missed path lingering in history).

**Classification (refine against the Task 1 manifest):**

- **Engine → public `Ryfter/Grimdex`:** `scripts/` (all `*.ps1` libs + tests:
  console/install-schedule/run-scheduled/schedule/setup/sweep/wire + `wire-project.ps1`),
  `setup.ps1`, `GRIMDEX.md`, `KNOWLEDGE.md`, `README.md`, `docs/`, `config/` (sanitize —
  strip any machine-specific values), `.github/`, the tool-wiring meta files (`CLAUDE.md`,
  `AGENTS.md`, `GEMINI.md`, `.cursorrules` — sanitize absolute paths → placeholders),
  `.gitignore`, `RIPPEDPAGES.md` (classify during audit). PLUS: an **empty `universal/`
  skeleton** (`claude-rules/`, `playbooks/`, `topics/`, `promotions/` as empty dirs with a
  `TEMPLATE.md` each) and an **`examples/`** dir holding a *small, audited* set of exemplar
  decision records drawn from the `coding-agent-orchestrator` tier so the format is
  demonstrable. Add `LICENSE` (MIT).
- **Data → private `Ryfter/grimdex-know`:** `universal/` content (`decision-guidance.md`,
  `mistakes.md`, `reasoning.md`, `routing.md`, `user-prefs.md`, `winners.md`,
  `PROMOTIONS-LOG.md`, and the populated `claude-rules/`/`playbooks/`/`topics/`/`promotions/`),
  **all of `projects/`** (answerbot, canvas-toolchain, coding-agent-orchestrator, grimdex),
  `KB-AUDIT-LOG.md`, `.index/`, `logs/`, `.claude/` (review/gitignore the last three).

**Steps (each gated by my confirmation; nothing public until the very end):**

1. **Tag the pre-split backup:** in the current repo, `git tag pre-split-backup && git push
   origin pre-split-backup`. This is the safety net — full history + all data preserved.
2. **Create private `Ryfter/grimdex-know`** (`gh repo create Ryfter/grimdex-know --private`).
   Move the DATA paths into it (a fresh initial commit is fine — the old repo retains full
   history as backup). Push.
3. **Repoint the junction:** `~/.claude/knowledge` → the local `grimdex-know` checkout (it's
   the live data store). Decide engine wiring: either (a) deploy the Grimdex tool globally and
   run it against the knowledge dir, or (b) pin the public Grimdex as a submodule of
   grimdex-know. Verify decisions/sweep/wire still work against the repointed store.
4. **Rebuild public `Ryfter/Grimdex` with clean history:** the cleanest route is to re-init —
   stage ONLY the engine paths + skeleton + examples + LICENSE into a fresh repo with a single
   initial commit, then force-replace the `Ryfter/Grimdex` remote (or create `Grimdex` fresh
   and archive the old). Confirm `git log` shows no data files in ANY commit and the tree
   contains zero private content. (Alternative if history must be preserved: `git filter-repo
   --invert-paths` to purge every data path from every commit — but verify exhaustively.)
5. **Verify both repos**: public Grimdex = engine-only, runs `setup.ps1`/tests green, no
   private content in tree OR history; private grimdex-know = all data present, junction works,
   decisions/sweep operate. Only then is Grimdex safe to make public (my manual flip).
6. Update the orchestrator's `CLAUDE.md`/`docs/agent-handoffs.md` Grimdex pointers if the
   data path/repo name changed.

## Task 3 — READMEs + MIT license

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

## After all tasks (my manual steps, for reference)

- Flip visibility: `gh repo edit Ryfter/coding-agent-orchestrator --visibility public` (and
  `Ryfter/Grimdex` once Task 2 is verified — `grimdex-know` stays private).
- Promote the release: `v1.2.0-rc1` → `v1.2.0` (re-tag + `gh release edit v1.2.0 --prerelease=false`).
