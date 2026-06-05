# Command reference

Every command here is a **slash command** you type into a Claude Code chat — e.g.
`/job-start "fix the login bug"` — and press Enter. Claude runs the underlying
script and reports back. You never run these in a terminal; they live inside Claude
Code after you've [installed the orchestrator](GUIDE.md#2-install--bootstrap).

If you're brand new, read the [**Guide**](GUIDE.md) first — it walks a whole session
start to finish. This page is the dictionary you come back to for "what are all the
options for *this* command?"

## How to read this page

- **`<angle brackets>`** = a value **you** supply (required unless noted).
- **`[square brackets]`** = optional.
- **`--flag`** = an option; some take a value (`--k 5`), some are on/off (`--apply`).
- **"Where results land"** tells you which file on disk changed, all under your home
  folder's `~/.claude/` directory (Windows: `C:\Users\<you>\.claude\`).

## Shared idea: the "fleet", providers, and tiers

Several commands fan a question out to a **fleet** of AI models. Each model is a
**provider** listed in `~/.claude/fleet.yaml` (e.g. `claude-cli`, `codex`,
`gemini-antigravity`, `ollama-local`, `lm-studio`). Every provider has a **cost tier**:
`paid`, `free`, or `local`.

When a command runs a group of providers (the "roster"), it's chosen by this
precedence:

1. **`--providers a,b,c`** — exact names you list (wins over everything).
2. **`--tier free,local`** — every enabled provider in those tiers.
3. **Default** — the `research_default` roster in `fleet.yaml` (currently
   `claude-cli, codex, ollama-local`).

All fan-out commands run providers **at the same time** (process-isolated), with a
**300-second** per-provider timeout, and they each get a small dose of your own
knowledge base mixed into their prompt before they answer.

---

# Jobs — track a piece of work start to finish

A **job** is a tracked unit of work (a feature, a bug, an investigation). It has
phases (research → design → code → review) and its own folder under `~/.claude/jobs/`.

### /job-start
- **One-liner:** Creates a new job folder and makes it active so your work gets tracked.
- **When you'd use it:** Kicking off a fresh feature, fix, or investigation.
- **Syntax:** `/job-start "<brief>" [--project <id> | --no-project]`
- **Arguments & flags:**
  - `"<brief>"` — short description (required). Becomes the title and the job ID.
  - `--project <id>` — set which project this belongs to. Default: auto-detected from the git remote, else the folder name.
  - `--no-project` — skip project detection entirely.
- **Under the hood:** Creates `~/.claude/jobs/<id>/` (manifest, brief, phase-log, lessons) and marks it active. Starting phase is always `research`.
- **Where results land:** `~/.claude/jobs/<id>/`.
- **Plain example:** `/job-start "add dark mode toggle"` → creates the job, sets it active at the research phase.
- **Gotchas:** If a job is already active it asks whether to suspend or resume — it won't silently start a second one.

### /job-status
- **One-liner:** Shows the active job's details plus its last 10 log entries.
- **When you'd use it:** A quick "where am I?" on the current job.
- **Syntax:** `/job-status`
- **Arguments & flags:** None.
- **Under the hood:** Reads the active job's manifest and the journal lines tagged with its ID. Read-only.
- **Where results land:** Console only — nothing is written.
- **Plain example:** `/job-status` → prints id, phase, status, and recent activity.
- **Gotchas:** If no job is active, it points you to `/job-resume` or `/job-list`.

### /job-list
- **One-liner:** Lists your jobs, newest first.
- **When you'd use it:** To see what exists — to resume one or review past work.
- **Syntax:** `/job-list [--all | --active | --done]`
- **Arguments & flags:**
  - `--active` — only active jobs (**default**).
  - `--done` — only finished jobs.
  - `--all` — every job.
- **Under the hood:** Reads each job's manifest and renders a table. Read-only.
- **Where results land:** Console table (ID, Phase, Project, Status, Started).
- **Plain example:** `/job-list --all` → a table of every job.
- **Gotchas:** Jobs with a missing/broken manifest are silently skipped.

