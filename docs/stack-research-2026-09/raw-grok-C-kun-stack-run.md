# Kun's four tools + no-mistakes, for a collapsed Baton

Snapshot: 2026-09-09. Sources: each repo README, GitHub API (stars/push/license/contributors), firstmate `docs/architecture.md` + `docs/configuration.md` + `.agents/skills/quota-array-dispatch/SKILL.md`, no-mistakes docs site (`installation`, `daemon`, `environment`, `global-config`), Kun `TOOLS.md`.

| Repo | Lang | License | Stars | Last push (UTC) | Open issues | Kun / others (top human) |
|---|---|---|---|---|---|---|
| [no-mistakes](https://github.com/kunchenguid/no-mistakes) | Go | MIT | 8356 | 2026-09-09 02:16 | 147 | 397 / khaira777=8 |
| [firstmate](https://github.com/kunchenguid/firstmate) | Shell | MIT | 5050 | 2026-09-09 02:14 | 1182 | 479 / karotkriss=14 |
| [gnhf](https://github.com/kunchenguid/gnhf) | TypeScript | MIT | 3968 | 2026-09-04 14:09 | 17 | 78 / jasonqlwilliams-alt=5 |
| [treehouse](https://github.com/kunchenguid/treehouse) | Go | MIT | 1649 | 2026-09-07 23:17 | 13 | 33 / karotkriss=3 |
| [quota-axi](https://github.com/kunchenguid/quota-axi) | TypeScript | MIT | 85 | 2026-09-08 14:32 | 10 | 59 / RooseveltAdvisors=3 |

All five are `kunchenguid` public MIT. Single-maintainer in practice: Kun writes almost everything; bots (release-please / github-actions) are #2 on four of five. firstmate is the outlier by volume (1182 open issues) and by platform (macOS/Linux badge; no Windows).

---

## 1. Per-tool, current state

### firstmate — crew dispatcher (agent distro, not a CLI)

**What it actually is.** A cloned directory that turns one coding-agent session into a captain's liaison. You talk to one agent (the first mate). It spawns crewmates in visible session endpoints (tmux default; herdr, zellij, cmux, orca also), each in an isolated git worktree, supervises them with a zero-token bash watcher, and returns PRs / approved local merges / scout reports. Optional persistent secondmates (local or SSH-whole-home). Explicitly **not** a model, harness, skill, MCP server, or installable app. The product *is* `AGENTS.md` + `.agents/skills/` + `bin/*.sh`.

**Install / prereqs.**

```sh
gh auth login
git clone https://github.com/kunchenguid/firstmate
cd firstmate
printf 'herdr\n' > config/backend          # Kevin already runs Herdr
# then one verified primary harness, in this checkout:
claude          # or: grok --trust   or: pi
```

Required: a verified primary harness (Claude Code / Grok / Pi co-primary; also Codex, OpenCode, Cursor Agent CLI, omp, pi-signed), git, authenticated `gh`, and a session backend (tmux default; herdr needs `jq` + a compatible `herdr` binary). firstmate detects missing tools and **asks consent before installing**. Platform badge: **macOS | Linux**. Not Windows.

Also expected on PATH for a full factory: `treehouse`, `no-mistakes`, `quota-axi`, `gh-axi`, `tasks-axi` (bootstrap-required for backlog mutations). Kun's own setup walkthrough also installs `chrome-devtools-axi` and `lavish-axi`.

**Day-to-day (you talk; scripts run).**

```text
# in the firstmate checkout, after launching the harness:
ahoy! look at github.com/you/api, then add rate-limit middleware...
/bearings                          # four-section fleet digest
/afk                               # walk-away supervisor
/stow                              # persist session knowledge to data/
/updatefirstmate                   # fast-forward distro + secondmates
```

Scripts the first mate actually shells out to (you almost never type these):

```sh
bin/fm-spawn.sh ...                # lease worktree + launch crewmate
quota-axi                          # once per intake, default TOON
treehouse get --lease --json --lease-holder fm-<id>
git -C "$worktree" push no-mistakes
bin/fm-pr-merge.sh https://github.com/you/api/pull/N
treehouse return --force --if-lease-id "$lease_id" "$path"
```

**On-disk state (gitignored; this *is* the factory home).**

```
<firstmate-clone>/                 # FM_ROOT (tracked: AGENTS.md, bin/, .agents/)
  config/backend                   # herdr | tmux | ...
  config/crew-harness              # claude | grok | pi | ...
  config/crew-dispatch.json        # NL rules → {harness,model,effort}[]
  config/secondmate-harness
  projects/<name>/                 # clones; firstmate is read-only except guarded ops
  data/projects.md                 # per-project mode: no-mistakes | direct-PR | local-only [+yolo]
  data/backlog.md                  # tasks-axi markdown backend
  data/done-archive.md
  data/captain.md                  # fleet prefs
  data/learnings.md
  data/secondmates.md
  data/<task-id>/report.md         # scout reports
  data/briefs/
  state/<id>.meta                  # backend=, worktree=, harness=, pr=, lease
  state/<id>                       # append-only status log
  state/.wake-queue
  state/.watch.lock
  .env                             # optional Relay pairing token
  .no-mistakes/                    # local gate state if this repo itself is gated
```

Override home with `FM_HOME=...` so `bin/` stays in the clone and operational dirs live elsewhere.

**Does NOT:** pick a model by itself (you write `config/crew-dispatch.json`; it ranks candidates against quota-axi), merge without captain say-so unless `+yolo`, touch the captain's project clone (crewmates work in treehouse/Orca worktrees), run overnight unattended loops (that's gnhf), score local LM Studio boxes, enforce a dollar budget, or run on Windows as a first-class platform.

---

### gnhf — overnight sequential loop (good night, have fun)

**What it actually is.** A ralph/autoresearch-style CLI: one command, one objective, one agent, many small committed iterations until you stop it or a cap hits. Each success is an unsigned git commit + a line in `notes.md`. Failures `git reset --hard` (except commit failures, which leave work for repair). Waits out Claude 5-hour windows instead of burning extra credits. Live TUI. Agent-agnostic (claude/codex/copilot/pi/cursor/rovodev/opencode + `acp:<target>`).

**Install / prereqs.**

```sh
npm install -g gnhf
# from a clean git repo:
gnhf "reduce complexity of the codebase without changing functionality"
```

Needs a supported coding-agent CLI signed in. macOS / Linux / **Windows**. Config created on first run at `~/.gnhf/config.yml`.

**Day-to-day.**

```sh
gnhf "add rate-limit middleware, 100 req/min per key, tests"
gnhf --max-iterations 20 --max-tokens 2000000 --stop-when "tests pass and middleware documented"
gnhf --worktree "..." &            # parallel runs; own git worktrees, NOT treehouse
gnhf --current-branch --push "..." # live branch; no force-push, no auto-pull
gnhf                               # resume when already on a gnhf/ branch
```

**On-disk.**

```
~/.gnhf/config.yml
<repo>/.gnhf/runs/<runId>/
  prompt.md
  notes.md
  gnhf.log                         # JSONL debug
  iteration-<n>.jsonl
  end-state.json
  acp-sessions/                    # if --agent acp:...
<repo>-gnhf-worktrees/<run-slug>/  # only with --worktree
```

Branch: `gnhf/<slug>` (or current branch with `--current-branch`). `.gnhf/` is gitignored locally.

**Does NOT:** dispatch a crew, read quota-axi, call firstmate, use treehouse, run no-mistakes, open a PR (unless you `--push` and something else opens one), decompose into parallel workers (one agent, sequential; `--worktree` is N independent gnhf processes you launched), or learn from benchmarks. Telemetry on by default (`GNHF_TELEMETRY=0` to kill); no prompts/paths/branches sent.

---

### quota-axi — data-only quota snapshot

**What it actually is.** AXI CLI that reads *local* vendor credential stores and hits first-party usage endpoints, then prints one compact TOON (or `--json`) of remaining windows for Claude, Codex, Cursor, Copilot, Grok, Kimi, Z.AI, Alibaba, OpenCode Go, Antigravity. Publishes `spendPriority` (forfeiture-of-paid-allowance scalar) and runway. **Never routes, never recommends, never proxies, never logs in, never imports cookies.** Optional delegated refresh = run *that vendor's* non-interactive CLI, then re-read the store.

**Install / prereqs.** Node **22.19+**.

```sh
npx skills add kunchenguid/quota-axi --skill quota-axi -g   # recommended
# or
npm install -g quota-axi
# macOS Keychain once:
quota-axi --allow-keychain-prompt
```

macOS / Linux / Windows.

**Day-to-day.**

```sh
quota-axi                          # default TOON — this is what firstmate captures
quota-axi --provider claude,codex,grok --json
quota-axi auth                     # sources, no secret values
quota-axi --tui                    # human live view
quota-axi models --sort runway     # opt-in comparator, still not a recommendation
```

**On-disk.** Reads (does not own): `~/.claude/.credentials.json`, macOS Keychain, `~/.codex/auth.json`, `~/.grok/auth.json`, Cursor `state.vscdb` / `~/.config/cursor/auth.json`, Copilot `apps.json`, Pi/OpenCode auth files. Stale per-provider cache is internal. Skill copy at `~/.claude/skills/quota-axi` if installed that way. No routing state.

**Does NOT:** see LM Studio / Ollama / Hermes / OpenClaw / any local GPU. Does not enforce a Governor. Does not rank a winner (default `quota[]` stays in provider-declaration order). Does not know Baton's private fleet.

---

### treehouse — pooled reusable git worktrees

**What it actually is.** Go CLI. Per-repo pool of detached-HEAD worktrees under `~/.treehouse/` (or `--root .` → `<repo>/.treehouse/`). Acquire → agent works → `exit`/`return` recycles the slot with `node_modules` / build cache intact. Durable `--lease` for callers that need a path with no subshell (this is the firstmate path). No daemon. Conflict detection via processes + leases. Optional experimental jj backend.

**Install / prereqs.** git. macOS / Linux / **Windows**.

```sh
curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh
# Windows:
irm https://kunchenguid.github.io/treehouse/install.ps1 | iex
# or: nix run github:kunchenguid/treehouse    or: go install github.com/kunchenguid/treehouse@latest
```

**Day-to-day.**

```sh
cd ~/src/api && treehouse          # subshell in a pooled worktree; exit returns it
treehouse status --json
treehouse get --lease --lease-holder fm-042 --json
# {"path":"...","lease_id":"...","lease_holder":"fm-042","leased_at":"...","base_branch":"main"}
treehouse return --force --if-lease-id "$lease_id" "$path"
treehouse prune --yes              # dry-run unless --yes; never touches leased slots
```

**On-disk.**

```
~/.treehouse/<repo>-<hash>/<n>/<repo>/     # pool slots
  treehouse-state.json                     # atomic; leases live here
~/.config/treehouse/config.toml            # user-level (hooks only here)
<repo>/treehouse.toml                      # repo-level: max_trees, root, base_branch
<repo>/.worktreeinclude                    # optional seed of gitignored files
```

**Does NOT:** run agents, review code, open PRs, or know firstmate. Isolation only. firstmate *calls* it; gnhf does **not** (gnhf uses `git worktree` into `<repo>-gnhf-worktrees/`). no-mistakes also does **not** (it makes its own detached worktrees under `~/.no-mistakes/worktrees/`).

---

### no-mistakes — pre-merge git-proxy gate

**What it actually is.** Local git remote named `no-mistakes` in front of origin. `git push no-mistakes` lands in a local bare repo; a daemon spins a **disposable** worktree (not treehouse) and runs `review → test → docs → lint → push → PR → CI`. Safe mechanical fixes auto-apply; judgment findings park. Forwards to the real remote only after local gates are green, then opens the PR and babysits CI. Agent-agnostic. TUI + `/no-mistakes` skill + `no-mistakes axi` TOON.

**Install / prereqs.** git + one runnable pipeline agent (`claude|codex|grok|rovodev|opencode|pi|copilot|agy|cursor|acp:*`). Optional: `gh` / `glab` / etc. for PRs.

```sh
curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh
# Windows:
irm https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.ps1 | iex
cd ~/src/api && no-mistakes init
```

Installer writes `~/.no-mistakes/bin/no-mistakes`, links into `~/.local/bin` or `/usr/local/bin`, and `no-mistakes daemon restart` (launchd / systemd user / Windows Task Scheduler). macOS / Linux / **Windows**.

**Day-to-day.**

```sh
git push no-mistakes               # start the gate; your WD is untouched
no-mistakes                        # attach TUI
no-mistakes -y                     # wizard: branch + commit + push, auto
# from a coding agent:
/no-mistakes add rate-limit middleware...
no-mistakes axi status             # what firstmate's watcher actually polls
no-mistakes doctor
no-mistakes eject                  # un-gate this repo
```

Pipeline (from README/docs): intent (optional transcript extract) → rebase → **review** (fresh agent; auto_fix.review default **0**) → **test** → **docs** → **lint** → push → PR → CI monitor + auto-fix. Review findings are human-gated by default.

**On-disk (`NM_HOME` default `~/.no-mistakes`).**

```
~/.no-mistakes/
  bin/no-mistakes
  config.yaml                      # global agent, timeouts, auto_fix, worktree_roots
  state.sqlite                     # runs, findings, local agent_invocations
  socket  daemon.pid  daemon.lock
  repos/<id>.git                   # bare gate remotes (hooks live here)
  worktrees/<repoID>/<runID>/      # disposable pipeline worktrees
  logs/  evidence/  eval/  servers/
<repo>/.no-mistakes.yaml           # tracked repo config (commands.test/lint, intent)
<repo>/.git/config                 # remote "no-mistakes" → ~/.no-mistakes/repos/<id>.git
```

**Does NOT:** dispatch a crew, pool/reuse worktrees (each run is disposable), read quota-axi, score local models, or merge the PR (it opens it and watches CI; merge is still you, or firstmate `+yolo` / `fm-pr-merge.sh`). Official release binaries embed Umami telemetry to `https://a.kunchenguid.com`; disable with `NO_MISTAKES_TELEMETRY=0`. Prompts, paths, branches, diffs are not sent. `go install` builds have telemetry off unless you set a website ID.

---

## 2. How they compose

They are **not** a nested stack of five. They are three layers plus one sibling loop.

```
                    Kevin (captain)
                          │  chat, or `baton go "..."` wrapping that chat
                          ▼
 ┌─────────────────────────────────────────────────────────────┐
 │ firstmate home  (AGENTS.md + bin/ + gitignored data/state)  │
 │  intake: decompose, pick project mode, pick dispatch profile │
 │  READ  quota-axi          (once; data only; no route)       │
 │  RANK  quota-array-dispatch skill (firstmate-owned policy)  │
 └──────────────┬───────────────────────────────┬──────────────┘
                │ spawn                         │ overnight alternative
                ▼                               ▼
     treehouse get --lease              gnhf "<objective>"
     ~/.treehouse/<repo>/N/             sequential iterations
                │                       own git worktrees
                ▼                       does NOT call firstmate
     herdr tab / tmux window            does NOT call treehouse
     crewmate (claude|codex|grok|pi)    does NOT call quota-axi
                │                       does NOT call no-mistakes
                │ implement + commit
                ▼
     git push no-mistakes               ◄── only if data/projects.md mode = no-mistakes
                │                           (direct-PR skips the gate; local-only never pushes)
                ▼
     no-mistakes daemon
     ~/.no-mistakes/worktrees/<repo>/<run>/     ◄── different worktree than treehouse
     review → test → docs → lint → origin push → gh pr create → CI
                │
                ▼
     PR URL written into firstmate state/<id>.meta  pr=
     captain: "alright merge it"  →  bin/fm-pr-merge.sh  (gh-axi pr merge --squash)
     treehouse return --force --if-lease-id ...
```

**Answers to the nesting questions, from the code/docs:**

- **Does firstmate use treehouse?** Yes, for tmux/herdr/zellij/cmux. `fm-spawn.sh` leases a pooled worktree (`treehouse get --lease`). Orca is the exception: Orca owns worktree + terminal, and `fm-spawn.sh` does **not** call treehouse. Herdr is session-only; treehouse still provides the worktree.
- **Does firstmate call no-mistakes?** Yes, as a **project mode**, not as an internal library. `data/projects.md` records `no-mistakes` | `direct-PR` | `local-only`. The crewmate is briefed to `git push no-mistakes`; firstmate's watcher then attributes the run via `bin/fm-nm-run-lib.sh` + `no-mistakes axi status`. firstmate also `no-mistakes init`s newly cloned projects when seeding a secondmate home.
- **gnhf vs firstmate.** Alternatives, not nested. firstmate = interactive crew, parallel tasks, PRs. gnhf = unattended sequential loop on one objective. gnhf does not spawn firstmate; firstmate does not invoke gnhf. You *can* run `gnhf` inside a treehouse worktree by hand, but nothing wires that.
- **Where quota-axi is read.** By **firstmate, at intake, before spawn**. One `quota-axi` (no `--json`) per intake; the TOON is reused for every candidate. Three gates (eligibility, reasoning-class, runway-feasibility) then rank survivors by `spendPriority`. Shell helper `bin/fm-quota-choose.sh` is a narrow post-reasoning picker; it never takes a second snapshot. Optional mid-task: `bin/fm-procevent-quota.sh` wakes if the tracked provider drops below a threshold or runway becomes `exhausted_now`. gnhf does not read quota-axi (it waits on Claude rate-limit events from the agent itself). no-mistakes does not read quota-axi (it uses `agent:` / fallbacks in `~/.no-mistakes/config.yaml`).

---

## 3. THE RUN — `baton go "add rate-limit middleware to the API, 100 req/min per key, tests"`

Assumption used below: Baton's `go` becomes a thin wrapper that either (a) types the objective into a live firstmate primary, or (b) is replaced by talking to firstmate. The four Kun tools have **no** `baton` binary. Walk is the firstmate-native path, which is what you actually get if you adopt these.

### Interactive (firstmate) path

**0. Human, once per machine / repo (not per feature).**

```sh
# Mac Mini / Omarchy (Linux): this works. Windows boxes: firstmate is not a supported primary.
cd ~/firstmate && printf 'herdr\n' > config/backend && grok --trust   # or claude / pi
# firstmate bootstrap: MISSING: treehouse / no-mistakes / quota-axi / gh-axi / tasks-axi
# HUMAN GATE 1 — consent to install each missing tool. Refuses to silently curl|sh.
```

Register the API repo (HUMAN GATE 2 — project mode + merge autonomy):

```
data/projects.md  →  api  no-mistakes          # or no-mistakes +yolo
config/crew-dispatch.json  (example Kevin would write)
  when: "implementation + tests in an existing service"
  use:
    - { harness: "codex", model: "gpt-5.4",  effort: "medium" }
    - { harness: "grok",  model: "grok-4.5", effort: "high" }
    - { harness: "pi",    model: "local/whatever", effort: "high" }  # only if pi catalog lists it
```

quota-axi **cannot** see LM Studio, so a local-Hermes candidate only survives gate 1 if you lie-map it through a harness quota-axi actually models, or if you accept "unknown spendPriority, disclosed uncertainty." That is a Baton-core hole (section 4).

**1. Intake (firstmate primary; strongest-judgment model — this is the expensive turn).**

You: `ahoy! in projects/api, add rate-limit middleware, 100 req/min per key, with tests.`

firstmate:

1. Reads `data/projects.md`, `data/backlog.md`, `data/captain.md`.
2. Runs `quota-axi` once. Captures TOON.
3. Judges task shape: **one ship task**, not a scout. Rate-limit + tests is one bounded change; it does **not** fan out to N workers unless you asked for independent slices (e.g. "also rewrite the dashboard"). Typical split for *this* prompt: **1 crewmate**. (README example "fix flaky login + add dark mode" → 2. This prompt is one feature.)
4. Mode: `no-mistakes` from the registry. `yolo` off unless registered.
5. Matches `config/crew-dispatch.json`. Profile array → `quota-array-dispatch`:
   - Gate 1 eligibility (catalog + auth).
   - Gate 2 reasoning-class: implementation+tests → medium, not max.
   - Gate 3 runway vs likely-completion horizon; `exhausted_now` vetoes.
   - Rank by `spendPriority`. Genuine tie → **HUMAN GATE 3**, captain picks.
6. Writes `data/backlog.md` (`tasks-axi`): item moves Queued → In flight.
7. `bin/fm-brief.sh` writes `data/briefs/<id>.md` with DoD + `--intent` string for no-mistakes.

Cost: 1 primary turn on whatever the firstmate session is (Claude/Grok/Pi). This is the "director" spend.

**2. Acquire worktree (treehouse).**

```sh
# fm-spawn.sh, approximately:
TREEHOUSE_LEASE_HOLDER=fm-042
treehouse get --lease --lease-holder fm-042 --json
# path: ~/.treehouse/api-<hash>/3/api
# lease_id: <random>
```

Recorded in `state/042.meta`: `worktree=... lease_id=... backend=herdr harness=codex model=gpt-5.4 effort=medium mode=no-mistakes`.

**3. Dispatch worker (firstmate → herdr + coding agent).**

`fm-spawn.sh` creates a Herdr tab, cds into the leased worktree, launches e.g.:

```sh
codex exec --full-auto -m gpt-5.4 -c model_reasoning_effort="medium"
# or grok / pi / claude --dangerously-skip-permissions, per adapter
```

Worker cost: one Codex (or chosen) session, medium effort — the implementation spend. Not a frontier "max" unless the dispatch rule said so.

Crewmate is instructed (via generated brief) to:

- verify `pwd -P` is the treehouse worktree, not the captain clone
- implement middleware + tests
- commit on `fm/042` (or similar)
- **not** `git push origin`
- `git push no-mistakes`

Status log `state/042` appends `working:` / `paused:` / `done: PR ...` / `needs-decision:`.

**HUMAN GATE 4** — only if the crewmate hits a real judgment (API shape, existing limiter conflict). Trivial reversible calls it is told to make itself. firstmate's watcher stays zero-token until an actionable wake.

**4. Gate (no-mistakes), before it is a PR.**

```sh
# inside the treehouse worktree:
git push no-mistakes fm/042
```

Daemon:

1. Bare repo `~/.no-mistakes/repos/<id>.git` accepts the push.
2. Creates **a second, disposable** worktree: `~/.no-mistakes/worktrees/<repoID>/<runID>/`. This is **not** the treehouse slot. Isolation-for-validation ≠ isolation-for-parallel-work (Kun's own distinction).
3. Pipeline agent from `~/.no-mistakes/config.yaml` (`agent: auto` → first of claude, codex, grok, ...). This is a **fresh** reviewer, ideally a different model than the author — Kun's stated preference. Cost: several bounded invocations, default `agent_timeout` 30m each:
   - review (auto_fix.review = **0** → findings park)
   - test (auto_fix 3)
   - docs (auto_fix 3)
   - lint (auto_fix 3)
4. **HUMAN GATE 5** — TUI / `/no-mistakes` / `axi`: approve / fix / skip each `ask-user` finding. Mechanical ones auto-apply. Review findings almost always hit this because auto-fix is off.
5. Push to origin, `gh pr create` with pipeline attestation in the body. Evidence optionally on orphan branch `no-mistakes/evidence`.
6. CI monitor. Failures auto-fix up to 3, then park. Merge-conflict repairs always re-review.

firstmate watcher sees `no-mistakes axi status` → `ci,running` then `done: PR https://github.com/you/api/pull/42`. Wakes the first mate. First mate reports to you.

**5. Merge and teardown.**

**HUMAN GATE 6** — you: `alright merge it`. firstmate runs `bin/fm-pr-merge.sh` → `gh-axi pr merge 42 --repo you/api --squash` after a live mergeability read. `+yolo` on the project would have merged without this ask.

Then:

```sh
treehouse return --force --if-lease-id "$lease_id" "$path"
# backlog item → Done; state/<id>.meta retained as receipt
```

**Final PR.** Title/body written by no-mistakes (intent section if transcript matched; pipeline attestation JSON in the body; evidence links). Squash-merged by you (or firstmate under `+yolo`). Author is your git identity, not the agent (firstmate even strips Claude co-author trailers on claude launches).

### Overnight (gnhf) instead

You do **not** type `baton go` into firstmate. You:

```sh
cd ~/src/api   # clean tree
gnhf --max-iterations 30 --max-tokens 4000000 --stop-when "rate limit 100/min per key with tests green" \
  "add rate-limit middleware to the API, 100 req/min per key, tests"
# sleep
```

What changes:

| Step | firstmate path | gnhf path |
|---|---|---|
| Decompose / parallel | 1 ship crewmate (judgment) | 1 agent, N sequential iterations |
| Worktree | treehouse lease | branch `gnhf/<slug>` in the same checkout, **or** `--worktree` → `api-gnhf-worktrees/<slug>/` (plain git worktree, cache not pooled) |
| Model | quota-axi-ranked dispatch profile | `~/.gnhf/config.yml` `agent:` / `--model`; no quota-axi |
| Human during run | gates 3–6 as they arise | **none**, until morning (Ctrl+C is the only interactive) |
| Verification | no-mistakes full pipeline | whatever the agent does inside an iteration; gnhf only checks "committed a change" vs rollback |
| PR | no-mistakes opens it | **no PR**. You wake up to a branch + `.gnhf/runs/<id>/notes.md`. Then *you* `git push no-mistakes` or hand it to firstmate |
| Merge | captain / +yolo | you, in the morning |

gnhf is the wrong tool for "open a clean PR of a named feature." It is the right tool for "grind tests / reduce complexity / keep going while I sleep" where the objective is mechanically checkable. Kun: overnight loops earn their keep when progress is verifiable and failures discardable.

A sane hybrid: firstmate ships the feature through no-mistakes by day; `gnhf --worktree "tighten rate-limit tests, no behavior change"` overnight on leftover edges.

---

## 4. What Kun's 4 (+ no-mistakes) do NOT give you — Baton-core residue

After adopting these, Baton still has to own anything that is **not** "visible crew + pooled worktrees + subscription quota snapshot + pre-merge gate + overnight grind."

| Residue | Why the 4 don't cover it | Seam (who calls whom) |
|---|---|---|
| **`baton` CLI / `go` verb** | firstmate is chat-in-a-clone, not a CLI. gnhf is a CLI but sequential. | `baton go` → either exec into the firstmate primary (`fm-send.sh` / herdr submit) or print "talk to firstmate." Do not rebuild spawn. |
| **Local-fleet routing + learned scores** | quota-axi covers Claude/Codex/Cursor/Copilot/Grok/Kimi/Z.AI/Alibaba/OpenCode-Go/agy. **Zero** LM Studio, Ollama, Hermes, OpenClaw, 4090/5090/2070S/Mac Mini/Pi. `spendPriority` is subscription-forfeiture, not quality-per-dollar on a private bench. | Baton router **calls** `quota-axi` for cloud seats, **then** overlays Kevin's measured local scores. Write local boxes as extra candidates in `config/crew-dispatch.json` only after Baton has a provider quota-axi doesn't model — and accept they will always look like `unknown` to quota-axi. |
| **Governor (hard spend cap)** | quota-axi is data; firstmate ranks; neither refuses a spawn because `$` remaining this month is $4. gnhf has `--max-tokens` per run, not fleet-wide $. no-mistakes has per-invocation wall clocks, not money. | Governor sits **in front of** `fm-spawn.sh` / `gnhf`. Read quota-axi + Baton ledger; if over cap, do not spawn. firstmate must not be allowed to "just dispatch." |
| **Grimdex loop (decisions / lessons KB)** | firstmate has `data/captain.md` + `data/learnings.md` + `/stow` (session sweep, decay, budget). That is *fleet ops memory*, not Grimdex. no-mistakes has local `eval/` corpus. Neither is a cross-agent decision record with alternatives + rationale, and neither syncs to the knowledge repo. | After merge: Baton appends Grimdex from firstmate `data/learnings.md` + no-mistakes findings you overrode. Incoming: inject Grimdex slices into firstmate `data/captain.md` (or a skill), not into Kun's tools. |
| **GitHub Projects coordination view** | gh-axi can *operate* Projects. firstmate's `data/backlog.md` is a markdown board, not GitHub Projects. No Projects dashboard in any of the 4. | Baton (or a thin gh-axi wrapper) remains the Projects UI. firstmate backlog is the execution queue; sync one way, don't dual-write. |
| **Mesh / machine placement** | firstmate secondmates can be `host: <ssh>` (Tailscale alias works). Remote secondmate agent is **pinned to Herdr**. Windows firstmate primary is unsupported. No GPU/box scheduler. | Baton owns "this task on the 5090 box." Implementation: a remote secondmate home on that host, or skip firstmate there and run gnhf/no-mistakes natively (both are Windows-ok). |
| **Session substrate** | firstmate *uses* Herdr; it does not replace it. | Keep Herdr. `config/backend` = `herdr`. |
| **Quality-of-local-model benches** | None of the 4 measure pass-rate on Kevin's private tasks. | Baton's learned router. Feed results back as dispatch-rule text, not as a patch to quota-axi (quota-axi will refuse to become a router). |

**Do not rebuild:** worktree pooling (treehouse), overnight grind (gnhf), subscription window math (quota-axi), pre-merge isolation+review+CI (no-mistakes), crew supervision/watchers (firstmate `bin/`).

Target shape of the 5–6k-line core:

```
baton go
  → Governor.allow?(ledger, quota-axi TOON, local scores)
  → route = Router.pick(task, local benches, quota-axi spendPriority)
  → if overnight-shaped: exec gnhf
    else: firstmate intake (or fm-spawn.sh with concrete --harness/--model/--effort already chosen)
  → firstmate uses treehouse + herdr as today
  → crewmate git push no-mistakes as today
  → on merge: Grimdex ingest + Projects update
```

The seam to protect: Baton may **pre-resolve** harness/model/effort and pass them to `fm-spawn.sh`. It must not fork firstmate's watcher, and it must not reimplement no-mistakes' pipeline.

---

## 5. Honest risks of standing on these 4

**Single-maintainer concentration.** Five public MIT repos, one human (Kun, Bellevue). Contributors exist but are noise next to his commit counts. firstmate has **1182 open issues** on a ~3-month-old repo (created 2026-06-12). If he burns out or pivots, you inherit a distro whose contract lives in a 76k-character `AGENTS.md` plus a pile of bash. Mitigation: pin SHAs (`fm-install-treehouse.sh` already pins treehouse 2.0.1 for CI), vendor `bin/` you actually call, treat `AGENTS.md` as a tracked dependency.

**Licenses.** All MIT. Fine. Telemetry is the real contract issue, not SPDX.

**Telemetry.**

- gnhf: anonymous usage, on by default. `GNHF_TELEMETRY=0`.
- no-mistakes: official binaries embed Umami host `https://a.kunchenguid.com`. `NO_MISTAKES_TELEMETRY=0`. `go install` / source builds off unless you set a website ID. Docs claim no prompts/paths/branches.
- quota-axi / treehouse / firstmate: no equivalent advertised. firstmate is a git clone of instructions; nothing phones home unless a helper you install does.

**Maturity.** no-mistakes is the most productized (docs site, daemon, Windows, 8.3k stars). treehouse is small, sharp, Windows-ok. quota-axi is young (85 stars, created 2026-07-06) but the schema is versioned and aggressively specified. gnhf is stable-enough CLI. firstmate is the risk: distro-not-app, harness-specific supervision protocols, experimental backends, remote-secondmate still growing. You are adopting a *workflow religion* plus bash, not a versioned library.

**Windows (Kevin has 3 boxes).**

| Tool | Windows |
|---|---|
| treehouse | yes (`install.ps1`) |
| no-mistakes | yes (`install.ps1`, Task Scheduler daemon, CI has a Windows leg) |
| gnhf | yes (explicit; `.cmd`/`.bat` wrappers) |
| quota-axi | yes |
| **firstmate** | **no** (README badge macOS \| Linux). Herdr stable = macOS/Linux; Windows Herdr is preview, WSL recommended. |
| Orca / cmux backends | macOS-only |

Practical split: Mac Mini + Omarchy laptops run firstmate+herdr. Windows 4090/5090/2070S run gnhf + no-mistakes + treehouse as workers, reached as firstmate **remote secondmates over Tailscale SSH** (remote secondmate agent is Herdr-pinned — so those Windows boxes need WSL or you skip firstmate there and let Baton SSH-start `gnhf`/`codex` directly).

**Harness assumption.** firstmate needs a *verified primary* with a turn-end story (Claude Stop hook, Grok `--trust` + background-notify, Pi extensions, …). Headless `cursor-agent -p` is explicitly the wrong primary. Crewmates can be a different harness than the primary (`config/crew-dispatch.json`). gnhf/no-mistakes are happier as non-interactive CLIs and do not need firstmate's watcher. If Kevin standardizes on Hermes/OpenClaw on Omarchy, firstmate will only see them if someone writes a harness adapter — not present today (verified: claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, omp, gemini/muse/rovo as crew-only).

**quota-axi vs local fleet.** Adopting quota-axi without a Baton overlay will route *as if* the 4090/5090 do not exist. That is the opposite of the audit's "cost-optimal router that LEARNS from measured benchmarks of his private LM Studio fleet."

**Two worktree systems.** treehouse pool (crew) and no-mistakes disposable worktrees (gate) are both in play for one PR. Disk + cache duplication is real; do not try to merge them. Kun is explicit: tool-internal scratch worktrees ≠ user-visible session worktrees.

**gnhf `--worktree` is not treehouse.** Parallel gnhf runs will not share `node_modules` the way treehouse does. If overnight parallel matters, wrap gnhf in `treehouse get --lease` yourself; upstream does not.

**Human gates you cannot delete without `+yolo` and `auto_fix.review > 0`.** Kun's whole point is the human still owns merge and review judgment. Collapsing Baton does not collapse that, and shouldn't.

**Supply-chain.** firstmate's own bootstrap "detects and offers to install" treehouse/no-mistakes/etc. Prefer pin-and-checksum (firstmate CI already does this for treehouse) over `curl | sh` on the 5090.

---

*If the 5–6k-line Baton core is a Governor + learned local router + Grimdex ingest sitting in front of firstmate spawn, this set actually fits. If the core is expected to also be the crew supervisor, you would be reimplementing firstmate and should not bother adopting it.*
