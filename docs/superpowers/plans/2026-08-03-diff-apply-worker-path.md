# Diff-apply worker path — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let providers with no filesystem harness (`kind: http`, `kind: stdio-json` —
local LM Studio, free-tier HTTP) take edit tasks, by having Baton read the files, the model
return SEARCH/REPLACE blocks, and Baton apply them to the worktree.

**Architecture:** A new pure library (`diff-apply-lib.ps1`) parses, validates, and applies
edit blocks. `fleet-executor-lib.ps1` gains two predicates and one dispatch branch;
everything downstream of the branch (proof-by-diff, frozen contract, scope oracle, rework)
is untouched because it judges the worktree, not the worker.

**Tech Stack:** PowerShell 7, `utf8NoBOM`, hermetic script-based tests
(`scripts/test-*.ps1`, run individually with `pwsh -NoProfile -File`).

**Spec:** `docs/superpowers/specs/2026-08-03-diff-apply-worker-path-design.md` — read it.

## Global Constraints

- **PowerShell 7 only.** Never name a variable `$args`, `$input`, `$event`, `$matches`,
  `$host`, or `$pid`.
- **Every file write uses `-Encoding utf8NoBOM`.**
- **Tests are hermetic.** Point `BATON_HOME` at a temp dir. Never touch real `~/.baton`,
  `~/.claude`, or a real project tree. Restore every env var you set in a `finally`.
- **Box-private data never enters the repo.** Fleet rows in tests use placeholder names
  only (`local-host-a`, `model-small`) — never a real model id, endpoint, or host.
- **Shell command arguments must stay under 965 bytes.** Anything longer goes in a file.
- **`Test-ProviderAgentic` must not change.** Tests A9/A10 assert the d091 transport veto.
- **No fuzzy matching.** Exact ordinal string comparison only.
- **Fail-soft telemetry.** Writing an observation row must never fail a task.
- **Never claim green without running.** Paste real test output in every report.
- Test suites are run individually; there is no central registry and no CI. A new suite is
  a new `scripts/test-<name>.ps1`.

## Dependency facts (verified 2026-08-03 — do not re-derive or guess)

- `Get-Utf8ByteCount` lives in **`scripts/fleet-lib.ps1:310`**, not in the executor.
  `diff-apply-lib.ps1` must dot-source `fleet-lib.ps1` to use it.
- `Test-DiffFilesInAllowedPaths` lives in **`scripts/verification-lib.ps1:573`** and returns
  `@{ ok; enforced; scope_exact; first_offender }`. Entries ending in `/` are segment-safe
  directory prefixes (`app/` matches `app/x.py`, not `apple/x.py`); all other entries are
  exact matches. Matching is case-insensitive. It rejects any `..` segment itself.
  **Empty `AllowedPaths` means not enforced and returns `ok = $true`** — which is why plan
  check A17 expects an unrestricted task to apply.
- The dot-sourcing convention is a block of `. "$PSScriptRoot/<lib>.ps1"` lines at the top
  of the file, each with a trailing comment naming what it is needed for. See
  `fleet-executor-lib.ps1:9-14`. Match that style.
- Baseline before this work: `test-fleet-executor-lib`, `test-conductor-lib`,
  `test-instrument-abi`, and `test-routing-observe` all exit 0 with `ALL PASS`. Any
  failure you see in them is yours.

---

### Task 1: Edit-block parser

**Files:**
- Create: `scripts/diff-apply-lib.ps1`
- Create: `scripts/test-diff-apply-lib.ps1`

**Interfaces:**
- Produces: `ConvertFrom-EditBlocks -Text <string>` →
  `[ordered]@{ result = 'ok'|'malformed'|'empty'; error = <string>; blocks = @(...) }`
  where each block is
  `[ordered]@{ path = <string>; search = <string>; replace = <string>; is_create = <bool> }`.

**Behavior:**

Scan line by line. State machine: `outside` → (saw `FILE:`) → expect `<<<<<<< SEARCH` →
`in_search` → (saw `=======`) → `in_replace` → (saw `>>>>>>> REPLACE`) → `outside`.

- A `FILE:` line is `^FILE:\s*(.+?)\s*$`. Record the path; it is only consumed when the
  next non-blank line is `<<<<<<< SEARCH`. If any other non-blank line intervenes, the
  pending path is discarded (it was prose) — a bare `FILE:` mention is not an error.
- Marker lines must match exactly at column 0, tolerating trailing whitespace:
  `^<<<<<<< SEARCH\s*$`, `^=======\s*$`, `^>>>>>>> REPLACE\s*$`.
- `<<<<<<< SEARCH` with no pending `FILE:` path → `malformed`, error
  `SEARCH block with no preceding FILE: line`.
- End of text while inside a block → `malformed`, error `unterminated block for <path>`.
- Text outside blocks is ignored.
- Zero blocks and no error → `result = 'empty'`.
- `search` is the joined `in_search` lines; `replace` is the joined `in_replace` lines.
  Join with `` "`n" ``. A section with zero lines yields `''`.
