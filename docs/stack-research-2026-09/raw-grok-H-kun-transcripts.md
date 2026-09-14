# Kun Chen transcripts — extraction for Baton

Sources (read in full):
- `KnowledgeDump/Kun-High Throughput Agentic Engineering.txt` — *High Throughput Agentic Engineering*, 2026-09-13 (`MSbacZ99E14`)
- `KnowledgeDump/Kun-Agentic Engineering.txt` — *L8 Principal's Agentic Engineering Workflow*, 2026-06-20 (`iQyg-KypKAA`)
- `KnowledgeDump/Kun- Agentic Dev Environm.txt` — *L8 Principal's Agentic Dev Environment From Scratch*, 2026-07-05 (`5N-okeDdIuI`)
- `KnowledgeDump/Kun-the AI Token Game.txt` — *ex-Meta Principal Explains the AI Token Game*, 2026-06-03 (`sxUPsyNwGgs`)
- `KnowledgeDump/Kun-ChenLinks.txt` — index (dotfiles, axi.md, the four talks, blog)

Stack context: `kun-analysis-context.md` (Baton KEEP-BUILD / ADD / Kun-tool verdicts as of 2026-09-08). This pass does **not** re-inventory his GitHub READMEs. It extracts what the talks say that a tool README does not.

Talk shorthand below: **HT** (high-throughput), **AE** (workflow), **ADE** (dev env), **TG** (token game).

---

## Key extracted knowledge

### Who he is, and what he claims the job is

Kun presents as an L8 principal (Meta, Microsoft, Atlassian; Bing, Windows, Facebook games; later “frontier coding agents” at Atlassian). The June workflow talk claims 40–50 well-tested production PRs a day, “not Minecraft demos.” The September talk is the same person running **36 projects** (mix of public OSS and private) from **one agent session**.

The role he wants the human in is not “senior implementer with a better autocomplete.” It is **captain**: set direction, make product decisions, hold a quality bar. Agents are **crewmates** that get onboarded, dispatched, and supervised. After firstmate takes the juggling, the bottleneck is supposed to move to “what should we build” — talking to users, reading the competitive landscape, writing a “treasure map.” If you run out of prompts for firstmate, that is a success signal: coordination is no longer the scarce resource; product judgment is.

He is explicit that this is not a paid course because he wants to stay in the product business, not the education business. The tools (firstmate, treehouse, no-mistakes, gnhf, lavish, AXI, herder, quota-axi, backpass) are the workflow, published because he wants more people doing this.

### The scarce resource is human attention, not tokens

This is the organizing principle that shows up in every talk and is easy to miss if you only read the CLIs.

- **HT:** the “biggest bottleneck across everything we do with agents is our attention and time.” Do not spend mental bandwidth on context-window tricks. Waste a little; keep the brain on what to build. The value of getting *what to build* right dwarfs token savings from compaction hygiene.
- **AE:** the middle of a task should not need you. You spend time at the **start** (requirements, usually in Lavish) and the **end** (quality bar). Everything in between is how you buy parallel capacity. Reviewing diffs is a self-imposed cap: AI writes faster than you can read, and nobody became an engineer to review diffs all day. Behave like an EM/director: culture + process, not personal code review of every line.
- **HT, calm mode:** a custom Pi extension (`/com`) hides tool calls and chain-of-thought, leaving a boat animation as a liveness signal. Tool-call streams are “distractions and noise.” Toggle details only when you actually need them. Default is *not looking*.
- **HT, ahoy:** chat UX loses you. While you review a Lavish board, firstmate prints a wall of updates. `ahoy` is a cheap skill: summarize what firstmate told you since your last message, plus open decisions you have not made. He says to spam it. It exists because the orchestrator session is not a reliable human inbox.
- **HT, steer vs follow-up (Pi):** Enter = steer (interrupts now). Alt-enter = follow-up (queued until current work finishes). He uses follow-up so firstmate is not “distracted” mid-dispatch. The orchestrator’s serial attention is itself a scarce resource, even if labor is parallel.

Net: he will **burn leftover subscription quota on purpose** and **leave context unoptimized on purpose**, because both are cheaper than captain attention. That is a different objective function than “minimize tokens.”

### Model and harness seating (his actual rules, not the folklore)

Kevin’s framing of Kun as “always the cheapest / least-token model” is **not** what these four talks say. What they say:

**Harness split (HT, Sept 2026).** Claude Code when he wants an Anthropic model (Opus, Fable). **Pi for everything else**, because Pi can use any model and makes switching easy. He uses both. In the June workflow talk he also lists Codex CLI (Rust, smoother, open source so the agent can read its own source and work around bugs; fewer bells, not very customizable) and OpenCode (smooth TUI, every model, more complete than Pi out of the box — “grab from the shelf”). Claude Code: best defaults, richest features, sometimes buggy, less customizable. He is **deliberately agent-agnostic** because “who knows which model or agents will be the best performing one next month.”

**Newer is not better (HT).** As of that recording Grok 4.6 exists. He prefers **Grok 4.5**: faster, more efficient, more straight to the point. 4.6 is “a little bit like Opus 5” with a personality that “doesn’t quite speak like a human.” Rule he recommends: sit with a new model yourself; also read other people’s summaries; do not assume the upgrade wins.

**Dispatch is capability-class, then remaining quota (HT).** `config/crew-dispatch.json` is the rule file. He does **not** write it by hand; he tells firstmate his preferences and firstmate writes the JSON. The classes he walks through:

| Task class | Who he allows |
|---|---|
| New feature work on his paid iOS app | **Always Fable** — “really good at building good UI”; paid product, “taken good care of” |
| Needs image generation | **Codex harness + GPT 5.6** — because Codex has a **native image tool** (OpenAI image model). This is tool-surface routing, not IQ routing |
| Hard technical product design / architecture / “genuinely very difficult” planning | Fable, Kimi K3, Astra (and “Y”) — ambiguous, high-judgment work |
| Simple bugfix whose root cause and expected behavior are already well defined | Luna, Sonnet, Cursor Grok 4.6 |
| Default (nothing matched) | Claude Opus, Cursor, Grok 4.6 high |