### /job-phase
- **One-liner:** Shows or moves the active job through its phases (or closes it).
- **When you'd use it:** When you finish one stage and want to advance, step back, or finish.
- **Syntax:** `/job-phase [next | back | done | <phase-name>]`
- **Arguments & flags:**
  - *(no argument)* — show the current phase and what `next` would do.
  - `next` — advance one step: `research → design → code.sprint-1 → review`; from review you can start another sprint or finish.
  - `back` — step to the previous phase (errors at `research`).
  - `done` — mark the job finished and clear the active state.
  - `<phase-name>` — jump to a named phase (`research`, `design`, `code.sprint-N`, `review`, `done`). Going earlier is logged as a "loop-back".
- **Under the hood:** Updates the job manifest, phase-log, and journal atomically.
- **Where results land:** The job's manifest + phase-log + the journal.
- **Plain example:** `/job-phase next` while in `design` → moves to `code.sprint-1`.
- **Gotchas:** `next`/`done` prompt you (non-blocking) to capture a lesson; `done` also lists the job's decisions and asks for retro feedback.

### /job-resume
- **One-liner:** Re-activates a job you started earlier.
- **When you'd use it:** Coming back to a job after a break or a new session.
- **Syntax:** `/job-resume <job-id>`
- **Arguments & flags:**
  - `<job-id>` — the full ID (e.g. `j-2026-05-26-feature-flags`). If omitted, it lists your jobs and asks which.
- **Under the hood:** Re-points the active-job state file at that job's saved phase.
- **Where results land:** The active-job state file.
- **Plain example:** `/job-resume j-2026-05-26-feature-flags` → re-activates it at its last phase.
- **Gotchas:** Errors if the job folder is missing or its manifest is corrupted.

### /job-lesson
- **One-liner:** Records a categorized lesson into the active job (and later, the knowledge base).
- **When you'd use it:** Any time you learn something worth keeping.
- **Syntax:** `/job-lesson <category> "<text>" [--scope universal|project]`
- **Arguments & flags:**
  - `<category>` — one of `routing`, `user-pref`, `reasoning`, `mistake`, `winner`, `convention`, `decision`, `architecture`, `knowledge`.
  - `"<text>"` — the lesson (quoted).
  - `--scope universal|project` — where it should eventually live. Default depends on the category.
- **Under the hood:** Appends to the job's `lessons.md` and writes a journal line.
- **Where results land:** `~/.claude/jobs/<id>/lessons.md` + the journal.
- **Plain example:** `/job-lesson mistake "forgot to mock the clock, tests flaked"`.
- **Gotchas:** Errors if no job is active.

---

# Fleet & ensembles — ask many models at once

