# Sprint 3 — GitHub Projects Sync (design)

**Status:** approved 2026-06-16
**Roadmap:** Baton v2 economic-conductor MVP, Sprint 3 of 7. Follows Sprint 1
(Triage Agent) and Sprint 2 (Usage Governor).
**Mantra:** *Labels classify, Project fields decide, Assignees own, Baton routes.*

## 1. Scope

Pull open issues from a repo, classify the untriaged ones through the Triage
Agent, and write the classification back to GitHub as **labels** (the classifying
dimensions) and **GitHub Projects v2 single-select fields** (the deciding
dimensions). Writes are **dry-run by default**; `--apply` commits them. All GitHub
operations go through the `gh` CLI — no hand-written GraphQL.

A new operator surface `/baton:projects` exposes two subcommands:

- `projects init [--title "Baton Board"]` — one-time: create the Project and ensure
  the `Priority` field exists.
- `projects sync` — classify + plan/apply the label and field writes. Dry-run unless
  `--apply`.

### Out of scope (deferred, named so the boundary is explicit)
- **Registering the GitHub model allotment as a worker** (`gh models run <model>` as a
  budgeted fleet worker). That is the Worker Adapter (Sprint 6). Sprint 3 consumes
  whatever workers the fleet offers; it will use the GitHub pool the moment one is
  registered in the box-private `fleet.yaml`.
- **Assignee management** ("Assignees own"). Sprint 3 reads assignees but does not set
  them.
- **Promoting `estimate` to a Project field.** Kept a label this sprint to hold the
  GraphQL/`gh project` field surface to exactly two fields (`Priority`, `Status`).
  One-line addition later if wanted.
- **A reverse sync** (GitHub field edits → Baton state). One-directional this sprint:
  Baton → GitHub.

## 2. Decisions

- **d-proj-1 — dry-run by default, `--apply` to write.** Writing to GitHub is an
  outward-facing mutation; the Triage Agent is deliberately recommend-only. `sync`
  prints the plan and writes nothing until re-run with `--apply`.
- **d-proj-2 — write both labels and Project v2 fields.** Labels carry the classifying
  dimensions (`type`, `area`, `risk`, `estimate`, `route`); the two deciding dimensions
  (`Priority`, `Status`) are Project v2 single-select fields. Fully delivers "Project
  fields decide."
- **d-proj-3 — Baton ensures structure via `gh`, idempotently.** `gh project field-list`
  reads what exists; an absent `Priority` field is created via
  `gh project field-create … --single-select-options "P0,P1,P2,P3,P4"`. `Status` ships by
  default on every Projects v2 board. Mirrors idea-lib's `Ensure-…Labels` idiom extended
  to fields. (Reversed from an earlier "never create structure" draft — the operator
  wants `gh` to manage board structure, and `gh` does it natively.)
- **d-proj-4 — project creation is explicit, never implicit.** `sync` uses a named
  project and create-if-absent on *fields*, but never creates a whole Project. A
  mistyped project number errors clearly and points at `projects init`. The only
  guardrail against accidental board spawning.
- **d-proj-5 — triage is the classification source; classification rides the governed
  fleet.** Untriaged issues (no `type:*` label) are classified via `Invoke-TriageAgent`
  → `Select-Capability`, which already carries the Sprint-2 route-around-exhausted
  filter and budget awareness. Classification therefore **prefers a budgeted/included
  worker and routes around it to another model when its budget is exhausted** —
  automatically, no failure. Already-typed issues are respected (idempotent;
  `--reclassify` overrides).
- **d-proj-6 — dry-run spends zero tokens.** Dry-run does not classify; it lists each
  untriaged issue and the worker that *would* classify it (a read-only `Select-Capability`
  peek), surfacing the token economics before any spend. `--apply` does the real
  classify+write. (A `--classify` flag can force full-preview classification.) Tokens are
  a resource — don't burn them on a preview.
- **d-proj-7 — fallbacks don't write decisions.** A low-confidence / `New-TriageFallback`
  result yields only a `needs-triage` label, never a `Priority`/`Status` field write.
- **d-proj-8 — box-private targeting.** Owner / repo / project number live only in runtime
  args or the live box-private config, never in the shared seed. Placeholders only in any
  committed example.

## 3. Mantra → target mapping

