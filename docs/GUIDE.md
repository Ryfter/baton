# The orchestrator — full guide (start to finish)

This is the complete walkthrough: what this thing is, how to install it, how to start
it, and a worked example of using it on a real piece of work — with plain-language
explanations of what's happening under the hood at each step.

For the exhaustive list of every command and flag, see the
[**Command reference**](COMMANDS.md). For every design decision in plain language, see
the [**Decision log**](DECISIONS.md).

---

## 1. What this is

It's a **control layer for a team ("fleet") of AI coding models**, built on top of
Claude Code. Instead of talking to one AI, you direct several — paid cloud models,
free CLIs, and local models on your own machine(s) — and the orchestrator keeps track
of what they did, what it cost, what you decided, and what you learned.

In one sentence: **Claude Code becomes the conductor, and a fleet of other models
become the orchestra.**

You interact with it entirely through **slash commands** inside Claude Code (like
`/job-start` or `/ensemble`) plus a **live web dashboard** in your browser.

### The moving parts

| Part | What it is | Where it lives |
|---|---|---|
| **The journal** | An automatic log of every AI dispatch (time, cost, tokens) | `~/.claude/model-routing-log.md` |
| **The fleet** | Your roster of callable AI models | `~/.claude/fleet.yaml` |
| **Jobs** | Tracked units of work, with phases | `~/.claude/jobs/<id>/` |
| **The knowledge base** | Searchable notes, lessons, and decisions | `~/.claude/knowledge/` |
| **The dashboard** | A live web view of all of the above | `http://localhost:8765` |

> Throughout this guide, `~/.claude/` means your home folder's `.claude` directory —
> on Windows that's `C:\Users\<you>\.claude\`.

---

## 2. Install & bootstrap

### Prerequisites