These send a question to several models and have Claude synthesize the answers. See
[Shared idea](#shared-idea-the-fleet-providers-and-tiers) for `--providers`/`--tier`.

### /fleet
- **One-liner:** Inspect and test your stable of AI models.
- **When you'd use it:** To see which models are configured, confirm they're reachable, or fire a quick prompt at one.
- **Syntax:** `/fleet doctor | list | test <name> "<prompt>" [--model <m>]`
- **Subcommands:**
  - `doctor` — health-checks every enabled provider (binary on PATH? endpoint reachable?) and prints a status table.
  - `list` — prints the registry (name, kind, enabled, cost tier).
  - `test <name> "<prompt>" [--model <m>]` — sends one prompt to one provider.
    - `<name>` — the provider key (e.g. `ollama-local`).
    - `"<prompt>"` — the prompt.
    - `--model <m>` — override that provider's default model.
- **Under the hood:** Reads `fleet.yaml`; `test` dispatches a single synchronous call and journals it.
- **Where results land:** Console (tables / the model's response). `test` appends one journal line.
- **Plain example:** `/fleet doctor` → a table showing each model green/red.
- **Gotchas:** Unknown/disabled provider names error — run `/fleet list` to see valid ones.

### /ensemble
- **One-liner:** Fan one prompt out to several models concurrently, then get a synthesis of where they agree and differ.
- **When you'd use it:** A quick multi-model "second and third opinion" — no job needed.
- **Syntax:** `/ensemble "<prompt>" [--providers a,b,c] [--tier free,local]`
- **Arguments & flags:**
  - `"<prompt>"` — the question (required).
  - `--providers` / `--tier` — choose the roster (see [Shared idea](#shared-idea-the-fleet-providers-and-tiers)).
- **Under the hood:** Resolves a roster, mixes in your top-3 relevant KB snippets, runs each provider in parallel, then Claude writes a synthesis.
- **Where results land:** `~/.claude/ensembles/ensemble-<timestamp>/` (or the active job's research folder), with one file per model + `synthesis.md`.
- **Plain example:** `/ensemble "SQLite or Postgres for this app?" --tier local` → your local models answer in parallel; you get one merged write-up.
- **Gotchas:** A model that errors or times out is skipped and noted; if all fail, it suggests `/fleet doctor`.

### /research
- **One-liner:** The job-bound version of `/ensemble` — same fan-out, filed into the active job's research phase.
- **When you'd use it:** Multi-model research you want recorded as part of a tracked job.
- **Syntax:** `/research "<question>" [--providers a,b,c] [--tier free,local]`
- **Arguments & flags:** Same as `/ensemble`.
- **Under the hood:** Same engine as `/ensemble`, but requires an active job and warns if you're not in the research phase.
- **Where results land:** `~/.claude/jobs/<id>/phases/research/ensemble-<timestamp>/`.
- **Plain example:** `/research "What auth strategy fits our constraints?"`.
- **Gotchas:** No active job → it tells you to use `/ensemble` or `/job-start`.

### /six-hats
- **One-liner:** Examines a question through six fixed lenses (facts, feelings, risks, benefits, creativity, process), then a "Blue Hat" conclusion.
- **When you'd use it:** When you want a decision pulled apart from six deliberately different angles instead of one blended answer.
- **Syntax:** `/six-hats "<question>" [--providers a,b,c] [--tier free,local]`
- **Arguments & flags:** Same roster options as `/ensemble`.
- **Under the hood:** Builds 6 role-prefixed prompts, rotates your roster across them (2 models → 6 hats split across them), runs them in parallel, then Claude writes a structured synthesis.
- **Where results land:** A `six-hats-<timestamp>/` dir with one file per hat + `synthesis.md`.
- **Plain example:** `/six-hats "Should we rewrite the billing service?"`.
- **Gotchas:** Each hat is one independent call — models don't see each other's hats.

### /council
- **One-liner:** A two-round deliberation — members answer, then read each other's answers and refine; Claude chairs the verdict.
- **When you'd use it:** High-stakes questions where you want genuine back-and-forth, not isolated answers.
- **Syntax:** `/council "<question>" [--providers a,b,c] [--tier free,local]`
- **Arguments & flags:** Same roster options as `/ensemble`. Roster is **capped at 5** and needs **at least 2**.
- **Under the hood:** Round 1 = independent answers; a quorum of ≥2 must succeed; Round 2 = each member refines after reading the others; Claude synthesizes.
- **Where results land:** A `council-<timestamp>/` dir with `round1/`, `round2/`, and `synthesis.md`.
- **Plain example:** `/council "Build vs. buy our analytics pipeline?" --providers claude-cli,codex,ollama-local`.
- **Gotchas:** Below 2 working members it won't run; an oversized roster is silently capped at 5.

---

# Code phase — turn a spec into working code

**The workflow:** `/code-decompose` slices a finished spec into small independent
tasks → `/code-parallel` hands each task to its own AI worker in an isolated copy of
the repo → `/code-merge` reviews the results and folds them back into the main branch.

### /code-decompose
- **One-liner:** Breaks a feature spec into small, independent, parallelizable tasks.
- **When you'd use it:** You've written what you want built and want it chopped into hand-off-able chunks.
- **Syntax:** `/code-decompose [<path-to-spec>]`
- **Arguments & flags:**
  - `<path-to-spec>` — the spec file. If omitted, uses the newest `.md` in the job's `phases/design/` folder.
- **Under the hood:** Claude proposes N subtasks (id, title, files-touched, depends-on); after you confirm, it writes `subtasks.json` and checks for dependency cycles.
- **Where results land:** `~/.claude/jobs/<id>/phases/<sprint>/subtasks.json`.
- **Plain example:** `/code-decompose docs/specs/new-login.md` → shows a task table, asks to confirm, then saves.
- **Gotchas:** Needs an active job. Always asks before writing; dependency cycles are rejected.

### /code-parallel
- **One-liner:** Dispatches one AI worker per task, each in its own isolated repo copy, running independent tasks at once.
- **When you'd use it:** After decomposing, to actually build the pieces concurrently.
- **Syntax:** `/code-parallel [--only t1,t2]`
- **Arguments & flags:**
  - `--only <ids>` — build only these task IDs. Default: all of them.
- **Under the hood:** Sorts tasks by dependency into "waves", gives each its own git worktree + branch, and runs independent ones in parallel.
- **Where results land:** `~/.claude/jobs/<id>/phases/<sprint>/parallel-<timestamp>/manifest.json` + a journal line.
- **Plain example:** `/code-parallel --only t1,t2` → two workers run at once; you get a status table.
- **Gotchas:** Needs `subtasks.json` first. A task whose dependency failed is marked `blocked`, not run.

### /code-merge
- **One-liner:** Reviews what the workers built and, on request, folds the branches back into main in order.
- **When you'd use it:** After the parallel run, to inspect and integrate.
- **Syntax:** `/code-merge [--apply] [--from t3]`
- **Arguments & flags:**
  - `--apply` — actually merge (cherry-pick). Without it, **review-only**.
  - `--from <task-id>` — when applying, start at this task (used to resume after fixing a conflict).
- **Under the hood:** Loads the latest run manifest, flags likely conflicts (overlapping files), and with `--apply` cherry-picks each task's commits in dependency order, stopping on the first conflict.
- **Where results land:** A printed merge plan; with `--apply`, commits land on your current branch.
- **Plain example:** `/code-merge` (preview) then `/code-merge --apply` (integrate).
- **Gotchas:** Never auto-applies. Skips empty/failed/blocked/dirty tasks. Never deletes worktrees automatically — it prints the cleanup commands for you.

---

# Knowledge base — your searchable memory

### /kb-index
- **One-liner:** Builds/refreshes the searchable index over your knowledge base.
- **When you'd use it:** After adding or editing notes, decisions, or lessons.
- **Syntax:** `/kb-index [--full] [--scope universal|<project-id>|all]`
- **Arguments & flags:**
  - `--full` — rebuild from scratch. Default: incremental (only changed files).
  - `--scope <value>` — limit to `universal`, one project, or `all` (default).
- **Under the hood:** Chunks and embeds your knowledge files via a local model and stores vectors at `~/.claude/knowledge/.index/`.
- **Where results land:** `~/.claude/knowledge/.index/` + a per-file summary in the console.
- **Plain example:** `/kb-index --full` → rebuilds everything and prints a row count.
- **Gotchas:** Needs the embedding model — if search errors, run `ollama pull nomic-embed-text` then re-index.

### /kb-search
- **One-liner:** Meaning-based search over your knowledge base (not keyword matching).
- **When you'd use it:** To recall a past note/decision/lesson when you don't remember the exact words.
- **Syntax:** `/kb-search "<query>" [--k N] [--scope universal|<project-id>|all] [--decisions-only]`
- **Arguments & flags:**
  - `"<query>"` — the search phrase (required).
  - `--k N` — number of results. Default: 5.
  - `--scope <value>` — restrict to `universal`, one project, or `all` (default).
  - `--decisions-only` — only return decision records.
- **Under the hood:** Embeds your query and returns the closest chunks; hits in your active project get a small relevance boost.
- **Where results land:** Console — ranked snippets with scores and source paths.
- **Plain example:** `/kb-search "merge gate rules" --k 3 --scope universal`.
- **Gotchas:** Empty index → no hits; run `/kb-index --full` first.

---

# Decisions & guidance — the self-improvement loop

See the [**Decision log**](DECISIONS.md) for every record in plain language.

### /decision-feedback
- **One-liner:** Attaches a verdict (worked / didn't / mixed) to a past decision.
- **When you'd use it:** Once you know whether a decision actually panned out.
- **Syntax:** `/decision-feedback <id> "<text>" [--outcome worked|didnt|mixed] [--urgent]`
- **Arguments & flags:**
  - `<id>` — the decision ID, e.g. `d014`.
  - `"<text>"` — your verdict in words.
  - `--outcome <value>` — `worked` (default), `didnt`, or `mixed`. A negative outcome flags the record for review.
  - `--urgent` — also surface it on the dashboard immediately.
- **Under the hood:** Appends a feedback line to that decision's record under `## Feedback`.
- **Where results land:** `~/.claude/knowledge/projects/<project>/decisions/<id>-*.md`.
- **Plain example:** `/decision-feedback d014 "held up across the fleet" --outcome worked`.
- **Gotchas:** Unknown ID errors — see the [Decision log](DECISIONS.md) for valid IDs. Author is recorded as `kevin`.

### /consolidate-decisions
- **One-liner:** Rolls all decision records + their feedback into readable guidance docs.
- **When you'd use it:** Periodically, or after attaching feedback, to refresh the "what works / what to avoid" guidance.
- **Syntax:** `/consolidate-decisions`
- **Arguments & flags:** None.
- **Under the hood:** Writes each project's `decision-guidance.md` (Established / Known mistakes / Open), and promotes patterns proven in 2+ projects to the universal layer. Idempotent.
- **Where results land:** `knowledge/projects/<id>/decision-guidance.md` + `knowledge/universal/decision-guidance.md`.
- **Plain example:** `/consolidate-decisions` → regenerates the guidance and prints "complete."
- **Gotchas:** Overwrites the guidance files (they're regenerated, not hand-edited).

### /project-init
- **One-liner:** Calibrates the universal guidance for a new project and records its deliberate deviations.
- **When you'd use it:** When starting work on a new project.
- **Syntax:** `/project-init [--re-calibrate]`
- **Arguments & flags:**
  - `--re-calibrate` — re-run even if already initialized.
- **Under the hood:** Shows you the universal guidance, asks for per-project overrides, and writes the project's guidance with a calibration marker.
- **Where results land:** `knowledge/projects/<id>/decision-guidance.md`.
- **Plain example:** `/project-init` → prints universal rules, asks for overrides, writes the file.
- **Gotchas:** Interactive — it waits for your input. Already-calibrated projects need `--re-calibrate`.

---

# Routing journal & lessons — tuning which model to use

**The routing journal** (`~/.claude/model-routing-log.md`) is an append-only log of how
each model performed. **The model catalog** (`~/.claude/knowledge/universal/routing.md`)
is the curated "which model for which job" reference. The two commands below move
observations from the noisy journal into the clean catalog.

### /log-routing
- **One-liner:** Jots one hand-written note about how a model just performed.
- **When you'd use it:** Right after a model does something memorable, good or bad.
- **Syntax:** `/log-routing <model> <free-text observation>`
- **Arguments & flags:**
  - `<model>` — the first word: which model the note is about.
  - `<observation>` — everything after: your plain comment.
- **Under the hood:** Appends a timestamped `note` line to the routing journal.
- **Where results land:** `~/.claude/model-routing-log.md`.
- **Plain example:** `/log-routing devstral:24b nailed the multi-file refactor, matched our style`.
- **Gotchas:** The first word is always taken as the model name. The note alone doesn't change routing — that happens via `/consolidate-routing`.

### /consolidate-routing
- **One-liner:** Reviews recent journal notes, proposes catalog edits for your approval, then archives the notes.
- **When you'd use it:** Weekly-to-monthly, or when routing defaults feel stale.
- **Syntax:** `/consolidate-routing`
- **Arguments & flags:** None.
- **Under the hood:** Groups recent entries by model (success rate, avg cost/time), proposes catalog edits, applies the ones you approve, and archives the consolidated entries.
- **Where results land:** Catalog `knowledge/universal/routing.md`; archived entries → `model-routing-log-archive-YYYY-MM.md`.
- **Plain example:** `/consolidate-routing` → "12 entries consolidated, 3 catalog edits applied."
- **Gotchas:** Only deeply analyzes models with 3+ recent entries.

### /consolidate-lessons
- **One-liner:** Files every job's captured lessons into the right knowledge-base document.
- **When you'd use it:** Periodically, to promote per-job lessons into durable knowledge.
- **Syntax:** `/consolidate-lessons`
- **Arguments & flags:** None.
- **Under the hood:** Walks each job's `lessons.md` and appends un-filed lessons to the matching KB file by category + scope, marking them consolidated. Idempotent.
- **Where results land:** `knowledge/universal/...` and `knowledge/projects/<id>/...`.
- **Plain example:** `/consolidate-lessons` → pending lessons get sorted into the KB.
- **Gotchas:** Project-scoped lessons on a job with no project are skipped.

---

# Cost

### /cost
- **One-liner:** Per-project spending ledger — bare call prints it; a number logs a new total.
- **When you'd use it:** To record the running spend from your billing dashboard.
- **Syntax:** `/cost [<new-total> [--source "<s>"] [--note "<text>"]]`
- **Arguments & flags:**
  - `<new-total>` — the new running total (a leading `$` is fine). Omit to just print the ledger.
  - `--source "<s>"` — where the figure came from. Default: `Claude Code billing`.
  - `--note "<text>"` — a free-text note.
- **Under the hood:** Appends a dated row with an auto-computed delta from the previous total.
- **Where results land:** `knowledge/projects/<id>/cost.md`.
- **Plain example:** `/cost 142.50 --note "after wave 2 backlog"` → logs the row and the delta.
- **Gotchas:** Totals are cumulative running totals, not per-entry charges.

---

# Cheat sheet

| Command | One-liner |
|---|---|
| `/job-start "<brief>"` | Start a tracked job |
| `/job-status` | Where am I on the current job |
| `/job-list [--all\|--active\|--done]` | List jobs |
| `/job-phase [next\|back\|done\|<name>]` | Move the job's phase |
| `/job-resume <id>` | Re-activate an old job |
| `/job-lesson <category> "<text>"` | Capture a lesson |
| `/fleet doctor\|list\|test` | Inspect/test the model fleet |
| `/ensemble "<prompt>"` | Ask many models, get a synthesis |
| `/research "<question>"` | `/ensemble` filed into a job |
| `/six-hats "<question>"` | Six-angle analysis |
| `/council "<question>"` | Two-round deliberation |
| `/code-decompose [<spec>]` | Slice a spec into tasks |
| `/code-parallel [--only ...]` | Build tasks in parallel |
| `/code-merge [--apply]` | Review/merge the results |
| `/kb-index [--full]` | Refresh search index |
| `/kb-search "<query>"` | Search your knowledge |
| `/decision-feedback <id> "<text>"` | Verdict on a decision |
| `/consolidate-decisions` | Roll decisions into guidance |
| `/project-init` | Calibrate a new project |
| `/log-routing <model> <note>` | Note a model's performance |
| `/consolidate-routing` | Update the model catalog |
| `/consolidate-lessons` | File lessons into the KB |
| `/cost [<total>]` | Per-project spend ledger |