When a class lists **multiple** models, firstmate calls **quota-axi** and picks the one with the **most quota remaining**. That is subscription-forfeiture, not “cheapest API dollar,” not “highest quality score.” He says this is so he “don’t waste any quota,” and because people like Theo constantly resetting Codex quota makes it impossible to track by eye. quota-axi’s TUI is for humans; the default CLI is for the agent.

He also **overrides** when he has an opinion. The Fly-with-Me visual prototypes were **explicitly Fable**, in parallel, one crewmate per idea, because he was looking at quota-axi, had a pile of Fable left after vacation, and “why not use that.” So: class → candidates → max remaining quota, with a human veto, and “we have leftover premium quota” is a valid reason to spend premium.

He does **not** mention local GPU boxes, LM Studio, Ollama, or quality-per-dollar scores anywhere in these four transcripts. The dispatch table is cloud subscription seats.

**Default firstmate session (HT).** The captain-facing firstmate in the demo is **Grok 4.5** in Pi. Labor crewmates are whatever the rules say (Opus 5 for Backpass, Fable for visual prototypes, etc.). Firstmate is **not** the implementer. That is load-bearing: because firstmate is not doing the work, it stays interruptible. He keeps typing more prompts while the boat is still moving. Parallelism is “keep giving firstmate ideas”; firstmate spawns; he does not wait.

### Hierarchy: firstmate → second mates → crewmates, across machines

**AE (June):** firstmate is the upgrade after you discover that juggling tmux tabs of crewmates is exhausting. Clone the repo, launch an agent *in that repo*, talk to it. It decomposes (three CLI `update` commands across three AXI projects = three parallel tasks), calls treehouse, launches agents, runs no-mistakes, returns PRs. You keep handing it more work (e.g. “look at the last three open issues in lavish-axi, discuss which are actionable”). Watching it context-switch is “oddly satisfying” because that used to be your job.

**HT (September) — the scale-up that is not in the June talk:** once firstmate is always orchestrating, it has “no time to even talk to me.” He created **second mates**, each a **firstmate that owns a domain** of the charter (Ship app, firstmate development, Eddy’s wallets, AXI, a default). Firstmate routes domain work to the second mate; the second mate spawns its own crewmates, has its own memory and instructions. He can talk to a second mate directly, or through firstmate (which routes). Most of the time he takes the easy path and only talks to firstmate.

**Hardware seating (HT):** Herder can manage agent sessions **across machines**. `local` = MacBook. `mini` = a headless Mac Mini on a shelf (no monitor/keyboard/mouse). The Mini has more hardware, so he assigned most domain second mates to it. The laptop keeps the captain session. This is not “the cloud”; it is a second box as a labor farm, multiplexed into the same UI.

**Surfaces (HT):** a firstmate **bot relays Discord and X** into the same local firstmate session. He `@`s firstmate on a Discord bug report (Treehouse hook not firing) and on an X complaint (Ship “send feedback” copy). Replies go back out through the relay. The point he stresses: **one session holds all intent and context across every project and every inbound channel.** GitHub issues, Discord, X, and his own rambling all funnel in. Firstmate investigates, decides, dispatches; he often never opens the crewmate tab. Mid-talk, a GitHub 500 on `gh pr create` is retried by firstmate without him doing anything — “I may not even be looking at this message.” That retry-without-the-human is a stated value of the orchestrator, not a side effect.

### Per-project merge policy, not a universal gate

**HT, `data/projects.md`:** every project has a policy. Examples he states:

- **Fly with me:** `direct PR + yolo`. Firstmate makes the judgment, raises a PR, **skips no-mistakes**, yolo-merges if it looks good. Toy, nobody depends on it, a bad merge cannot really hurt.
- **Most projects:** no-mistakes **on**.
- **Yolo on** typically when a change **will not release immediately** — there is still a human test-before-release step (Treehouse: he tests at release time, so a PR can yolo-merge after no-mistakes).
- Some projects need his eyes before merge; he tells firstmate which.

**The heuristic (HT):** “For this code change, would you have asked another human to review this code?” If no → you probably do not need no-mistakes. If the change is risky enough that you would have asked a peer → activate no-mistakes. He is explicit that no-mistakes is **slow and token-heavy**; it is not the default for every diff.

**What no-mistakes is, in his words (AE + HT):** not a linter wrapper. Pipeline: understand real intent from the agent session → rebase on latest main, resolve conflicts up front → **adversarial review in a fresh context window** (obvious problems self-correct; product-ambiguous ones escalate to the human) → **end-to-end test against original intent**, with **evidence** (screenshot, video, log) → docs pass → lint → push + PR → **babysit until merge** (conflicts, CI). Isolated worktree, so validation does not touch the working repo. Trigger as CLI or as a skill. He never stares at it; he starts other tasks.

**How he actually looks at a no-mistakes PR (HT, Treehouse warning-fix):** he does **not** start at the diff. He reads: intent (his requirements), what changed, **risk assessment**, testing (9/10 live scenarios that prove the intent; skipped scenario called out as docs-only). Low risk + well tested → **he does not look at the code**. Medium/high risk or unresolved product issue → then he looks. AE says the same: the risk field is how he decides how much review time the change is worth; low-risk problems he could catch are “very likely already caught by the pipeline.”

This is process-as-attention-allocator. The gate is expensive, so he meters it by blast radius, not by ideology.

### Planning and feedback are visual, not markdown walls

**Lavish (AE, then HT).** Named because it is “richer than a rich editor” (he almost called it filthy-rich editor). The agent is instructed to emit an **HTML artifact** in the **current project’s design system**, so prototypes look like the product. Humans annotate specific regions, click decisions at the bottom, send feedback **without returning to the terminal**. He says he cannot go back to reading plan-text in the terminal.

The June demo is a product planning task (High Bit: merge two similar buttons into an achievement system). Default without Lavish = wall of text, hard to point at “this part.” With Lavish = options laid out, clickable decisions, comments on the artifact.

The September demos are **implementation-adjacent visual validation**, not just planning:

- Fly-with-me: three ideas (snowy mountains, northern lights, bird kinds), **three variants each**, each idea a **Fable crewmate in parallel**, deliver in Lavish. He reviews screenshots/previews, picks (raptor, swallow, crane, owl; reject glider as too close to current), sends “build the ones we decided.” A follow-up board covers the chooser UI + colorways; he accepts a straightforward chooser. Mountain board: he rejects “good enough,” asks them to study **photos of Everest and K2**, then picks variant D and asks for taller/sharper pyramid peaks. The point of the photo step: make the agent share the visual referent, not guess from the phrase “good-looking mountains.”
- **Bearings-lavish:** default `bearings` dumps a fleet snapshot in the terminal (hard to read at this volume). The variant is an interactive HTML: charted next / underway / recently landed, plus **captain’s calls** — previously discussed decisions that were never made. He walks the list, marks hold / build-now / non-wedge / later. Firstmate then acts (and discovers one “build now” was already in the codebase). This is how he prevents 36-project decision rot.

**Voice (AE, HT).** Default input. Stanford paper: talking ~3× typing. Fallback to typing for URLs and file paths. Open Super Whisper, local, free. **AE:** Whisper’s initial-prompt / vocabulary field is loaded with project names so transcription hits `lavish-axi` etc. instead of garbling them.

**Rambling as a feature (HT).** He dumps a long unstructured idea-list (three Fly-with-me prototypes, three variants, Fable, Lavish) and expects firstmate to turn it into dispatches. He likes this. The orchestrator’s job includes **parsing captain ramble** into a work graph.

### Memory, skills, and onboarding — and the contradiction with firstmate itself

**Global memory is tiny (AE, ADE).** Claude’s global file and the AGENTS.md standard location are **symlinked to the same ~27-line file**. Everything in it is in **every** session’s system prompt, so bloat is a silent tax. Contents he actually states:

- Never use em-dashes (models default to them; feels robotic in PR descriptions).
- **When making technical decisions, do not overweight development cost.** Models are trained on human estimates (days/weeks/months). He demonstrates: ask Claude to estimate a local 3D FPS with AI enemies → weeks/months; ask it to build one → playable in minutes (he says he has done this many times). That mismatch **biases the model toward cheap, low-quality, unscalable options**. Correct it explicitly: prefer quality, simplicity, robustness, scalability, long-term maintainability.
- Bugfixes: **always reproduce end-to-end as the user would**, not jump to unit tests. Models default to unit tests that do not cover product behavior. E2E is more reliable.
- ADE adds: never auto-add the agent as git co-author (Claude loves this; the human is still accountable). Never hand-edit changelog.md or autogenerated files. On product E2E, be **picky about UI / pixel-perfection**; if something looks off even if unrelated, fix it. Same high bar for lint, test failures, flakiness — fix them even if you did not cause them.
- ADE distributes this one file via Home Manager into **every harness’s** global memory path so Claude / Codex / OpenCode / Pi / Grok behave consistently.

**Project memory (AE).** `CLAUDE.md` / `AGENTS.md` in-repo, also symlinked. Verbose is OK here: what the project is, layout, terminology, important components, how to E2E, conventions. He does **not** author it up front. Every time the agent does something wrong, he corrects it and tells it to **store the learning in that file**. Crewmates on that project get “smarter” over time. “You don’t need any fancy memory system… this markdown file is all it takes.”

**Skills as progressive disclosure (AE).** Project memory bloats. Conditional instructions (e.g. E2E testing — useless on a question) get extracted into a skill. At start the agent only loads the **tiny description**; it reads the body when it decides it needs it. He asks the agent to do the extraction live. Other harnesses may not know how; install Anthropic’s **skill-creator** via Vercel’s `npx skills` CLI (his main skill installer, agent-agnostic).

**Do not install random internet skills (AE).** Two reasons. (1) Security: a skill can instruct the agent to run anything, leak API keys or bank credentials. (2) Quality: popularity ≠ help. He evaluated a skill from a repo with **177k GitHub stars** (“Android Skills,” and “not even written by Karpathy”) on Program Bench: **+5% tokens, worse results**. Stars measure virality. Rule of thumb: do not install any skill that claims to magically improve the agent unless it has published a **rigorous evaluation**.

**Tension he does not acknowledge in these talks:** firstmate itself is a 76k-character AGENTS.md religion (from the existing stack verdict). His own global-memory lecture is “27 lines or you burn tokens on every call.” The product he ships as the orchestrator violates the constraint he teaches for project/global memory. Treat that as a real tradeoff he made for the captain session (firstmate *is* the workflow), not as a principle Baton should copy blindly.

**Backpass (HT, not in the prior Kun-tool verdicts).** A tool that mines **past agent sessions** to propose improvements to `AGENTS.md` / `CLAUDE.md`. The live task is: previously planned “collect agent sessions across multiple remote machines”; pull that plan; dispatch a crewmate. This is session-log → memory-file evolution, closer to Baton’s `/learn` / projectmem loop than to Grimdex decisions.

### Agent ergonomics (AXI) as a first-class design problem

**AE.** Agents’ performance is dominated by the tools you give them, not just the model. GitHub example he benchmarked: **GitHub MCP vs `gh` CLI** on the same tasks — MCP costs **~3× tokens and >2× latency**, “no clear benefits.” AXI (his design standard, axi.md) treats agents as first-class users. He states **ten principles**; the one he quantifies: **token-efficient output (~40% savings vs JSON)**. He built GitHub AXI and Chrome DevTools AXI; the latter uses fewer turns and fewer tokens than other browser tools on his benchmark. Catalog at axi.md. The claim is not “write a prettier CLI”; it is **mileage per agent**.

quota-axi in HT is the same family: human TUI vs agent CLI, default output for the agent.

This is a different “token game” than model picking. He will spend Opus if the class demands it, and **separately** insist that every tool the agent calls is cheap to *read*.

### Long-running labor, isolation, overnight

**The shape of a task (AE):** human at start and end; AI in the middle; longer middles = more parallel human capacity. Complex tasks are harder to complete autonomously, so the overnight question is: how do you keep them busy for 7–8 hours of sleep?

