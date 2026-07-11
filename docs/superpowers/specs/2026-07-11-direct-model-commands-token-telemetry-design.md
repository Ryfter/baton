# Direct model commands + per-model token telemetry — design

**Date:** 2026-07-11 · **Status:** SPEC — authored async (Kevin away); build gated on his
review + the batched decisions in §7 · **Track:** multi-model conductor · **Priority:**
#2 in Kevin's 2026-07-11 order (after Verified Labor V2 shipped, before Copilot budget d079)
· **Inspiration:** Kevin's "/codex inside Claude Code" want + github.com/dysfunc/ai-plugins-cc
(Apache 2.0) + Ringer's per-engine token-usage regex

## 1. Problem

Two gaps, both raised by Kevin 2026-07-10:

**(a) No direct line to one fleet model.** Talking to a specific instrument from inside
Claude Code means prose-routing through the conductor or dropping to a raw terminal. Kevin
wants `/codex "<prompt>"`, `/grok "<prompt>"`, `/gemini` (or `/agy`) — type it, the CLI
runs, the answer comes back, and — unlike installing ai-plugins-cc as-is — the call is
**journaled and Usage-Governor-metered** through Baton's already-hardened dispatch (the
stdin / `{{prompt_file}}` per-provider quirk handling). Installing ai-plugins-cc directly
would create a second, unjournaled dispatch path — the exact thing we don't want.

**(b) The journal counts calls, not tokens.** `Write-FleetJournalLine` records
`provider · duration · exit · prompt-summary · host [· job · phase]` but **not tokens**.
So the Usage Governor forecasts on call-count, and realized token cost is metered for
Claude only (CostResolver). Capturing per-model tokens is the missing input for
consumption-based forecasting and realized effective-cost.

## 2. Architecture

Three thin additions, no new subsystem. One shared runner backs the commands; the token
capture is an additive field on the existing dispatch path. Observe-only for tokens this
slice — no Governor/cost wiring yet (same observe-first discipline as d078 / Verified Labor).

```
/baton:codex "<p>"  ─┐
/baton:grok  "<p>"  ─┼─► scripts/fleet-ask.ps1 <provider> <prompt>
/baton:gemini "<p>" ─┘        │
                              ├─► Invoke-Fleet -Name <provider> -Prompt <p>   (existing, hardened)
                              │        └─► Invoke-Fleet-Cli → +tokens,+tokens_basis   (NEW: §4)
                              │        └─► Write-FleetJournalLine → +" | tok:N(basis)"  (NEW: §4)
                              └─► prints model stdout + footer: "provider · Ns · exit · tok:N(basis)"
```

## 3. Commands + shared runner

### 3.1 `scripts/fleet-ask.ps1` (new — the one shared runner)

`fleet-ask.ps1 -Provider <name> [-Prompt <inline>] [-PromptFile <path>] [-TimeoutS 120]`

- Resolves `$BATON_HOME/fleet.yaml`, finds the row, **errors politely on unknown or
  disabled provider** (`[Console]::Error.WriteLine("provider '<n>' disabled in fleet.yaml")`
  + `exit 2`).
- Reads the prompt from `-PromptFile` when given (the 965-byte escape hatch — the command
  doc writes long `$ARGUMENTS` to a temp file), else `-Prompt` inline.
- Calls `Invoke-Fleet -Name <provider> -Prompt <p>` (reuses stdin / `{{prompt_file}}`
  transport selection per provider — no new dispatch logic).
- Prints the model's stdout verbatim, then one footer line:
  `— <provider> · <duration>s · exit:<code> · tok:<n>(<exact|est>)`.
- Exit code = the provider's exit code (so a failed model call surfaces as a failed command).

### 3.2 Command docs

Three thin delegators. **Namespacing is the one open decision — see §7 fork A.** The
recommended default is plugin-namespaced `commands/{codex,grok,gemini}.md` →
`/baton:codex` etc., because they then ship + version + bootstrap-deploy with Baton and
inherit the deploy-assert safety net. Each doc: writes `$ARGUMENTS` to a temp file when
long, invokes `fleet-ask.ps1`, respects the 965-byte rule. `gemini` maps to the
`gemini-antigravity` (agy) row; a `commands/agy.md` alias delegates to the same runner.

## 3.3 Model tier + thinking-effort selection (Kevin 2026-07-11)