- `is_create = ($search -eq '')`.
- **On any `malformed` result, return zero blocks.** Never return a partial set — a
  dropped edit looks like success and produces a half-implemented task.

Normalize the input's line endings to LF before scanning (`-replace "`r`n", "`n"` then
`-replace "`r", "`n"`), so CRLF model output parses identically.

- [ ] **Step 1: Write the failing tests**

Create `scripts/test-diff-apply-lib.ps1` following the convention in
`scripts/test-routing-observe.ps1` (shebang, `$ErrorActionPreference = 'Stop'`, an
`Assert($label, $cond)` helper counting `$script:failures`, temp `BATON_HOME` in a `try`
with env restore in `finally`, and `exit $failures` at the end).

Cover, at minimum:

| id | case | expectation |
|---|---|---|
| P1 | one well-formed block | `result=ok`, 1 block, path/search/replace exact |
| P2 | two blocks, different files | 2 blocks, order preserved |
| P3 | two blocks, same file | 2 blocks, order preserved |
| P4 | prose before, between, and after blocks | prose ignored, blocks intact |
| P5 | CRLF input | parses identically to the LF form |
| P6 | unterminated block (no `>>>>>>> REPLACE`) | `result=malformed`, 0 blocks |
| P7 | `<<<<<<< SEARCH` with no `FILE:` line | `result=malformed`, 0 blocks |
| P8 | prose only, no blocks | `result=empty`, 0 blocks |
| P9 | empty string / whitespace only | `result=empty`, 0 blocks |
| P10 | empty SEARCH section | 1 block, `is_create=$true` |
| P11 | `FILE:` line followed by prose, then a real block elsewhere | pending path discarded; the real block still parses; `result=ok` |
| P12 | one good block followed by one unterminated block | `result=malformed`, **0 blocks** (all-or-nothing at parse time) |
| P13 | search text containing a line that looks like prose but not a marker | preserved verbatim |
| P14 | replace section empty (deletion) | 1 block, `replace=''`, `is_create=$false` |

Build the fixture text with here-strings. Note that `<<<<<<<` and `=======` inside a
PowerShell here-string are literal — no escaping needed — but use a **single-quoted**
here-string (`@'...'@`) so `$` and backticks in fixture code stay literal.

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-diff-apply-lib.ps1`
Expected: FAIL — `ConvertFrom-EditBlocks` is not defined.

- [ ] **Step 3: Implement `ConvertFrom-EditBlocks` in `scripts/diff-apply-lib.ps1`**

Create the file with a header comment naming the spec and d103, then the function per the
behavior above.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-diff-apply-lib.ps1`
Expected: all PASS, exit 0. Paste the real output in your report.

- [ ] **Step 5: Commit**

```
git add scripts/diff-apply-lib.ps1 scripts/test-diff-apply-lib.ps1
git commit -m "feat(diff-apply): edit-block parser (d103)"
```

---

### Task 2: Safe applier

**Files:**
- Modify: `scripts/diff-apply-lib.ps1`
- Modify: `scripts/test-diff-apply-lib.ps1` (append)

**Interfaces:**
- Consumes: Task 1's `ConvertFrom-EditBlocks` block shape;
  `Test-DiffFilesInAllowedPaths -DiffFiles <string[]> -AllowedPaths <string[]>` from
  `scripts/verification-lib.ps1` (returns an object with `.ok` and `.enforced`).
- Produces:
  - `Test-DiffApplyPathSafe -Worktree <string> -RelPath <string>` →
    `[ordered]@{ ok = <bool>; reason = <string>; full = <string> }`
  - `Invoke-EditBlockApply -Worktree <string> -Blocks <object[]> -AllowedPaths <string[]>` →
    `[ordered]@{ ok = <bool>; result = 'ok'|'search-not-found'|'search-ambiguous'|'path-rejected'|'scope-rejected'|'create-exists'; error = <string>; files_written = @(<string>); blocks_applied = <int> }`

**`Test-DiffApplyPathSafe` rejects, each with its own `reason`:**