- **Claude Code** (you're already using it).
- **PowerShell 7+** (`pwsh`) — the scripts are PowerShell.
- **Python 3.10+** — for the dashboard and the knowledge-base search.
- **The claude-octopus plugin** — the dispatch layer this builds on.
- **Optional but recommended:** [Ollama](https://ollama.com) (local models + the search
  embedding model), and any provider CLIs you want in the fleet (`codex`, `gemini`/`agy`,
  `gh`, LM Studio).

### Steps

```powershell
# 1. Install the Octopus dispatch plugin (one-time)
claude plugin marketplace add https://github.com/nyldn/plugins.git
claude plugin install octo@nyldn-plugins

# 2. Get this repo
git clone <this repo> D:\Dev\coding-agent-orchestrator
cd D:\Dev\coding-agent-orchestrator

# 3. Bootstrap — copies commands, hooks, scripts, and config into ~/.claude/
pwsh -NoProfile -File scripts\bootstrap.ps1

# 4. (Optional) pull the local search model
ollama pull nomic-embed-text
```

**What bootstrap does:** it deploys all the slash commands, the usage-logging hook, the
helper scripts, and a starter `fleet.yaml` into `~/.claude/`. It's **idempotent** —
safe to re-run any time (e.g. after `git pull`) to re-sync. It also prints a
**version-drift line** at the top so you can see whether `~/.claude/` is behind the repo,
and finishes with a "Next steps" list.

> Re-running later: `pwsh -NoProfile -File scripts\bootstrap.ps1 -Force` overwrites
> deployed copies with the latest from the repo. Add `-NonInteractive` for unattended runs.

### Turn on cost tracking (optional)

To capture spend automatically, add this line to your PowerShell profile (`notepad $PROFILE`):

```powershell
. $HOME\.claude\otel-env.ps1
```

Then restart Claude Code.

### Confirm it worked

```
/fleet doctor
```

You should see a table of your providers, each marked reachable or not.

---

## 3. Start the dashboard

```powershell
cd D:\Dev\coding-agent-orchestrator
python -m uvicorn dashboard.main:app --port 8765
```

Open **http://localhost:8765**. It runs fully offline (no external requests). You'll see:

- **Fleet activity** — live multi-model runs as they happen
- **Portfolio** — every project with its cost, active jobs, decisions, last activity
- **Jobs** — active and recently finished (click for a per-job drill-in)
- **Today's spend** + a **model leaderboard**
- **Knowledge search** — search your notes from the browser
- **Controls** — stop/unload local Ollama / LM Studio models
- **Live activity** — the last few dispatches, refreshing every few seconds

Leave it running in a terminal tab while you work.

---

## 4. Your first session — a full walkthrough

Here's a realistic end-to-end session. Each step shows the command and what happens
behind the scenes.

### Step 1 — Open your project

```powershell
cd path\to\your\repo
claude
```

The usage-logging hook automatically tags every AI dispatch with this project's name,
so it shows up in the dashboard portfolio.

### Step 2 — Start a job

```
/job-start "rewrite the auth middleware"
```

*Under the hood:* creates `~/.claude/jobs/<id>/` (manifest, brief, phase-log, lessons)
and marks it the active job, starting at the **research** phase. From now on your work
is tracked against this job.

### Step 3 — Research with the whole fleet

```
/research "safest way to migrate session tokens without invalidating logins?"
```

*Under the hood:* pulls the top-3 most relevant snippets from your *existing* knowledge
base and prepends them to the prompt, then sends the question to your research roster of
models **all at once**. Each model answers into its own file; Claude reads them all and
writes a single `synthesis.md` highlighting agreement, disagreement, and a recommendation
— filed into the job's research folder.

For a *decision* rather than open research, use a structured method instead:

```
/six-hats "should we adopt sliding-window refresh tokens?"
/council  "should we adopt sliding-window refresh tokens?" --providers claude-cli,codex
```

- `/six-hats` examines it from six fixed angles (facts, feelings, risks, benefits,
  creativity, process).
- `/council` runs a two-round debate where models refine after seeing each other's answers.

### Step 4 — Capture what you learned

```
/job-lesson knowledge "tokens are HS256 today; rotating without invalidating needs a grace window in the validator"
```

*Under the hood:* appends the lesson to the job's `lessons.md`. Later, `/consolidate-lessons`
promotes it into the durable knowledge base.

### Step 5 — Design

Write your design spec in conversation with Claude and save it (e.g. to
`<job>/phases/design/auth-rewrite.md`). When the spec is ready, advance the phase:

```
/job-phase next        # research → design → code.sprint-1
```

### Step 6 — Build it in parallel

```
/code-decompose docs/specs/auth-rewrite.md
```

*Under the hood:* Claude proposes a list of small subtasks (each with the files it'll
touch and what it depends on), shows you the plan, and on your confirmation writes
`subtasks.json`.

```
/code-parallel
```

*Under the hood:* each subtask is handed to its own AI worker running in an **isolated
copy of the repo** (a git worktree), so they can't collide. Independent tasks run at the
same time; dependent ones wait their turn.

```
/code-merge            # preview the integration plan + likely conflicts
/code-merge --apply    # actually fold the finished branches into your main branch
```

*Under the hood:* it flags tasks that touched the same files (likely conflicts), then
cherry-picks each task's commits in dependency order, stopping safely at the first real
conflict so you can resolve it.

### Step 7 — Wrap up

```
/job-phase done        # closes the job, prompts for retro feedback on its decisions
/cost 187.42           # log your new running billing total
```

---

## 5. The self-improvement loop

The orchestrator gets smarter the more you use it. Three rollups turn day-to-day
exhaust into durable guidance:

| Run periodically | What it does |
|---|---|
| `/consolidate-lessons` | Files your per-job lessons into the knowledge base |
| `/consolidate-decisions` | Rolls decision records + their verdicts into guidance docs |
| `/consolidate-routing` | Turns notes about model performance into a "which model for what" catalog |

**Decisions** are special. Whenever a significant choice is made, it's captured as a
record (what was chosen, the alternatives, the reasoning). Later you attach a verdict:

```
/decision-feedback d011 "the A/B held up; smaller model is fine" --outcome worked
```

A `worked` verdict moves the decision into **Established patterns**; `didnt`/`mixed`
moves it into **Known mistakes**. Patterns proven across **two or more projects** get
promoted into **universal** guidance that applies everywhere. See the
[Decision log](DECISIONS.md) for the full list in plain language.

---

## 6. Working across multiple projects

Just repeat the session flow in any repo. Each project gets:

- its own row in the dashboard portfolio,
- its own decision-guidance and cost ledger,
- its own job history.

The **universal** knowledge layer captures patterns that recur across projects, so
lessons learned in one project quietly improve your defaults everywhere.

---

## 7. Maintenance & troubleshooting

| Symptom | Fix |
|---|---|
| A model shows as unreachable | `/fleet doctor` to re-probe; check the CLI is installed / the machine is on |
| Search returns nothing | `/kb-index --full` (and `ollama pull nomic-embed-text` if needed) |
| `~/.claude/` looks out of date | re-run `pwsh scripts\bootstrap.ps1 -Force` (idempotent) |
| Want to confirm nothing's broken | `python -m pytest dashboard kb -q` + the `scripts\test-*.ps1` suites |
| Stop auto-capturing decisions | create `~/.claude/decisions-off` (global) or a per-project `decisions-off` |

---

## 8. Where to go next

- [**Command reference**](COMMANDS.md) — every command, every flag, plain language.
- [**Decision log**](DECISIONS.md) — every design decision and why.
- [Roadmap](roadmap.md) — what's shipped and what's parked.
- [Design specs](superpowers/specs/) — the deep reasoning behind each feature.