| Triage field | GitHub target | `gh` mechanism |
|---|---|---|
| `type` | label `type:<v>` | `gh issue edit --add-label` |
| `area` | label `area:<v>` (skipped when null) | `gh issue edit --add-label` |
| `risk` | label `risk:<v>` | `gh issue edit --add-label` |
| `estimate` | label `estimate:<v>` | `gh issue edit --add-label` |
| `recommended_platform` | label `route:<v>` | `gh issue edit --add-label` |
| `priority` | Project field `Priority` (P0–P4, created if absent) | `gh project field-create` / `item-edit` |
| `status` | Project field `Status` → `Todo` on import | `gh project item-edit` |
| low confidence / fallback | label `needs-triage` (no field writes) | `gh issue edit --add-label` |

## 4. Architecture

The single gh-mocking seam: **every gh-touching function takes
`[scriptblock]$GhInvoker = { param($argv) & gh @argv }`**, defaulted to the real `gh`
and stubbed in tests. Mirrors triage's `-Dispatcher` seam. This is what makes the I/O
layer hermetically testable and guarantees tests never touch a real repo or board.

### Files

- **`scripts/projects-lib.ps1`** — core library:
  - `Get-RepoIssues` — `gh issue list --json number,title,body,labels,assignees,url`
    (open issues). Returns normalized PSCustomObjects.
  - `Resolve-ProjectFields` — `gh project field-list <num> --owner <o> --format json` →
    field map `{ name → { id, type, options{ optionName → optionId } } }`. Read-only.
  - `Ensure-ProjectFields` — create-if-absent on `Priority` (options P0–P4) via
    `gh project field-create`. Idempotent. Returns the refreshed field map.
  - `ConvertTo-SyncLabels` — pure: triage hashtable → desired label string[]
    (`type:`,`area:`,`risk:`,`estimate:`,`route:`; or `needs-triage` for a fallback).
  - `ConvertTo-SyncFieldValues` — pure: triage hashtable → `@{ Priority='P1'; Status='Todo' }`
    (empty for a fallback).
  - `Get-IssueTriageState` — pure: from an issue's current labels, is it already triaged
    (has a `type:*` label)? Returns `@{ triaged=$bool; existing_labels=@(...) }`.
  - `Build-SyncPlan` — **pure, zero gh**: issues + per-issue triage result + current
    labels + field map → ordered list of per-issue plan objects
    `{ number, classify_worker, add_labels=@(), set_fields=@(), add_to_project=$bool, skips=@() }`.
    Each label/field already present-and-correct becomes a `skip` with a reason. The whole
    mapping layer is tested here without any I/O.
  - `Invoke-SyncPlan` — **apply only**: executes a plan via `$GhInvoker`
    (`gh issue edit --add-label`, `gh project item-add`, `gh project item-edit`),
    **best-effort per issue** (one failure never aborts the batch). Returns per-issue
    results `{ number, applied=@(), failed=@(), error }`.
  - `Test-GhAuth` — preflight `gh auth status` (reuse idea-lib idiom); returns `$bool`.
- **`scripts/fleet-projects.ps1`** — CLI dispatcher: `init` | `sync`; flags `--owner`,
  `--repo`, `--project <num>`, `--apply`, `--reclassify`, `--classify`, `--json`. Resolves
  config, runs the pure planner, prints the plan (dry-run) or applies it.
- **`commands/projects.md`** — `/baton:projects` slash command (shells to
  `$HOME/.claude/scripts/fleet-projects.ps1 $ARGUMENTS`).
- **`scripts/test-projects.ps1`** — hand-rolled `Check($n,$c)` harness; gh stubbed via
  injected `-GhInvoker`, triage stubbed via injected dispatcher / canned JSON. Never
  touches a real repo or board.
- **Touched:** `scripts/bootstrap.ps1` (manifest: add `projects-lib.ps1`,
  `fleet-projects.ps1`), `scripts/test-bootstrap.ps1` (two deploy assertions),
  `.claude-plugin/plugin.json` (`1.2.0-rc.9` → `1.2.0-rc.10`).

## 5. Data flow (`sync`)