- empty/whitespace path → `empty-path`
- `[System.IO.Path]::IsPathRooted($RelPath)` → `absolute-path`
- path matching `^[A-Za-z]:` or starting `\\` or `//` → `absolute-path`
- any segment equal to `..` (split on both `/` and `\`) → `parent-escape`
- any segment that is empty after the first, or a segment equal to `.git` → `git-path`
  (check `.git` case-insensitively)
- any character with code point < 32 → `control-char`
- After `$full = [System.IO.Path]::GetFullPath((Join-Path $Worktree $RelPath))`, if `$full`
  is not `$rootFull` + separator + something → `outside-worktree`, where
  `$rootFull = [System.IO.Path]::GetFullPath($Worktree).TrimEnd('\','/')`. Compare with
  `StartsWith(..., [System.StringComparison]::OrdinalIgnoreCase)` on Windows.
- If the target exists and
  `(Get-Item -LiteralPath $full -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint`
  → `symlink-target`. Also check each existing ancestor directory up to the worktree root
  for `ReparsePoint` — a symlinked directory is the same escape.

**`Invoke-EditBlockApply` algorithm — all-or-nothing:**

1. **Validate every path first.** Any failure → return immediately with
   `result='path-rejected'`, nothing written.
2. **Scope check.** Collect the distinct relative paths (normalized to `/` separators) and
   call `Test-DiffFilesInAllowedPaths -DiffFiles $paths -AllowedPaths $AllowedPaths`. If it
   reports not-ok → `result='scope-rejected'`, nothing written. Do **not** reimplement the
   matching rule — reuse that function so the pre-check and the oracle cannot drift.
3. **Load into memory.** For each distinct path that exists, read raw bytes, and record:
   `content` (as a string), `eol` (`"\r\n"` if CRLF occurrences outnumber lone-LF, else
   `"\n"`), `bom` (`$true` if the bytes start `EF BB BF`), `trailing_newline` (`$true` if
   the content ends with a newline).
4. **Apply each block in order** against the in-memory map:
   - `is_create`: if the path is already in the map (file existed) → `result='create-exists'`.
     Otherwise add it with `content = <replace>`, `eol = "\n"`, `bom = $false`,
     `trailing_newline = $true`.
   - otherwise: normalize the block's `search` and `replace` from LF to the file's `eol`.
     Count occurrences of `search` in `content` with an ordinal loop
     (`IndexOf($search, $i, [System.StringComparison]::Ordinal)`).
     - 0 → `result='search-not-found'`, `error` names the path and the first ~80 chars of
       the search text.
     - 2+ → `result='search-ambiguous'`, same detail.
     - 1 → replace that single occurrence (index-based `Remove`/`Insert`, **not**
       `-replace`, which is regex and would corrupt text containing metacharacters).
   - Any failure returns immediately; **nothing is flushed.**
5. **Flush.** Only after every block succeeded, write each touched file: restore
   `trailing_newline` state, create parent directories as needed, and write with
   `utf8NoBOM` (or with a BOM if `bom` was true — use
   `[System.IO.File]::WriteAllText($full, $text, [System.Text.UTF8Encoding]::new($true))`).
   Return `ok=$true`, `result='ok'`, the written paths, and the block count.

- [ ] **Step 1: Write the failing tests** (append inside the existing `try` block)

| id | case | expectation |
|---|---|---|
| A1 | single exact match | file content updated, `ok=$true`, `blocks_applied=1` |
| A2 | search text absent | `search-not-found`, file byte-identical to before |
| A3 | search text twice | `search-ambiguous`, file unchanged |
| A4 | two blocks same file, second matches text the first wrote | both apply, `ok=$true` |
| A5 | good block + later bad block | `ok=$false`, **both files byte-identical to before** |
| A6 | create new file (empty SEARCH) | file created with exact content |
| A7 | create where file exists | `create-exists`, existing file unchanged |
| A8 | CRLF file, LF blocks | edit applies, file still CRLF throughout |
| A9 | LF file stays LF | no CRLF introduced |
| A10 | file with BOM | BOM still present after write |
| A11 | file with no trailing newline | still no trailing newline after write |
| A12 | search text containing regex metacharacters (`$x = @(1); a.b[0]`) | applies literally |
| A13 | path `../escape.txt` | `path-rejected`, reason `parent-escape` |
| A14 | absolute path | `path-rejected`, reason `absolute-path` |
| A15 | path `.git/config` | `path-rejected`, reason `git-path` |
| A16 | path outside `AllowedPaths` | `scope-rejected`, nothing written |
| A17 | `AllowedPaths` empty (unrestricted) | applies (matches the oracle's unenforced case) |
| A18 | deletion (empty replace) | text removed, rest intact |

For A5, assert byte-identity by hashing every file before and after
(`Get-FileHash -Algorithm SHA256`), not by eyeballing content.

Create the fixture worktree under the suite's temp dir — a plain directory is enough for
the applier; no git init required.

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-diff-apply-lib.ps1`
Expected: the new A-checks FAIL (functions not defined); P-checks still PASS.

- [ ] **Step 3: Implement `Test-DiffApplyPathSafe` and `Invoke-EditBlockApply`**

Dot-source `verification-lib.ps1` from `diff-apply-lib.ps1`'s header the same way sibling
libraries do (check how `fleet-executor-lib.ps1` sources its dependencies and match that
pattern). If `Test-DiffFilesInAllowedPaths` is unavailable, fail closed —
`scope-rejected` — never silently skip the check.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-diff-apply-lib.ps1`
Expected: all P and A checks PASS. Paste real output.

- [ ] **Step 5: Commit**

```
git add scripts/diff-apply-lib.ps1 scripts/test-diff-apply-lib.ps1
git commit -m "feat(diff-apply): safe all-or-nothing applier (d103)"
```

---

### Task 3: Context assembly and the size envelope

**Files:**
- Modify: `scripts/diff-apply-lib.ps1`
- Modify: `scripts/test-diff-apply-lib.ps1` (append)

**Interfaces:**
- Produces:
  - `Get-DiffApplyLimits -Provider <object>` →
    `[ordered]@{ max_context_bytes = <int>; max_files = <int>; max_blocks = <int> }`,
    reading `$Provider.diff_apply_limits` with defaults `24000` / `4` / `8`. When the
    provider declares `max_prompt_bytes`, clamp `max_context_bytes` to
    `min(declared, max_prompt_bytes - 4000)` (the reserve covers instructions plus the
    model's response).
  - `Get-DiffApplyContext -Worktree <string> -AllowedPaths <string[]> -Limits <object>` →
    `[ordered]@{ ok = <bool>; reason = <string>; files = @([ordered]@{ path; text }); context_bytes = <int>; file_count = <int> }`
  - `Build-DiffApplyPrompt -TaskDesc <string> -InputBlock <string> -Context <object> -AllowedPaths <string[]> -Limits <object>` → `<string>`

**`Get-DiffApplyContext` behavior:**

- Expand `AllowedPaths`: an entry ending in `/` is a directory prefix — enumerate existing
  files beneath it recursively, skipping anything under `.git/`. An entry naming a concrete
  file is taken as-is. A path that does not exist yet is a file the task will *create* and
  is simply not read (it must still appear in the prompt's scope list).
- **Do not follow reparse points while recursing.** On Windows a junction or symlinked
  directory inside the tree can send `Get-ChildItem -Recurse` into an unbounded loop, which
  would hang a dispatch rather than fail it. Skip any directory whose attributes include
  `ReparsePoint`. Enumeration must also never escape the worktree root.
- Sort deterministically by relative path (ordinal) so the same task yields the same
  prompt — non-determinism here would poison the observation data.
- Read each file as text; measure with `Get-Utf8ByteCount` (already in the codebase — find
  it and reuse; do not write a second byte counter).
- If `file_count > max_files` → `ok=$false`,
  `reason = "task exceeds diff-apply envelope: <n> files > limit <max>"`.
- If the running byte total exceeds `max_context_bytes` → `ok=$false`,
  `reason = "task exceeds diff-apply envelope: <n> bytes > limit <max>"`.
- **Never truncate a file.** A model shown half a file produces SEARCH blocks that cannot
  match, or that match the wrong region. Over-budget is a routing signal, not a
  degradation to absorb.

**`Build-DiffApplyPrompt` output**, in this order:

1. the optional bus `InputBlock` (advisory data, not authority — same framing as
   `Build-AgenticWorkerPrompt`)
2. `Task: <desc>`
3. the scope list, same wording as `Build-AgenticWorkerPrompt`'s scope brief
4. each file as `FILE: <path>` followed by a fenced block of its exact current content
5. the edit-format instruction block: the grammar from the spec, one worked example,
   and these rules stated plainly — quote the existing text **exactly**, include enough
   surrounding lines to be unique, **keep each SEARCH section as small as possible while
   still matching only once**, emit **at most `max_blocks` blocks**, use an empty
   SEARCH section to create a new file, and **do not** output a unified diff, prose
   explanation of the change instead of blocks, or the whole file.

Keep the instruction block short and imperative. It is being read by a small model.

**Observed behavior to design against (real probe, 2026-08-03 02:58).** A live local model
was given a 3-function file and asked to make two unrelated one-line changes. It returned a
correctly-formed block on the first attempt — but quoted the **entire file** as a single
SEARCH section rather than two surgical blocks. That is harmless on a small file and
expensive-to-dangerous on a large one: it burns context, and every quoted line is a line
the model can silently mistranscribe.

Hence the "keep each SEARCH section as small as possible" rule above, and hence
`blocks_emitted` in the observation record is worth reading closely — a task with N
independent changes that comes back as 1 block means the model is bulk-quoting, not
editing. That is a size signal, and it is exactly the kind of thing the envelope data
should surface.

**The minimality rule is load-bearing, and that is measured, not assumed.** Two follow-up
probes added the "keep each SEARCH section as small as possible" line and gave the same
model a synthetic module of 20 and then 60 near-identical functions (2.8 KB and 7.0 KB),
asking for one surgical change deep inside. Both returned a **minimal 3-line block**
targeting exactly the right function, unique match, in 3 seconds. Same model, same task
shape, one added sentence — bulk-quote became surgical edit. Do not drop that rule from the
instruction block.

Honest limit on that evidence: those files were synthetic and uniform, which is the *easy*
case for uniqueness because each function carried a distinguishing docstring. Real code has
genuinely repeated fragments, where a minimal SEARCH section is more likely to match twice
and hit `search-ambiguous`. Expect the ambiguity path to fire in practice; it is a
correct-by-design refusal, not a bug, and the model should be given the rework signal.

- [ ] **Step 1: Write the failing tests**

| id | case | expectation |
|---|---|---|
| C1 | limits default when provider declares none | 24000 / 4 / 8 |
| C2 | provider overrides are honored | exact values returned |
| C3 | `max_prompt_bytes` clamps `max_context_bytes` | clamped to declared − 4000 |
| C4 | two small files under a `dir/` prefix | both read, `ok=$true`, correct `file_count` |
| C5 | file count over limit | `ok=$false`, reason names files and the limit |
| C6 | byte total over limit | `ok=$false`, reason names bytes and the limit |
| C7 | `.git/` contents never included | absent from `files` |
| C8 | non-existent path in AllowedPaths | not read, no error |
| C9 | deterministic ordering | two calls produce identical `files` order |
| C10 | prompt contains task desc, scope list, file contents, and the markers `<<<<<<< SEARCH` / `=======` / `>>>>>>> REPLACE` | all present |
| C11 | prompt states the block cap from `Limits` | the number appears |

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-diff-apply-lib.ps1`
Expected: new C-checks FAIL.

- [ ] **Step 3: Implement the three functions**

- [ ] **Step 4: Run tests to verify they pass** — paste real output.

- [ ] **Step 5: Commit**

```
git add scripts/diff-apply-lib.ps1 scripts/test-diff-apply-lib.ps1
git commit -m "feat(diff-apply): context assembly and size envelope (d103)"
```

---

### Task 4: Observation record

**Files:**
- Modify: `scripts/diff-apply-lib.ps1`
- Modify: `scripts/test-diff-apply-lib.ps1` (append)

**Interfaces:**
- Produces: `Write-DiffApplyObservation -Row <hashtable> [-Path <string>]` → `[bool]`
  (`$true` if written). Default path
  `Join-Path (Get-BatonHome) 'diff-apply-observations.jsonl'`.

**Behavior:**

Append one JSON object per line (`ConvertTo-Json -Compress -Depth 6`), `utf8NoBOM`,
creating the parent directory if needed. Fields, in this order, always present (empty
string or `$null` when unknown):

`ts`, `run_id`, `task_id`, `provider`, `model_version`, `context_bytes`, `file_count`,
`blocks_emitted`, `blocks_applied`, `parse_result`, `apply_result`, `verdict`.

`ts` is `[datetimeoffset]::UtcNow.ToString('o')` unless the caller supplies one — accept an
injected timestamp so tests are deterministic.

**Fail-soft is mandatory:** wrap the whole body in `try/catch` and return `$false` on any
error. An unwritable telemetry file must never fail a task.

`model_version` is required in the schema because a capability observation about a model is
worthless without its version — the same lesson the jagged-edge work recorded. When the
fleet row carries no version, write the empty string; do not omit the field.

- [ ] **Step 1: Write the failing tests**

| id | case | expectation |
|---|---|---|
| O1 | one row written | file has 1 line, parses as JSON, all 12 fields present |
| O2 | two calls | 2 lines, append not overwrite |
| O3 | injected `ts` honored | exact value round-trips |
| O4 | missing optional fields | present as `''`/`null`, never absent |
| O5 | unwritable path (point at a path whose parent is an existing *file*) | returns `$false`, throws nothing |
| O6 | row containing a quote/newline in a string field | round-trips intact |

- [ ] **Step 2: Run to verify they fail** — expected FAIL.

- [ ] **Step 3: Implement `Write-DiffApplyObservation`**

- [ ] **Step 4: Run tests to verify they pass** — paste real output.

- [ ] **Step 5: Commit**

```
git add scripts/diff-apply-lib.ps1 scripts/test-diff-apply-lib.ps1
git commit -m "feat(diff-apply): observation record for the size envelope (d103)"
```

---

### Task 5: Eligibility predicates

**Files:**
- Modify: `scripts/fleet-executor-lib.ps1`
- Modify: `scripts/conductor-lib.ps1` (the mirror at ~line 429)
- Modify: `scripts/test-fleet-executor-lib.ps1` (append)

**Interfaces:**
- Produces:
  - `Test-ProviderDiffApply -Provider <object>` → `[bool]`
  - `Test-ProviderEditCapable -Provider <object>` → `[bool]`

**`Test-ProviderDiffApply` returns `$true` only when both hold:**

- `$Provider.diff_apply -eq $true` (explicit opt-in; absent or false → `$false`)
- `[string]$Provider.kind -in @('http', 'stdio-json')`

A `kind: cli` provider is never a diff-apply provider — it already has hands.

**`Test-ProviderEditCapable`** returns
`(Test-ProviderAgentic -Provider $Provider) -or (Test-ProviderDiffApply -Provider $Provider)`.

**Do not modify `Test-ProviderAgentic`.**

**Switch these call sites to `Test-ProviderEditCapable`:**

- `fleet-executor-lib.ps1:168` (`Get-CapabilityCostTierFloor`) — **this is what closes
  #168**; it lets the planner see a free/local floor for `code-gen`
- `fleet-executor-lib.ps1:235` (`Get-EditPoolExclusions`) — when a provider fails the
  combined predicate, the reason string must distinguish the cases: a text-transport
  provider without the opt-in reports `not edit-eligible (no diff_apply opt-in)`;
  anything else keeps `not edit-eligible`
- `fleet-executor-lib.ps1:439` (`Resolve-AgenticSubstituteCandidates`)
- `fleet-executor-lib.ps1:826` (`New-AgenticSpawner` candidate filter)
- `conductor-lib.ps1:429` — the planner-side mirror. Read the existing function, mirror the
  new combined rule exactly, and update its comment to name both predicates.

The eligibility-agreement test at `test-fleet-executor-lib.ps1:234` compares the executor
predicate against the planner mirror. It must still pass; extend its provider fixtures to
include diff-apply rows so the agreement is actually exercised on the new case.

- [ ] **Step 1: Write the failing tests** (append to `test-fleet-executor-lib.ps1`)

| id | case | expectation |
|---|---|---|
| DA1 | `kind=http`, `diff_apply=$true` | `Test-ProviderDiffApply` `$true` |
| DA2 | `kind=stdio-json`, `diff_apply=$true` | `$true` |
| DA3 | `kind=http`, no `diff_apply` | `$false` |
| DA4 | `kind=http`, `diff_apply=$false` | `$false` |
| DA5 | `kind=cli`, `diff_apply=$true` | `$false` (already has hands) |
| DA6 | `kind=http`, `diff_apply=$true` | `Test-ProviderAgentic` still `$false` (A9/A10 invariant) |
| DA7 | same row | `Test-ProviderEditCapable` `$true` |
| DA8 | `platform=claude`, `kind=cli` | `Test-ProviderEditCapable` `$true` |
| DA9 | `platform=local`, `kind=cli`, no opt-in | `Test-ProviderEditCapable` `$false` |
| DA10 | fleet with only a `local`-tier diff-apply `code-gen` provider | `Get-CapabilityCostTierFloor -Capability code-gen` returns `local`, not `UNAVAILABLE` — **the #168 regression guard** |
| DA11 | text-transport provider without opt-in | `Get-EditPoolExclusions` reason contains `no diff_apply opt-in` |
| DA12 | extended agreement fixtures | executor and planner predicates agree on every row |

Existing checks A1–A10 must all still pass unchanged.

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1`
Expected: DA-checks FAIL, A1–A10 PASS.

- [ ] **Step 3: Implement the predicates and switch the five call sites**

- [ ] **Step 4: Run both suites**

```
pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
```

Expected: both green. `test-conductor-lib.ps1` covers the planner mirror — if it goes red,
the mirror drifted. Paste real output for both.

- [ ] **Step 5: Commit**

```
git add scripts/fleet-executor-lib.ps1 scripts/conductor-lib.ps1 scripts/test-fleet-executor-lib.ps1
git commit -m "feat(diff-apply): edit-capable predicate; free/local floor for code-gen (#168)"
```

---

### Task 6: Dispatch branch and end-to-end proof

**Files:**
- Modify: `scripts/fleet-executor-lib.ps1`
- Modify: `scripts/test-fleet-executor-lib.ps1` (append)

**Interfaces:**
- Consumes: Tasks 1–4 (`ConvertFrom-EditBlocks`, `Invoke-EditBlockApply`,
  `Get-DiffApplyLimits`, `Get-DiffApplyContext`, `Build-DiffApplyPrompt`,
  `Write-DiffApplyObservation`); Task 5's predicates.
- Produces: `Invoke-DiffApplyAttempt` with the **same return shape** as
  `Invoke-AgenticDispatchAttempt`: `@{ result = @{ stdout; stderr; exit_code; duration_s }; dispatch_error = <string> }`.

**`Invoke-DiffApplyAttempt` parameters:** `-Candidate`, `-Task`, `-Prompt`(no — see below),
`-Worktree`, `-FleetPath`, `-UsagePath`, `-DepthTier`, `-RunDir`, `-Dispatcher`.

It builds its own prompt (it needs the file contents, which the agentic prompt has no
reason to carry), so it takes `-TaskDesc`, `-InputBlock`, and `-AllowedPaths` rather than a
finished prompt string.

**Algorithm:**

1. `$limits = Get-DiffApplyLimits -Provider <fleet row for $Candidate.name>`
2. `$ctx = Get-DiffApplyContext -Worktree $Worktree -AllowedPaths $AllowedPaths -Limits $limits`.
   If `-not $ctx.ok`: write an observation row (`parse_result=''`,
   `apply_result='envelope-exceeded'`, with `context_bytes`/`file_count` filled in) and
   return `exit_code = -1`, `stderr = $ctx.reason`, `dispatch_error = $ctx.reason`.
3. `$prompt = Build-DiffApplyPrompt ...`
4. Dispatch exactly as the agentic path does — `& $Dispatcher` when supplied, else
   `Invoke-Fleet -Name ... -NoJournal`. **No `Push-Location` is needed** (the model is not
   touching the filesystem), but pushing to the worktree is harmless and keeps journal
   context consistent; do not push, and note why in a comment.
5. Non-zero exit → return as-is; the caller's existing failure handling applies.
6. Parse the stdout. `malformed` or `empty` → observation row, then return `exit_code = 1`
   with `stderr` naming the parse error. This is a real failure, not a no-change pass.
7. `Invoke-EditBlockApply`. Failure → observation row, return `exit_code = 1` with the
   apply `result` and `error` in `stderr`.
8. Success → observation row with `blocks_applied`, return `exit_code = 0` and the model's
   stdout preserved (the task bus captures it downstream).

**Rating interaction:** when `apply_result` is `envelope-exceeded`, the failure is about
size, not model quality — per the #156 precedent (availability is not quality), it must not
produce a capability rating.

Mechanism (verified — implement exactly this, do not invent an alternative):
`Resolve-OutcomeRatingValue` in `scripts/routing-observe-lib.ps1:83` already takes a
`-Why` parameter and returns `$null` to skip a rating. Add an explicit early check there
for the envelope case, returning `$null`, and make the spawner's `why` string for an
over-envelope task contain the stable literal `diff-apply envelope` so the check can match
it. Put the check in `Resolve-OutcomeRatingValue` itself, **not** in
`Test-AvailabilityOutcome` — an oversized task is not an availability event, and
overloading that function would make its name a lie. Comment it as: size is not evidence
about model quality.

Add a covering check to `scripts/test-routing-observe.ps1`: a `why` containing
`diff-apply envelope` yields `$null` (no rating), while an ordinary `fail` verdict still
yields `bad`.

**Spawner wiring** in `New-AgenticSpawner`, at the dispatch site (~line 974):

```
$isDiffApply = Test-ProviderDiffApply -Provider $pick
$firstAttempt = if ($isDiffApply) {
    Invoke-DiffApplyAttempt -Candidate $pick -TaskDesc ([string]$task.desc) `
        -InputBlock $busInputs -AllowedPaths $scopePaths -DepthTier $policy.depth_tier `
        -Worktree $Worktree -FleetPath $FleetPath -UsagePath $UsagePath -RunDir $RunDir `
        -TaskId ([string]$task.id) -Dispatcher $Dispatcher
} else {
    Invoke-AgenticDispatchAttempt -Candidate $pick -Prompt $prompt -DepthTier $policy.depth_tier `
        -Worktree $Worktree -FleetPath $FleetPath -UsagePath $UsagePath -Dispatcher $Dispatcher
}
```

Apply the same branch to the substitute dispatch (~line 1044) — a failover target may be a
diff-apply provider too. Everything after the branch (tree sha, per-task diff, usage
observation, verification) stays exactly as it is.

`$prompt` is still built unconditionally for the agentic path; leave that alone.

**Do not let the two prompts get crossed — this is a real defect, not a hypothetical.**
After the dispatch, the spawner calls

    Get-AgenticUsageObservation -Result $res -Worker ... -PromptBytes (Get-Utf8ByteCount -Text $prompt)

On a diff-apply dispatch, `$prompt` is the *agentic* prompt, which was never sent. Reporting
its size would mis-measure the dispatch and feed a wrong `prompt_bytes` into
context-overflow detection — which decides whether to fail over to a larger-context peer.

Fix: have `Invoke-DiffApplyAttempt` return the prompt it actually sent (add a
`prompt_sent` key alongside `result` and `dispatch_error`), and have the spawner measure
**the prompt that was actually dispatched** on both branches. Apply this at the substitute
dispatch site too. Add a check asserting that a diff-apply dispatch's observed
`prompt_bytes` matches the diff-apply prompt's byte count and not the agentic prompt's.

- [ ] **Step 1: Write the failing tests** (append to `test-fleet-executor-lib.ps1`)

Build a real temp git worktree with a seeded file, a placeholder fleet whose only
`code-gen` provider is `kind: http`, `diff_apply: true`, `cost_tier: local`, and a
`-Dispatcher` scriptblock returning canned text.

| id | case | expectation |
|---|---|---|
| E1 | dispatcher returns a valid block editing the seeded file | spawner `ok=$true`, file content changed on disk, `chose` = the provider |
| E2 | same | `why` mentions the diff grew (existing wording path) |
| E3 | same | `tasks/<id>.diff` written under `RunDir` |
| E4 | dispatcher returns prose only | `ok=$false`, worktree byte-identical |
| E5 | dispatcher returns a block whose SEARCH does not match | `ok=$false`, worktree byte-identical |
| E6 | dispatcher returns a block writing outside `allowed_paths` | `ok=$false`, worktree byte-identical |
| E7 | task whose files exceed the envelope | `ok=$false`, reason names the envelope, **dispatcher never invoked** (assert with a counter the scriptblock increments) |
| E8 | any of the above | an observation row was appended with `provider`, `context_bytes`, `file_count` populated |
| E9 | an agentic (`kind: cli`) provider in the same fleet | still takes the old path — regression guard that Task 6 changed nothing for existing providers |
| E10 | result shape from `Invoke-DiffApplyAttempt` | has exactly the keys `result` and `dispatch_error`, and `result` has `stdout`/`stderr`/`exit_code`/`duration_s` |

- [ ] **Step 2: Run to verify they fail** — expected FAIL.

- [ ] **Step 3: Implement `Invoke-DiffApplyAttempt` and wire both dispatch sites**

`fleet-executor-lib.ps1` must dot-source `diff-apply-lib.ps1`. Follow the existing sourcing
pattern in that file's header; do not invent a new one.

- [ ] **Step 4: Run the full suite set**

```
pwsh -NoProfile -File scripts/test-diff-apply-lib.ps1
pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
pwsh -NoProfile -File scripts/test-instrument-abi.ps1
pwsh -NoProfile -File scripts/test-routing-observe.ps1
```

All five green. `test-instrument-abi.ps1` guards the d091 transport veto specifically — if
it goes red, the veto was weakened and the change is wrong. Paste real output for all five.

- [ ] **Step 5: Commit**

```
git add scripts/fleet-executor-lib.ps1 scripts/test-fleet-executor-lib.ps1
git commit -m "feat(diff-apply): dispatch branch — text-only providers can implement (d103)"
```

---

### Task 7: Deploy list and documentation

**Files:**
- Modify: `scripts/bootstrap.ps1`
- Modify: `docs/agent-handoffs.md`
- Create: `docs/diff-apply.md`

**Why this is its own task:** `bootstrap.ps1` deploys an explicit inclusion list, and it
has silently omitted new scripts **three times running** (#166). A missed entry means the
feature works from the repo and is absent from the deployed CLI — a failure that looks like
success.

- [ ] **Step 1: Add the new scripts to the deploy list**

Add `diff-apply-lib.ps1` and `test-diff-apply-lib.ps1` to the deploy list in
`scripts/bootstrap.ps1`, matching the surrounding style exactly. Read the list first and
confirm whether test scripts are deployed — if sibling `test-*.ps1` files are not in the
list, do not add ours either; match the established convention rather than guessing.

- [ ] **Step 2: Verify the deploy is complete**

```
pwsh -NoProfile -File scripts/bootstrap.ps1
```

Then prove repo and deployed copies match — compare `Get-FileHash` for every `scripts/*.ps1`
in the repo against `~/.claude/scripts/`, and report any file present in one and not the
other. Do not claim byte-identical without showing the comparison output.

- [ ] **Step 3: Write `docs/diff-apply.md`**

Cover: what the path does and why (link the spec and d103); the exact edit-block grammar
with a worked example; the fleet-row opt-in snippet, using **placeholder names only**:

```yaml
# in ~/.baton/fleet.yaml, on a text-transport provider row
diff_apply: true
diff_apply_limits:
  max_context_bytes: 24000
  max_files: 4
  max_blocks: 8
```

Then: what each safety rejection means and how to read it; where observations land
(`~/.baton/diff-apply-observations.jsonl`) and what question they answer — the correct task
size is unknown and is being measured, not assumed.

State plainly that the envelope defaults are provisional.

- [ ] **Step 4: Update `docs/agent-handoffs.md`**

One short paragraph in the appropriate existing section: text-transport providers can now
take edit tasks when opted in; the oracle and frozen contract are unchanged and remain the
sole authorities.

There is no formal fleet-schema document in this repo — the `agentic` field is documented
only at `docs/agent-handoffs.md:66`. Document `diff_apply` in the same place, so the two
edit-eligibility fields are described together rather than one being discoverable and the
other folklore.

Two specifics that must appear (both surfaced by Task 5's implementer):

- **The opt-in is strictly `diff_apply: true` (boolean).** The check uses `-ne $true`, the
  same shape as `enabled`, so a *quoted* `'true'` in YAML does **not** opt in. That is
  fail-closed and therefore safe, but it is a sharp edge and silent — say so explicitly.
- **Do not set `diff_apply` on a provider row until Task 6 has shipped.** Between Task 5
  and Task 6 the provider is eligible but there is no dispatch branch, so it would be
  routed down the agentic path and fail proof-by-diff. Once Task 6 is merged this note can
  be dropped; while the branch is unmerged it matters.

- [ ] **Step 5: Commit**

```
git add scripts/bootstrap.ps1 docs/diff-apply.md docs/agent-handoffs.md
git commit -m "docs(diff-apply): deploy list, operator guide, handoff note (d103)"
```

---

## Self-review notes

- **Spec coverage:** edit format → T1/T2; safety invariants → T2; predicates and the #168
  floor → T5; context envelope → T3; observation record → T4; dispatch integration → T6;
  deployment → T7. Every spec section maps to a task.
- **The two invariants most likely to be broken by a careless implementer:**
  `Test-ProviderAgentic` must not change (guarded by A9/A10 and
  `test-instrument-abi.ps1`), and the applier must be all-or-nothing (guarded by A5 and E4–E6
  asserting byte-identity, not just a failure verdict).
- **Not built here, on purpose:** automatic task splitting. This plan measures where the
  envelope bites; teaching the planner to atomize should be driven by that data rather than
  guessed now.