**gnhf / “good night, have fun” (AE).** Objective + stop condition. Loop until the condition, a token cap, or an iteration cap. Live TUI (iterations as moons, commits, token usage). He uses it for **verifiable** objectives or ones where he **trusts the agent’s judgment**: page-load time, E2E coverage, “Android hypothesis auto-research, keep experimenting to improve the metric,” and the High Bit demo — pretend you are a seven-year-old, use the app, find the first usability trap, fix it, rinse and repeat. Wake up to a branch of commits, pick which to keep.

**Why not Claude/Codex `/goal` (AE):** those can do something similar, but gnhf lets him set **token cap / iteration cap / stop condition more precisely**. `/goal` overnight can consume the **weekly quota**. That is the same Governor instinct Baton already has.

**Worktrees (AE).** Two agents in one checkout step on each other. Raw `git worktree add` creates **mental debt**: names, leftover directories, “is an agent still running in highbit-2?” Treehouse: `treehouse` drops you in a fresh pooled worktree; `treehouse status` lists used vs idle; closing the tab frees the slot; next acquire **reuses** idle trees (node_modules/build cache implied by the later tool docs; in the talk he stresses reuse vs create). Parallel pattern he demos: tab + treehouse + Claude, three times, three independent High Bit UX fixes, each told to run no-mistakes after, status bar as the only “do I need to look?” signal, keyboard tab-switching.

**ADE:** Herder replaced tmux for him. He had years of tmux muscle memory; after a few weeks he says Herder is better **because it is built in the agent era** — it understands agents and integrates with mainstream harnesses. Possibly the only multiplexer that works on Windows the same way. Sidebar: workspaces + agents; status of Claude (model, working) without writing your own hooks. He still uses Neovim in a split to review diffs / git (neo-tree, gitsigns) when he wants to; that is optional, not the scaled path.

### Terminal, Nix, and “the ship”

**Why terminal (AE).** (1) Hands never leave the keyboard → flow; mouse is a context switch. GUI apps with keybinds still have mouse as the primary paradigm, which breaks the discipline. (2) **Same workflow on phone and laptop** via tmux (later Herder) session attach. He says if you hate the terminal, the *concepts* still apply to GUI workflows.

**Stack he actually uses:** WezTerm (cross-platform including Windows, Lua config, hot reload, rose-pine moon, Hack Nerd Font), tmux then **Herder**, Neovim (leader space, relative numbers, Snacks picker, Oil as editable filesystem buffer, which-key, ESC saves, paste-register fix). He cares about the environment being **pleasant** because he will stay focused longer.

**ADE — Nix as disaster recovery for agentic work.** The first problem on a fresh Mac Mini is reproducibility: apply this setup to another machine, **or recover instantly after an agent destroys the system**. Determinate Nix → nix-darwin (Mac settings as code: dark mode, key repeat, hidden dock/desktop, Finder list view, tap-to-click) → nix-homebrew with `cleanup = zap` (undeclared Homebrew packages get removed — forces every app through the flake) → home-manager (user packages, fonts, env, symlink configs). Pin nixpkgs, do not float on unstable. `rebuild.sh` after every change. Stable symlink at a fixed home path so scripts find the clone. End state: clone dotfiles on a fresh Mac, rebuild, get the whole agentic environment. Global AGENTS.md is part of that rebuild.

This is not “Nix because reproducible builds.” It is **the agent is an untrusted co-resident on the machine**, so the machine definition must be a git checkout.

### The token game (the talk that is not a workflow)

**TG** is the load-bearing philosophy piece, and it is **anti-token-max**, not pro-cheap-model.

**The food chain.** User → frontier lab (OpenAI/Anthropic) → hyperscaler (Azure/AWS/GCP) → chip vendor. Google is the only one that spans the chain. Chip vendors have the cleanest model (POs in, money in). Hyperscalers only recoup GPUs if someone consumes compute.

**Circular capital.** Microsoft “invests” ~$13B in OpenAI, mostly **Azure credits**; OpenAI spends them back on Azure; Microsoft records **revenue**. OpenAI then copies the playbook: ~$2M in **token credits** to every current YC company. Same loop among AWS/Google/Microsoft and Anthropic (Anthropic committed to ~$30B Azure capacity in the partnership he cites). Sequoia tells people to token-max and also holds Anthropic, Nvidia, OpenAI. The whole chain is happy iff **someone keeps paying for more tokens**.

**Two different prices.** Frontier labs’ own employees token-max and go on podcasts. Startups/individuals token-max because **$200/mo subscriptions are heavily subsidized** — thousands of dollars of tokens for a fixed price, so after a point there is “no reason not to keep burning until the limit.” He says the labs are not losing-money-by-accident: the subsidy is the **marketing campaign**. If Anthropic/OpenAI tell enterprises to burn tokens, they look like salesmen. If fast startups tell the same story, it creates **FOMO**.

**Enterprises are the only ones paying the real bill.** Uber-class customers do not get the $200 plan; they get **API list price, an order of magnitude more**. Individual Max users and the labs’ own usage do not fund the chain. Enterprise token-max does.

**Advice to enterprise leaders (this is the part that maps onto Baton):**
- Do **not** build a token-usage leaderboard. Leaderboards reward outliers who game the metric. Token count is **not a productivity metric**.
- Jellyfish study, 7,000+ engineers: the developers who spend the most tokens produce **roughly 2× output at 10× cost**. They burn because it is free to them and it looks cool.
- Measure **adoption buckets** over time: not using / occasional / regular / primary way of work.
- Measure **business outcomes**: teams hitting OKRs early, exceeding targets, setting goals you previously could not imagine — then look at which usage *patterns* correlate.
- **Generous but not unlimited quotas.** The cap is what makes power users look for efficiency, not just more spend.
- Do not “AI layoff” your way to startup speed. Invest in people who already know the business. Train the not-yet-regular users with people who have figured it out. For people already AI-native, **remove the org roadblocks** (ownership boundaries, politics, quarterly planning, cross-team dependencies, stakeholder sign-off). Until those come down, “no amount of tokens” gets you to startup speed.

**Advice to ICs:**
- If you have not adopted, you still need to learn the tool (learning-curve analogy: hand workshop vs steam; arithmetic vs spreadsheets). Even a bubble leaves the capability in place, like the internet after dotcom.
- If you already use it heavily: **do not use tokens as the success metric.** You will ship slop PRs your peers hate, and you will misalign with leaders who care about business success and cost efficiency.
- Instead: **success stories** that translate AI into outcomes — team hits the goal early, everyone around you gets more efficient, the scary tech-debt project finally moves. Leaders who started spending on AI will look for those stories.
- If the org is the bottleneck, escalate: your velocity is outpacing the surrounding process.

