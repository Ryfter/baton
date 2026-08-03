# Diff-apply worker path

**Decision:** `d103`. **Spec:** [`docs/superpowers/specs/2026-08-03-diff-apply-worker-path-design.md`](superpowers/specs/2026-08-03-diff-apply-worker-path-design.md).

## What this is, and why

Some providers Baton can dispatch to have no filesystem harness — a plain HTTP
endpoint (`kind: http`) or a stdio-JSON process (`kind: stdio-json`) can only
exchange text. They cannot open, edit, or save a file themselves. Before this
feature, that meant Baton had **no free or local implementer for edit tasks at
any stakes level** — every candidate with hands was a paid, agentic CLI.

The diff-apply worker path gives Baton the hands instead of the model. Baton
reads the relevant files from the worktree, sends their content to the model
as text, the model replies with a small edit-block grammar describing the
change, and Baton parses and applies those blocks to the worktree itself.

Everything downstream of that — the scope oracle, the frozen verification
contract, the rework loop, proof-by-diff — is **completely unchanged**. Those
systems judge the resulting worktree, not who or what produced it. A
diff-apply provider's bad edit is caught by exactly the same gate that catches
a bad edit from a paid frontier agentic model.

## Edit-block grammar

The model must reply using `SEARCH`/`REPLACE` blocks — it quotes the exact
existing text and its replacement; Baton applies the change with an exact,
literal string match (no fuzzy matching, ever). Prose around the blocks is
fine and is ignored.

```
FILE: <repo-relative path>
<<<<<<< SEARCH
<exact existing text>
=======
<replacement text>
>>>>>>> REPLACE
```

Rules:

- A response may contain multiple blocks, in any order; each carries its own
  `FILE:` line, which must be the last non-blank line before `<<<<<<< SEARCH`.
- The marker lines must start at column 0 and match exactly.
- **Empty `SEARCH` section means "create this file"** — the `REPLACE` section
  is the whole file content. If the file already exists, this is an error
  (it prevents an accidental clobber).
- An unterminated or malformed block fails the **whole response**. A block is
  never silently dropped — a dropped edit would look like success and leave a
  half-implemented task.
- Search text matching **zero** times in the target file is an error
  (`search-not-found`). Search text matching **two or more** times is also an
  error (`search-ambiguous`) — Baton does not guess which occurrence was
  meant; the model must quote more surrounding context.
- **Application is all-or-nothing.** Every block in a response is applied to
  an in-memory copy of the file set first; only if every block succeeds does
  anything get written to disk.

### Worked example

Given `src/greet.py` containing:

```python
def greet(name):
    print("Hello, " + name)
```

A model reply of:

```
FILE: src/greet.py
<<<<<<< SEARCH
    print("Hello, " + name)
=======
    print(f"Hello, {name}!")
>>>>>>> REPLACE
```

replaces just that one line. Keep each `SEARCH` section **as small as
possible while still matching only once** — this instruction measurably
changes model behavior. In live probes against a local model, omitting it
caused the model to quote an entire file as a single block; including it
produced minimal, 3-line blocks instead. The same probes exercised a
multi-change edit, a surgical edit inside a ~7 KB / 60-function file, and a
file creation, and all three succeeded on the first attempt.

## Opting a fleet row in

Diff-apply is **off by default**. A text-transport provider (`kind: http` or
`kind: stdio-json`) becomes edit-eligible only when its fleet row opts in
explicitly:

```yaml
# in ~/.baton/fleet.yaml, on a text-transport provider row
diff_apply: true
diff_apply_limits:
  max_context_bytes: 24000
  max_files: 4
  max_blocks: 8
```

`diff_apply_limits` is optional; the values above are also the defaults when
it is omitted.

**The opt-in is a strict boolean check.** The code path is literally
`if ($Provider.diff_apply -ne $true) { return $false }`
(`scripts/fleet-executor-lib.ps1:148`). This means a **quoted** `'true'` in
YAML does **not** opt the row in — it fails the `-ne $true` comparison and the
provider stays non-edit-eligible. This is fail-closed, so it is safe, but it
is also silent: there is no warning if you opt in with the wrong YAML type.
Write `diff_apply: true` unquoted.

