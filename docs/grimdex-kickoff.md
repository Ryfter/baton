# Grimdex kickoff prompt

Paste the block below into a fresh Claude Code session launched in `D:\Dev\Grimdex`
(`cd D:\Dev\Grimdex` then `claude`).

---

Bootstrap **Grimdex** — a standalone, tool-agnostic, file-first coding knowledge base
("the Grimoire Index for coding"), promoted out of the orchestrator's KB.

READ FIRST (full design): the decision record
`~/.claude/knowledge/projects/coding-agent-orchestrator/decisions/d032-*.md` and the
"⚑ Parked threads" block in `D:\Dev\coding-agent-orchestrator\docs\next-session.md`.
Honor my standing rules: back up everything to GitHub; stay tool-agnostic; 965-byte
shell-arg limit; capture significant decisions; gated merges; terse.

ARCHITECTURE (decided — d032): file-first (MCP = Phase 2). Markdown+frontmatter is the
universal floor. Canonical root file `GRIMDEX.md` (the CLAUDE.md/AGENTS.md/GEMINI.md
analog) + a thin `KNOWLEDGE.md` redirect to it + a `README.md` reference. Per-tool
pointer stanzas wire every tool to contribute. A disciplined maintenance sweep
(read-only audit + human-gated consolidation, incremental). Tight universal root +
per-project tiers. Existing content is repo `Ryfter/knowledge` at `~/.claude/knowledge`.

The architecture is decided, so do a QUICK lean spec (focus only on: migration safety,
the exact pointer-stanza wording, and the script surface), then build. Deliverables:

1. REPO + CONTENT: the empty folder `D:\Dev\Grimdex` already exists — clone the existing
   KB into it with `git clone https://github.com/Ryfter/knowledge.git .` (trailing dot =
   into the current folder). Verify intact. Then, WITH MY CONFIRMATION, replace
   `~/.claude/knowledge` with a directory junction → `D:\Dev\Grimdex` (rename the old dir
   to `.bak` first; keep until verified) so the orchestrator's existing paths keep working
   and there's one physical store. Optional: rename the GitHub repo to `Ryfter/Grimdex`.
2. ROOT FILES: `GRIMDEX.md` (front door — what Grimdex is, the layout, and the
   contribution rule: "programming decisions/rules/lessons are recorded here"; keep it
   TIGHT), `KNOWLEDGE.md` (thin redirect to GRIMDEX.md), and `README.md` referencing
   GRIMDEX.md.
3. FIRST-RUN SETUP (`setup.ps1`): initializes structure, creates the junction (with
   backup + confirmation), redeploys the mirrored rules (see #6), idempotent and
   re-runnable.
4. `wire-project` SCRIPT: given a project dir, idempotently injects a marked block —
   `<!-- grimdex:start -->` … `<!-- grimdex:end -->` — into that project's `CLAUDE.md`,
   `AGENTS.md`, `GEMINI.md`, `.cursorrules`, and `.github/copilot-instructions.md`
   (create if missing). The block says: "PROGRAMMING DECISIONS, rules, and lessons →
   record them in Grimdex at <path>; read GRIMDEX.md first; when you make or revise a
   coding rule, write it there." Re-runs update in place between the markers. Wire
   `D:\Dev\coding-agent-orchestrator` as the first project.
5. TESTS + bootstrap per project conventions; gate green before any merge.

6. KB HEALTH — `/kb-audit` + rules-mirror (re-homed idea; concept at
   `~/.claude/ideas/kb-consistency-audit-…/concept.md`):
   a. RULES-MIRROR (do this first — closes a LIVE backup gap): copy `~/.claude/rules/*.md`
      (context7, task-group-closeout, post-compact-state-report) into Grimdex
      `universal/claude-rules/`, and have `setup.ps1` redeploy them back to `~/.claude/rules/`
      on run. Those 3 global rules are currently in NO git repo = unbacked.
   b. `kb-audit` capability + a KB-root `KB-AUDIT-LOG.md` (append-only, newest-on-top): a
      READ-ONLY sweep over the whole KB checking — MEMORY.md pointers resolve;
      `[[wikilinks]]` resolve or are intentional forward-refs; decision ids
      sequential/no dupes; cross-project contamination (entries referencing issues/PRs not
      in that project's repo); reconciliation of dormant projects' "shipped/closed" claims
      vs live `gh`; backup coverage (everything that should be in the KB is present and the
      repo is clean/pushed). Findings append to `KB-AUDIT-LOG.md`.
   c. DISCIPLINE: the audit is READ-ONLY (reports drift + proposes fixes); consolidation
      stays human-gated; sweeps are incremental (only what changed). Never let an automated
      sweep silently rewrite the universal root.
   d. SCHEDULE: weekly, off-peak, rank-4. Run LOCALLY for now — a cloud-scheduled agent only
      sees GitHub-backed content, so the rules-mirror (6a) must land before any cloud run.

Automate aggressively: first-run setup + wire-project should each be one command. Keep the
first cycle lean (1–5 + 6a); 6b–6d can be the immediate next slice if needed. Capture
significant decisions. Brainstorm the lean spec with me first, then build.