He is, in other words, running a **subsidized-subscription factory** in HT (burn remaining Fable because it is already paid) while **telling enterprises not to copy that**. Those two talks are consistent only if you keep the price regime in view.

### Captain habits that are not tools

- **Don’t watch the middle.** Calm mode, no-mistakes babysitting, firstmate retries, gnhf while asleep.
- **Keep the orchestrator idle-capable.** Firstmate is not labor. Second mates exist so firstmate can still talk.
- **Queue decisions; don’t lose them.** Bearings / captain’s calls. 36 projects generate more undecided discussions than a human inbox can hold.
- **Catch up on purpose.** Ahoy, because chat is a lossy log.
- **Fun / second monitor.** Fly-with-me is a procedural bird-flight toy he leaves on a second monitor with sound off, as a relax-while-coding artifact. Not a productivity system; it is how he stays in the chair. He still runs it through the same factory (Fable prototypes, yolo merge).
- **Community as inbound.** Discord (~2k people) bug-report channel is a work queue, relayed into firstmate. He treats community reports like GitHub issues: funnel, don’t tab-hop.
- **Ship 40–50 PRs/day** is the June claim; September is 7–10 concurrent crewmates in one sitting without “going insane.” The method is the same: parallel labor, serial captain decisions, gated merge by stake.

### Link index (what he points people at)

From `Kun-ChenLinks.txt`: `github.com/kunchenguid/dotfiles`, `https://axi.md/`, the four videos above, `https://blog.kunchenguid.com/`. AE also names WezTerm, tmux, Neovim, `npx skills`, Open Super Whisper, AXI, lavish, no-mistakes, gnhf, treehouse, firstmate.

---

## Impact on Baton's tech stack

Existing verdicts (from the condensed context / `00-DECISION`): KEEP-BUILD learned local-fleet router + Governor + Grimdex + `baton go`; ADD Archon, Ringer, no-mistakes, projectmem, Presidio; Herdr `agent` API already replaces Baton’s crew-dispatch; firstmate adopted at the **seam** (Baton-core sits in front of spawn, pre-resolves harness/model/effort; do not reimplement firstmate’s watcher or no-mistakes’ pipeline); quota-axi for **cloud seats only**, overlay local scores (do not adopt `spendPriority` as the whole ranker); gnhf = sibling overnight loop, no PR; KunAgent Electron app SKIP; pin SHAs / vendor `bin/`; telemetry off.

What the transcripts add — **new, confirm, refine**. Nothing here is a “throw out the 2026-09-08 stack” event.

### Confirm (talks agree with the already-written verdicts)

1. **quota-axi is a probe, not a router.** HT is the demo of the existing finding: firstmate calls quota-axi, then picks among an already-filtered candidate set by **remaining quota**. He never claims quota-axi knows what is *good*. The “overlay local scores” decision is exactly right; the talks give the *why* (subscription forfeiture on Max-class plans). Adopting `spendPriority` as-is would still route as if the 4090/5090 do not exist — he never mentions them.

2. **Governor still has a job quota-axi will not do.** AE’s whole pitch for gnhf vs `/goal` is **caps** so an overnight loop cannot eat the weekly window. TG’s enterprise advice is “generous but not unlimited.” HT’s “waste a little context” is *not* “unlimited Opus.” Baton’s hard-cap Governor is the piece Kun does not ship and still implies.

3. **Do not reimplement no-mistakes or firstmate’s watcher.** HT’s GitHub-500 retry, PR babysitting, and “I didn’t look at the crewmate” are the watcher. AE’s intent→rebase→fresh-context adversarial review→E2E evidence→docs→lint→PR is the pipeline. Both talks argue these exist so the **human does not stare**. Rebuilding them in pwsh would be repeating the thing he already extracted.

4. **Herdr as substrate.** ADE is the conversion story (tmux → Herder because it understands agents). HT is Herder as the multi-machine session fabric (MacBook captain + headless Mini labor). KEEP Herdr is confirmed as the *actual* Kun path as of July–September 2026, not a Baton idiosyncrasy.

5. **gnhf stays a sibling, not the PR factory.** AE: wake to a branch + commits, **you** decide what to keep. Matches the existing “opens no PR, push it through the gate yourself.”

6. **Pin / don’t `go install` and pray.** Not from a README this time: AE’s skill lecture (177k-star skill that made Program Bench *worse*) is the same epistemic rule as “firstmate is a 3-month-old workflow religion.” Popularity is not evaluation. Pin SHAs.

7. **Human at start and end, process in the middle.** Directly supports Ringer (cheap parallel checkers, exit-0 = truth) *then* no-mistakes (branch gate) *then* frontier review on load-bearing diffs. Kun’s “risk assessment decides whether I open the diff” is the same seating as Baton’s “Ringer feeds the router; premium review is not the default.”

### Refine (keep the decision, change the shape)

1. **Learned router: add a capability-class key before “cheapest that scores well enough.”**  
   KEEP-BUILD the router. Do **not** replace it with Kun’s JSON. But HT shows his real ranker is **not** a global cheapest-model sort. It is `task class → allowed {harness, model, effort}[] → max remaining quota among those`. Baton’s current one-dimensional “cheapest model that scores well enough” will mis-seat work that is:
   - **tool-surface bound** (Codex because of native image gen, not because GPT won a coding eval),
   - **taste/product bound** (Fable always on the paid iOS app),
   - **ambiguity bound** (hard planning gets Fable/Kimi/Astra, not Luna).
   Concrete refine: the router’s unit of learning should be **(task class × worker)**, with classes at least as coarse as his table (UI/paid-surface, image/native-tool, hard-plan/architecture, well-defined bugfix, default). Global Elo-across-all-tasks will wash out the thing he is actually optimizing.