1. Resolve owner / repo / project number from args (box-private; no seed defaults).
2. `Test-GhAuth` — stop before any write if unauthenticated.
3. `Get-RepoIssues` — open issues.
4. `Resolve-ProjectFields` (+ `Ensure-ProjectFields` on `--apply`) → field map, resolved
   **once** per sync (not per issue — keeps API calls low).
5. Per issue: `Get-IssueTriageState`.
   - **Dry-run (default):** untriaged → record `classify_worker` (read-only
     `Select-Capability` peek), no token spend; triaged → compute concrete label/field
     diff. `--classify` forces real classification in dry-run.
   - **Apply:** untriaged → `Invoke-TriageAgent` (governed routing; tokens spent here);
     triaged → reuse existing labels (unless `--reclassify`).
6. `Build-SyncPlan` → per-issue plan with skips.
7. Dry-run → print the plan and exit (zero mutating gh calls). `--apply` → `Invoke-SyncPlan`,
   print results.

## 6. Error handling

- gh unauthenticated → `Test-GhAuth` stops before any write, clear message.
- Project / field absent on resolve → plan marks affected field writes as skips with a
  reason (`"field 'Priority' not found on Project #N"`), never crashes. On `--apply`,
  `Ensure-ProjectFields` creates `Priority` first.
- Triage dispatch failure → `New-TriageFallback` → `needs-triage` label only (d-proj-7).
- `Invoke-SyncPlan` best-effort per issue: a single failing issue is recorded in `failed`
  and the batch continues.
- Idempotent: re-running only adds missing labels / sets differing fields; already-correct
  state is a skip.

## 7. CLI surface

```
/baton:projects init  --owner @me [--repo OWNER/REPO] [--title "Baton Board"]
/baton:projects sync  --owner @me --project N [--repo OWNER/REPO]
                      [--apply] [--reclassify] [--classify] [--json]
```

Dry-run example:

```
$ baton projects sync --owner @me --project 7
PLAN (dry-run — no writes):
  #61  add type:bug, risk:medium, route:Codex; set Priority=P1, Status=Todo; +add to project
  #62  add type:docs (Priority=P3 already set — skip)
  #63  untriaged — would classify via github-models/gpt-4o
Re-run with --apply to write.
```

## 8. Testing (~24 checks)

**Pure layer (no gh):**
- `ConvertTo-SyncLabels`: full triage → `type:`/`area:`/`risk:`/`estimate:`/`route:`;
  null `area` omitted; fallback → `needs-triage` only.
- `ConvertTo-SyncFieldValues`: full triage → `Priority`+`Status`; fallback → empty.
- `Get-IssueTriageState`: `type:*` present → triaged; absent → untriaged.
- `Build-SyncPlan`: untriaged → classify + full plan; already-typed → idempotent skip;
  field absent in map → field-write skip with reason; fallback → `needs-triage` only,
  no field writes; label already present → skip; field already-correct → skip.

**I/O layer (stubbed `-GhInvoker`):**
- `Resolve-ProjectFields`: parses canned `field-list` JSON → field map with option ids.
- `Ensure-ProjectFields`: `Priority` absent → emits a `project field-create` call with the
  P0–P4 options; present → emits no create.
- `Invoke-SyncPlan`: asserts the exact `gh issue edit` / `project item-add` /
  `project item-edit` arg arrays; one stubbed failure → recorded in `failed`, batch
  continues (best-effort).
- `Test-GhAuth`: unauth stub → `$false`, stops the run.

**CLI:**
- dry-run emits **zero** mutating gh calls (stub records calls; assert none mutate).
- `--apply` triggers the write calls.

All tests stub gh and triage; none touch a real repo, board, or model. Bootstrap test
asserts both new scripts deploy.

## 9. Risks

- **`gh project` JSON shape drift across gh versions.** Mitigation: `Resolve-ProjectFields`
  parses defensively (field by name, options by name) and the canned-JSON test pins the
  expected shape for gh 2.86.0.
- **Option-name vs option-id.** `item-edit` needs the option *id*, not the name;
  `Resolve-ProjectFields` builds the name→id map so the planner works in names and the I/O
  layer translates. Covered by the resolve + invoke tests.
- **Token spend on large boards.** `--apply` classifies every untriaged issue. Mitigated by
  governed routing (route-around on budget exhaustion) and dry-run preview showing the
  classifier per issue before any spend.