> **While this branch (`feat/diff-apply-worker-path`) is unmerged, do not set
> `diff_apply: true` on a real fleet row.** Between the eligibility predicate
> change and the dispatch branch landing, a provider could be routed down the
> wrong code path. Once this branch is merged to main, this caveat no longer
> applies.

This does **not** change agentic eligibility. `Test-ProviderAgentic` is
unmodified and still returns `$false` unconditionally for `http`/`stdio-json`
transports (the d091 transport veto) — a `diff_apply` opt-in grants
*diff-apply* eligibility, never agentic (filesystem-harness) eligibility.
Both are folded together only at the single predicate
(`Test-ProviderEditCapable`) that edit-eligibility call sites now check.

## The size envelope

Baton selects what the model sees: it reads files under the task's
`allowed_paths`, subject to the envelope above (`max_context_bytes`,
`max_files`, `max_blocks`). If a task's context doesn't fit, the provider is
skipped for that task with a specific reason
(`task exceeds diff-apply envelope: N bytes > limit`) and selection falls
through to the next candidate — this is a routing signal, not a failure.
`max_blocks` is enforced on the *response* as well as advertised in the
prompt: a reply carrying more than the cap is refused after parsing and
before anything is applied.
Baton never truncates context to make a task fit; a model shown only part of
a file can produce a `SEARCH` block that matches nothing, or worse, matches
the wrong region.

**These defaults (24000 bytes / 4 files / 8 blocks) are provisional.** The
correct task size for a cheap or local model to handle reliably is genuinely
not known yet — it is deliberately conservative and is being *measured*, not
assumed. Every diff-apply attempt appends one row to the observation record
at `~/.baton/diff-apply-observations.jsonl` (context size, files touched,
blocks emitted/applied, parse and apply results, and the verification verdict
once known). That record is the dataset that will eventually answer "what is
the right envelope" for both local models and cheap paid ones — don't hand-
tune these numbers without it.

## Reading a safety rejection

The scope oracle and the frozen verification contract remain the **sole
authorities** on whether a change is acceptable — nothing in the diff-apply
path weakens or bypasses them. The rejections below are early, cheap checks
that turn what would otherwise be a wasted run into an actionable signal
before the oracle is even invoked:

| Rejection | Meaning |
|---|---|
| `search-not-found` | The quoted `SEARCH` text does not occur in the target file at all — usually stale context (the model saw an older version of the file) or a paraphrase instead of an exact quote. |
| `search-ambiguous` | The quoted `SEARCH` text occurs 2+ times — the model needs to quote more surrounding context to pin down a single match. Occurrences are counted **overlapping**, so `aa` in `aaa` is ambiguous, not unique. |
| `encoding-rejected` | A target file's bytes are not valid UTF-8. The applier round-trips text, so decoding leniently would rewrite the offending bytes as `EF BF BD` and corrupt the file far outside the `SEARCH` region. Baton fails closed and edits nothing. |
| `envelope-exceeded` (too many blocks) | The model emitted more than `max_blocks` blocks. Enforced after parsing and before applying, so the worktree is untouched — an advertised-but-unenforced cap would make the envelope measurements meaningless. |
| a rejected path (`..` segment, absolute/drive/UNC path, empty segment, control character, or a target outside the worktree root) | Path-containment check failed. The model named a file outside the task's worktree; the block is refused before anything is touched. |
| a rejected write through a symlink | The target path's existing file has the `ReparsePoint` attribute — refused because a pure string/path check cannot see through it. |
| a rejected `.git/` write | The path resolves under `.git/`; always refused. |
| `not edit-eligible (no diff_apply opt-in)` | The candidate provider has a text-only transport and no `diff_apply: true` on its fleet row, so it was excluded from the edit pool entirely — this is the exclusion reason string, distinct from a rejection during application. |
| out-of-scope path (allowed_paths) | Failed the same `Test-DiffFilesInAllowedPaths` check the oracle itself uses (`scripts/verification-lib.ps1:573`) — the diff-apply path reuses that matcher rather than reimplementing it. |
| empty response (no blocks) | The model replied with prose only. This is **not** treated as a silent no-op success — it yields an explicit failure with its own reason. |

None of these consume a capability rating when the failure is attributable to
an oversized context (an envelope skip, or a parse/apply failure on a task
that exceeded the envelope) — per the existing precedent that availability
failures are not quality evidence, only failures **inside** the envelope are
evidence about the model itself.