2. **quota-axi overlay is the *tie-break among cloud seats in a class*, not the first sort.**  
   Existing text says “call quota-axi for cloud seats, then overlay measured local scores.” HT says the order is **class first, quota second**. If Baton overlays quota *before* class, leftover Opus will eat well-defined bugfixes that Luna/local would have taken. If it overlays *after* class, leftover Opus correctly wins **inside** the hard-planning set, which is the “why not, we have Fable” move. Write that order down: `class → (local scores if a local passes the class bar) → else cloud candidates in class by remaining quota / Governor`.

3. **no-mistakes is not an always-on pre-merge gate.**  
   Existing ADD treats it as *the* pre-merge gate. HT meters it with a **per-project policy** (`data/projects.md`: no-mistakes / direct-PR / yolo) plus the “would you have asked a human reviewer?” heuristic. Baton already has a hard merge gate on its own repo; that can stay. For the factory that runs Kevin’s *other* projects, copying always-on no-mistakes would spend the exact resource Kun says not to (tokens + time) on toys and on changes that still get a human release test. Refine: **policy bit per project**, default on for anything that auto-releases or that he would have peer-reviewed; yolo or skip for sandboxes; Ringer can still run cheaply on everything.

4. **Pi’s seating is stronger in the talks than in the leftover-Pi verdict.**  
   `00-DECISION` / grok-G: Pi CLI = optional ADD as the *local-small-model* worker if OpenCode’s tool surface fails 7–32B jobs. **HT (Sept 13):** Pi is his **default captain harness** and the switcher for every non-Anthropic model; Claude Code is the Anthropic-only door. That does not force “make Pi the Baton OS.” It does mean: if firstmate is adopted as the liaison, **Pi is how Kun actually runs firstmate day-to-day in the later talk**, with Claude Code as a crewmate harness. Revisit the “Pi is a 7th cloud harness / skip” framing for the *liaison* seat, not for labor. Labor stays multi-harness (already required).

5. **Second mates are the missing scale-out, and they interact with Herdr-across-machines.**  
   Existing firstmate verdict covers spawn/supervise/PR. HT adds **domain-scoped recursive firstmates** plus **headless Mini as the labor host**. Baton’s “one Herdr workspace per worker” is the crewmate layer. It does not yet say who owns Ship vs AXI vs “default” when the liaison saturates. Refine the seam: Baton-core still pre-resolves model/harness **per task**; firstmate (or a thin Baton equivalent) may need **domain owners** so the captain session stays interruptible. The Mini-as-labor-box pattern matches Kevin’s actual hardware (Mac Mini + GPU boxes over Tailscale) better than “all workers on the laptop.”

6. **Context-window micro-optimization should not be a Baton-core feature.**  
   HT: set a **constant auto-compact threshold** (he uses **500k** even though Claude Code’s default is 1M — `CLAUDE_CODE_AUTO_COMPACT_WINDOW` in his dotfiles) and then **stop thinking about it**. Tools will catch up. Spending captain (or orchestrator-designer) attention here is the wrong scarcity. Baton’s efficiency officer / token-saver skills are fine as *automatic* context select; they should not become another dashboard the human tends. Confirm Governor windows; do not build a compaction cockpit.

7. **Global memory content, not just the file.**  
   Grimdex remains the decision ledger (KEEP-BUILD; Kun has no equivalent). What the talks add is a **tiny always-on pref list** that is not a decision record: development-cost bias correction, E2E-first bugfixes, no em-dash, no agent co-author, pixel pickiness, fix unrelated red CI. That belongs in Baton’s own global AGENTS.md (or the Home Manager equivalent), **not** in Grimdex and **not** in a 76k firstmate prompt. projectmem still covers “this fix already failed”; Kun’s project AGENTS.md covers “this crewmate was wrong, remember the convention.” Complementary.

8. **AXI-shaped tools are in scope; GitHub MCP is a known footgun.**  
   Token tracking already seats quota-axi as the machine probe. AE’s GitHub MCP vs `gh` result should change **tool seating**: prefer `gh` / gh-axi over GitHub MCP in worker prompts; prefer TOON/compact agent output on anything Baton writes for agents (`fleet doctor`, usage probe, bearings-equivalents). This is not a new product. It is a constraint on Baton’s own CLIs and on what gets installed into workers.