Kevin wants to pick a provider's model **and** thinking-effort the way he picks
Fable/Opus/Sonnet/Haiku on Claude — e.g. Codex `5.6 | Sol / Tera / Luna` at a chosen
effort. This is the concrete realization of "effort as an unmodeled routing dimension"
(`reference_aa_coding_index_effort_curves.md`: Luna-high dominated score-per-cost) and it
enables **testing the boundaries** of each new model — run the same task across tiers and
watch the score/cost curve.

**Ground truth (probed 2026-07-11):**
- `codex exec` — `-m/--model <MODEL>`; effort via `-c model_reasoning_effort=<low|medium|high>`
  (a config override, not a flag); `--profile` layers a config profile. Live default seen:
  `gpt-5.6-sol`.
- `grok` — `-m/--model <MODEL>` **and** first-class `--reasoning-effort`/`--effort <EFFORT>`;
  `grok models` lists available.

**Existing plumbing to build on:** `Resolve-FleetCommand` already substitutes `{{model}}`
from `-Model` / `$Provider.model_default` (fleet-lib.ps1:161-182, mirrored on the stdin +
prompt-file branches). So model selection is 80% wired; tiers add friendly naming + effort.

**Design — per-provider `tiers` map + `{{tier_args}}` template token.** Keep the
provider-specific flag *syntax* in config (codex's `-c …` vs grok's `--effort`), not in code:

```yaml
- name: codex
  command_template: 'codex exec {{tier_args}} --sandbox workspace-write -'
  default_tier: sol
  tiers:
    sol:  '-m gpt-5.6-sol'
    tera: '-m gpt-5.6-tera -c model_reasoning_effort=high'
    luna: '-m gpt-5.6-luna -c model_reasoning_effort=high'
- name: grok-cli
  default_tier: fast
  tiers:
    fast:  '-m grok-4-fast'
    heavy: '-m grok-4 --effort high'
```

- `Resolve-FleetCommand` (+ the stdin/prompt-file branches) gain a `{{tier_args}}`
  substitution: `Invoke-Fleet -Name codex -Tier luna` looks up `tiers.luna` and injects its
  argv; omitted `-Tier` uses `default_tier`; a template without `{{tier_args}}` is unchanged
  (backward compatible). Commands expose `--tier <name>`: `/baton:codex --tier luna "<p>"`.
- **Safety:** tier argv are **trusted, box-private** config tokens (Kevin authors them), and
  they are plain flag tokens (no quotes / shell operators) → they tokenize cleanly under the
  existing clean-token-list predicate that already gates the stdin path. Real
  model/tier names stay in the live `~/.baton/fleet.yaml`; the shared seed carries commented
  **placeholder** tier names only (box-private rule).
- **Unknown tier** → `[Console]::Error.WriteLine("unknown tier '<t>' for provider '<p>' — valid: <list>")` + exit 2.
- The journal line + footer already carry the resolved model via `{{model}}`; add the tier
  name so a run records *which tier did the work* (needed for the boundary-testing curve).

**Boundary-testing helper (small, optional):** a `--tier all` mode on the runner dispatches
the same prompt across every configured tier and prints a compact table
(`tier · model · duration · tokens · exit`) — the cheap way to eyeball a model's score/cost
frontier. This is the observe-only seed for later tier-aware routing (a named follow-up, not
this slice).

## 4. Token telemetry

### 4.1 New optional `fleet.yaml` row field

```yaml
token_usage: 'tokens used[:\s]+([\d,]+)'   # CLI rows: ONE capture group over stdout
```

- **CLI rows with the field:** after dispatch, match stdout → `tokens = <captured, commas
  stripped>`, `tokens_basis = 'exact'`.
- **No field / no match:** `tokens = [math]::Ceiling((len(prompt)+len(stdout))/4)`,
  `tokens_basis = 'estimate'` — the d059 honesty rule: never present an estimate as
  metered.
- **HTTP hatches** (ollama, LM Studio): read native counts
  (`prompt_eval_count`+`eval_count`, or OpenAI `usage.total_tokens`) → `exact`.

### 4.2 Return shape + journal (both additive)

- `Invoke-Fleet-Cli` return hashtable gains `tokens` (int) + `tokens_basis` (string). The
  HTTP path gains the same two keys. `Invoke-Fleet` threads them to the return + the
  journal writer.