9. **Lead-orchestrator fork (QUEUE #1) gets a data point, not a resolution.**  
   HT’s captain session is Grok 4.5 in Pi; Anthropic models are crewmates via Claude Code. That **rhymes** with “Grok Build lead, Opus consultant” but the reason is **Pi’s model switcher + he likes 4.5’s manner**, not headless-Groks-as-OS. It does not settle the Claude-Code-lead vs Grok-lead fork. It does argue: the **liaison** should be the harness that can see every model, and the **premium Anthropic** path should stay a crewmate door. Do not collapse to one harness (already required).

### Change (small; the talks actually move a prior item)

1. **Lavish / interactive decision artifacts were not in the KEEP/ADD list.** They should not become a Baton product (that would violate “no new UI until the router ships one PR”). They **should** be an allowed **captain interface** on top of firstmate for planning and variant-picking, and a **pattern** for Baton’s own “PARKED-ON-HUMAN / captain’s calls” surface. The GitHub Projects table remains system of record; a wall of markdown in the liaison session is the thing Kun explicitly abandoned. If firstmate is adopted, lavish-axi is part of *that* workflow, not a second dashboard app.

2. **Backpass is a new Kun tool the 2026-09-08 inventory did not sit.** Session-log → AGENTS.md proposals, including a planned multi-machine session collector. Closest Baton piece is `/learn` + projectmem, not Grimdex. **Do not add it to the stack this cycle** (adoption-mania risk is already written). Flag as a later sibling if Baton’s own session corpus is large enough to mine. Do not build a second one in pwsh.

3. **Nothing in the talks revives KunAgent/Electron, gastown-as-OS, or “always cheapest model.”** Skip those stays skip. The “cheapest model” characterization should be **retired as a description of Kun**; it was never his stated rule in these four files.

### If nothing else: the overlay decision is the whole routing merge

The transcripts do **not** argue for replacing the learned router with quota-axi. They argue that on **fixed-price cloud seats**, remaining quota is the right tie-break **inside a capability class**, and that **human attention** is the thing both the router and the Governor are in service of. Baton’s differentiator remains: **locals exist, quality is measured, API/local price regimes differ.** Kun never solves that because he is not running that fleet.

---

## What's adoptable piecemeal

Do **not** adopt wholesale: “burn whatever Max quota is highest,” “one 76k-char AGENTS.md is the orchestrator,” “Nix-darwin as a Baton dependency,” “never look at a diff,” “Pi is the OS,” “token usage is the enemy / is the goal.” His personal factory is a subsidized-subscription, taste-driven, single-human shop.

Steal these pieces anyway:

1. **Capability-class dispatch table** (even if scores fill the cells). Minimum classes from HT: UI/paid-surface, native-image/tool-surface, hard-plan, well-defined-bugfix, default. Human can pin a class (“this iOS app is always Fable”). Router learns inside the class.

2. **Quota as tie-break among already-qualified cloud seats.** Wire quota-axi *after* class + local-bar, not as the ranker. This is how you spend leftover Opus on planning without letting leftover Opus steal bugfixes from a local that already passed.

3. **Per-project gate policy + the human-reviewer heuristic.** `no-mistakes | direct-PR | yolo`, keyed on blast radius and whether a release still has a human in it. Do not run the expensive adversarial pipeline on Fly-with-me-class repos.

4. **Liaison is not labor.** Whatever sits in front of spawn (firstmate or `baton go`’s conductor) must stay interruptible. If it saturates, **domain second mates** (or equivalent Herdr workspaces that own a project) — do not make the captain session the implementer.

5. **Hide the middle; instrument the ends.** Calm-mode equivalent: workers do not stream tool calls at the captain by default. Human artifacts are: plan/prototype (Lavish or equivalent), bearings (what is open / what needs a decision), ahoy (what did I miss), no-mistakes risk+evidence (whether to open the diff). Baton’s PARKED-ON-HUMAN column is the bearings “captain’s calls” list. Build that, not a live token ticker, as the human HUD.

6. **Steer vs follow-up.** If the liaison harness supports queued follow-ups, use them so a bearings dump cannot preempt an in-flight dispatch. If it does not, do not interrupt; wait. This is cheaper than a second orchestrator.

7. **500k auto-compact, then ignore.** Set Claude Code’s auto-compact window (and equivalent on other harnesses) to a constant; do not build compaction policy into Baton-core.

8. **Tiny global prefs, fat project memory grown from corrections.** ~30 lines global (dev-cost bias, E2E-first, no co-author, pixel bar, fix the red CI you walked past). Project AGENTS.md is the append-only “you got this wrong, don’t again.” Extract conditionals into skills. **Ban un-evaluated public skills** in the factory path — the 177k-star counterexample is the rule.

9. **AXI constraints on Baton’s own agent-facing CLIs.** Compact/TOON for probes; `gh` not GitHub MCP; tools designed for the agent as the primary user. quota-axi already; extend the attitude to `fleet doctor`, usage, bearings dumps.

10. **gnhf-style overnight = verifiable objective + hard caps.** Steal the loop semantics into `baton go --overnight` (already the lean): token cap, iteration cap, stop condition. Do not use `/goal` as the overnight. Do not auto-PR from the overnight; wake to a branch and notes, then the daytime gate.

11. **Treehouse pooling as already decided** — talks only add *why*: raw worktrees become mental debt. Closing the tab must return the lease. No change to ADD.

12. **Headless labor box.** Captain session on the laptop; Mini (and GPU boxes) as Herdr remotes for second mates / workers. Matches Kevin’s seating better than running 10 crewmates on the MacBook. Not a new product.

13. **Voice + a proper-noun prompt for Whisper** if Kevin actually talks to the liaison. Not load-bearing for the router.

14. **Relay later, not now.** Discord/X → one liaison session is how he absorbs inbound without tab-hopping. Baton’s inbound is GitHub issues. Do not build a Discord bot this cycle; do treat “one session holds intent” as the UX invariant when wiring `baton go` to firstmate.

15. **Risk field as attention allocator.** Whatever no-mistakes (or Ringer+review) emits, the human default on `low` is **do not open the diff**. That is the only way 40–50 PRs/day is not a fantasy. Baton’s hard merge gate on *Baton itself* can still demand more.

16. **Nix/dotfiles as personal disaster recovery, not a Baton dependency.** ADE’s “agent destroyed my machine” story is real; it is Kevin’s box, not the orchestrator’s job. Optional pointer, not ADD.

---

## The core tension

Kevin’s framing: the high-throughput talk *is* a lot of what Baton is meant to be, except Kun optimizes for lowest-token models and Kevin wants Baton “smarter,” via a learned router.

**The framing needs a correction before the opinion, because it is the wrong axis.** In these four talks Kun does **not** optimize for the cheapest model. He optimizes for **captain attention**. Model seating is (1) taste/capability class, (2) **don’t leave paid subscription on the table**, (3) human override. The Token Game talk is actively hostile to token-max as a success metric, and cites 2× output at 10× cost. The “why not Fable, we have quota” move in HT is the **$200/mo subsidy talking**. It is the behavior TG tells **enterprises** not to copy.

So the real tension is:

> Kun’s factory: **capability class + burn the Max quota you already bought**, because tokens on that plan are a sinking, resetting allowance and the human is the bottleneck.  
> Baton’s factory: **capability class + cheapest worker that has been measured to be good enough**, because the fleet includes **local GPUs and API-priced seats**, and leftover Opus is not free in every price regime.

Those are compatible if you keep the price regime in the ranker. They fight if you flatten either one into a slogan.

### Where Kun actually beats a learned-router (even a good one)

**1. Subscription forfeiture is the correct sort for Max-class cloud seats.**  
A learned quality-per-API-dollar router will *underuse* a Claude Max / Codex / Grok plan that is about to reset. On that plan the marginal dollar is ~0 until the window is empty, then it is infinite (or you wait). quota-axi’s remaining-quota pick is the right micro-optimizer **inside a class** for that regime. Baton has to keep that overlay or it will “smartly” sit on paid Opus while a local does planning the human did not want a local to do — or the opposite, spend API dollars while Max sits unused. Kun wins this on day one with a JSON file and a probe. The learned router wins it only after someone encodes the price regime (sunk subscription vs API vs electricity).

**2. Tool-surface and taste are not in the eval set.**  
Codex-for-images is not a quality score. Fable-for-the-paid-iOS-app is a product decision. A router that only scores “coding task pass rate” will keep getting those wrong until the feature space includes **native tools** and **per-project pins**. Kun just writes the pin. That is smarter, today, than a half-built Firefly loop.

**3. Operational completeness now vs. the thing that made Baton unfinishable.**  
HT is a working 36-project, 7–10 concurrent crewmate loop. The learned router is the differentiator **and** the unfinished core. Kun’s static table plus “I felt 4.5 was better than 4.6” ships. A router that does not yet have class-level scores will lose to that on actual throughput. This is the honest cost of “smarter”: until the scorecards exist, Kun’s vibes+quota factory produces more PRs.

**4. Attention-aware waste is a feature.**  
He will not compact at 40%, will not watch tool calls, will not no-mistakes a toy bird. A naive “smart/cheap” system that also tries to be token-tight will **spend Kevin** on the wrong scarcity — the exact failure HT warns about. Baton’s efficiency officer should be automatic or absent, not another captain job. Kun is clearer on this than most orchestrator designs, including Baton’s temptation to meter everything.

**5. The liaison pattern (one interruptible brain, recursive domain owners, inbound relay) is a better human-systems design than “N Herdr workspaces the human tabs between.”**  
That is independent of model intelligence. Baton can lose the plot by building a brilliant router that still makes Kevin play whack-a-mole. Firstmate+second-mates+ahoy+bearings is the answer to *that* problem. Adopt the seam; do not re-derive it.

### Where Baton is clearly better once built

**1. Locals exist. Kun’s dispatch table is blind to them.**  
This is the whole product. A well-defined bugfix that Luna-or-Sonnet would take in his JSON should, on Kevin’s fleet, often be a **measured local**. That is cheaper in the TG sense (real resources: electricity, not a marketing subsidy) and it **saves the Max window for the classes that actually need Fable/Opus**. Kun cannot do this without the score overlay because he has no local quality signal. The 2026-09-08 overlay decision is the correct merge: quota-axi for cloud seats, local scores as a first-class competitor **inside the classes locals can pass**.

**2. “Don’t assume the new model is better” is an eval slogan. Kun executes it as vibes.**  
Grok 4.5 vs 4.6 is exactly the case a learned router is for. He sat with it and preferred 4.5. That does not scale across 22 Herdr kinds, two GPU boxes, and next month’s checkpoint. Baton’s Firefly/wraith2 scores are how you **institutionalize** the thing he is doing by hand, and how you notice when a local 32B starts passing the well-defined-bugfix class. Once that loop runs, it is strictly more “Kun than Kun”: same skepticism toward new-and-shiny, but written down and rerun.

**3. API and enterprise-shaped spend need TG’s advice, not HT’s leftover-Fable habit.**  
When the seat is OpenRouter list price, or a hard Governor window, “we have quota, why not Fable” is the Jellyfish 2×-at-10× trap. Kun the YouTuber can do it because $200/mo is a marketing subsidy (he explains this himself in TG). Baton is being built as a **fleet with a Governor**. On that object, quality-per-dollar-with-a-good-enough bar is the right objective, and leftover-premium-burn is the thing to *prevent* except as an explicit “window is resetting, dump remaining into planning/UI.” The learned router + Governor can encode that; quota-max cannot.

**4. Repeatability without Kun.**  
`crew-dispatch.json` is his taste. Baton’s reason to exist is that the next model, the next box, and the next week’s Kevin should not require re-deriving seating from a video. Grimdex + measured scores + a class table is the durable version of “I like Fable for UI.” The talks are the bootstrap of the class table, not a substitute for learning.

**5. Verification that feeds the router.**  
He uses no-mistakes evidence to decide whether to look. He does not close the loop into *who gets the next task*. Ringer’s pass rates into Baton’s router is the piece his factory is missing: a Fable crewmate that keeps failing E2E should lose the UI class; a local that keeps passing well-defined bugfixes should win them. Kun’s process stops at “this PR is low risk.” Baton’s process can change tomorrow’s seating. That is the actual “smarter.”

**6. TG’s own enterprise advice *is* Baton’s philosophy.**  
Adoption buckets, outcomes not token leaderboards, generous-but-capped quota, don’t fire people to buy tokens, remove org/process blockers. A learned router with a Governor is how an individual shop follows the advice Kun gives companies, instead of the practice he uses on subsidized seats. If Kevin wants Baton to be smarter rather than cheaper, this is the clean version: **smarter = measured good-enough, including locals, with premium reserved for classes that fail the bar — not more tokens, not always-Opus, not always-Luna.**

### Opinion, sharp

Kun’s high-throughput system is the **right human-systems architecture** (one liaison, domain deputies, hidden middles, visual decisions, risk-metered gates, quota as a cloud tie-break). It is the **wrong model-economics architecture** for a fleet that includes local GPUs and real API prices. Kevin’s instinct (“that talk is Baton, except I want smarter”) is right if “smarter” means **class-aware measured routing + Governor**, and wrong if “smarter” means **always a frontier model**. The talks actually warn *against* the second reading: he already uses Luna/Sonnet for well-defined bugfixes, already says new Grok is not automatically better, already tells enterprises that token-max is a trap.

The failure mode to avoid is **either slogan**:
- Copy HT’s leftover-Fable burn and you are token-maxing with extra steps, locals idle, Governor as theater.
- Copy a global cheapest-model router and you will put a 7B on hard planning, skip Codex when the task is an image, and leave paid Opus on the table the day the window resets.

The already-written seam is the resolution, with one sentence the transcripts add: **class first, local bar if it exists, remaining cloud quota among the rest, human pin when taste matters, expensive gates only when you would have asked a human.** That is Kun’s factory with Baton’s differentiator installed at the one place he is blind: the local fleet, and the difference between a subsidized Max seat and a dollar.

Do not adopt his religion. Adopt his scarcity (attention), his class table, his gate metering, and his refusal to watch the middle. Keep the router. Teach it his classes. Let quota-axi speak only after that.
)