- `Write-FleetJournalLine` gains a `[int]$Tokens = 0` + `[string]$TokensBasis = 'estimate'`
  param and **appends `| tok:<n>(<e|est>)` at the very end of the line** — after
  `host:`/`job:`/`phase:`. Append-at-end is deliberate: existing parsers split on ` | `
  and match by prefix, so a new trailing field is ignored by every current consumer
  (verified: §6 lists the consumers to confirm before landing).

### 4.3 Seed rows

- **codex:** gets the regex above (live-verified trailer `tokens used\n14,350`) → exact.
- **claude rows:** `--output-format json` gives exact usage but changes stdout shape →
  **deferred** (a follow-up), estimate fallback until then.
- **grok / agy:** estimate fallback, documented. (grok row disabled 2026-07-15 anyway —
  [[project-grok-availability]].)

## 5. Scope

**In:** the three commands + shared runner; **model-tier + effort selection** (`tiers`
map + `{{tier_args}}` + `--tier`, plus the `--tier all` boundary-testing table); token
capture field + exact/estimate basis; journal + return-shape threading (model **and** tier
recorded); bootstrap deploy-asserts for the new runner + command docs; command-doc +
AGENTS.md line; plugin minor bump.

**Out (named follow-ups, not this slice):**
- Governor tick using tokens instead of call-count budgets.
- Effective-cost realized-token costing.
- Interactive TUI sessions inside the CC REPL (impossible in the REPL; ai-plugins-cc has
  the same limit — one-shot headless only).
- `/ai:compare` fan-out — already exists as `/baton:research` ensemble.
- Vendoring ai-plugins-cc code (different runtime; we reuse the *shape* only).

## 6. Tests (hermetic — temp fleet.yaml + temp BATON_HOME + try/finally; never touch real
`~/.baton`/`~/.claude`/`D:\Dev\Grimdex`/`D:\dev`)

- Fixture provider with a fake token trailer → **exact** capture, commas stripped.
- No-trailer provider → **estimate** + basis flag; guard the `len/4` divide.
- Journal line format assert: new `tok:` field present, appended at end, old fields intact.
- **Consumer-safety check:** grep the repo for parsers of the fleet journal line
  (test-hook / OTel / any `-split ' | '`) and assert the new trailing field breaks none.
- `fleet-ask.ps1` child-process smoke against a stub provider; disabled-provider →
  stderr + exit 2.
- Bootstrap deploy-asserts: `fleet-ask.ps1` + the command docs land in `~/.claude`
  (the v1.8.0 coach-lib omission lesson).

## 7. Open decisions — batched for Kevin

**Fork A — command namespace (the one real fork).** Kevin's literal want was bare
`/codex`, `/grok`, `/gemini`. Two ways:
- **A1 (recommended): plugin-namespaced `/baton:codex`.** Ships/versions/deploys with
  Baton; inherits the bootstrap deploy-assert; discoverable under `/baton:*`. Cost: the
  `baton:` prefix — not the bare `/codex` Kevin typed.
- **A2: user-level un-namespaced `/codex`.** Exactly what Kevin asked to type. Cost:
  user commands live in `~/.claude/commands/` — bootstrap *can* deploy there, but they're
  not plugin-scoped, so they collide with any other tool that defines `/codex`, and they
  ship outside the plugin's version story.
- **A3: both** — plugin `/baton:codex` as the canonical, deployed pair, plus optional
  bare `/codex` user aliases documented (not force-deployed) for those who want them.

*My default if you don't answer:* **A3** — canonical `/baton:*` (safe, versioned) with the
bare aliases documented so you can drop them in. Lets me build without blocking on the fork.

**Fork B — journal line format bump.** Adding `| tok:N(basis)` to *every* fleet journal
line (single format, estimate fallback for rows without the regex). *Default:* yes, append
at end — it's the only way tokens are uniformly present, and append-at-end is
parser-safe. Flagging only because it changes a long-stable line format. Veto → tokens
only on rows with the field (two line shapes).

## 8. House rules

965-byte args (long prompts → temp file); `[Console]::Error.WriteLine` + `exit 2` on CLI
error; hooks exit 0; utf8NoBOM writes; `ConvertTo-Json -InputObject @(...)` for arrays;
never name vars `$args`/`$input`/`$event`; guard the `len/4` divide; box-private
placeholder hosts only in any example fleet.yaml. Execution per model ladder:
subagent-driven, Haiku for transcription-grade tasks with complete code in the plan,
Sonnet for the `Invoke-Fleet-Cli` token-capture integration edit, Opus final whole-branch
review; streamlined ceremony (one final review).
