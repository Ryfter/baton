# Hooks + MCP review — 2026-09-03

Review notes for the hooks / MCP hardening batch. The earlier Grok and Opus
review passes were not committed to the repo; this file starts with the
verification pass over their fixes and carries the still-open items forward.

---

## Verification pass — `43596ab..fa703f6` (Opus 5, 2026-09-03)

Scope: confirm the 4 commits `9ab8382`, `bdec01b`, `92f6782`, `fa703f6`
actually implement what they claim, flag regressions, and re-check the
deferred Grok findings. Verification only — no code changed.

### What checks out

Everything the batch claims is present and correct:

| Claim | Verified |
| --- | --- |
| `.mcp.json` launches via `uv run --with …` (`9ab8382`) | ✅ `.mcp.json:4-14`, no `env` block, bootstrap resolves `CLAUDE_PLUGIN_ROOT` then the plugin cache |
| rm-rf-guard catches wrappers / quoting / case (`bdec01b`) | ✅ `python3 scripts/hooks/test_rm_rf_guard.py` → **58/58 passed**, exit 0 |
| hooks.json wires both hooks (`92f6782`) | ✅ `hooks/hooks.json:56-60` (PreToolUse:Bash), `:96-100` (Stop, `timeout: 600`) |
| `.claude/test-gate.sh` is executable | ✅ mode `100755` in the index |
| bridge: `stdin=DEVNULL`, `start_new_session`, `killpg`, bounded drain (`fa703f6`) | ✅ `baton_mcp/bridge.py:66,72,34,79-86` |
| killpg-by-pid assumption | ✅ `run_op` has exactly one `Popen` (`bridge.py:64`) and it carries `start_new_session` on POSIX, so `pid == pgid` holds |
| pwsh-guard: 60s timeout, `errors="replace"`, absolute fail-open | ✅ `scripts/hooks/pwsh-guard.py:29,60,62-67,73-77,84-89` |
| test-gate.py: timeout now **blocks**, `BASH` on darwin, `RUN_TIMEOUT` 540 | ✅ `scripts/hooks/test-gate.py:32,34,64-74` — direction is fail-**closed**, as claimed |
| test-gate.sh: `git status -z` + BRE sed, never selects `test-all.ps1` | ✅ verified with a `pwsh` stub: a change to `scripts/officers-lib.ps1` selects `test-officers-lib.ps1`; a change to `scripts/test-all.ps1` selects nothing |
| test_bridge.py mocks `os.killpg` and asserts `killpg(pid, SIGKILL)` | ✅ `baton_mcp/tests/test_bridge.py:176,236,306-314` |

**bash 3.2 / BSD sed:** `test-gate.sh:24-25` uses only POSIX BRE
(`\(…\)`, `\1`, `[ ]`) — no GNU extensions — and the `while … done <<EOF`
heredoc (not a pipe) keeps `$suites` in the current shell, which is the
correct bash 3.2-safe pattern. `$changed` is expanded once, so a path
containing `$(…)` is not re-evaluated. Portable as written. (Only GNU
sed 4.9 was available here; the BSD claim is by inspection, not execution.)

**Test runs**

- `python3 scripts/hooks/test_rm_rf_guard.py` → **58/58 passed**, exit 0.
- `uv run --with pytest --with 'mcp>=1.25,<2' --with numpy --with httpx
  python -m pytest baton_mcp/tests/test_bridge.py baton_mcp/tests/test_server.py -q`
  → **32 passed**. (With the `--with` list from the review prompt, which
  omits `numpy`/`httpx`, 2 `test_server.py` tests fail on
  `ModuleNotFoundError: numpy` — an artifact of the truncated command, not
  a code defect.)
- `baton_mcp/tests/test_e2e_stdio.py` → **2 skipped** (`pwsh` absent). See M2.
- **Skipped for lack of `pwsh`:** the e2e stdio round-trip, the `.mcp.json`
  bootstrap launch, and every `scripts/test-*.ps1` suite. `test-gate.sh`
  exits 0 at its `command -v pwsh` check on this box, so its `pwsh`
  invocation path was exercised with a stub only.

### Findings

#### H1 — `find -exec <wrapper> rm -rf` bypasses the guard entirely

`scripts/hooks/rm-rf-guard.py:131-135`

The `-exec` scan requires `rm` to be the *literal next token*
(`_is_rm(tokens[j + 1])`). The wrapper-stripping loop at `:100-126` runs
only against the segment head, so every wrapper the module docstring
promises to handle works at the head and fails after `-exec`:

```
find . -exec sudo rm -rf {} +                        -> ALLOWED
find . -exec env rm -rf {} +                         -> ALLOWED
find . -exec timeout 5 rm -rf {} +                   -> ALLOWED
find . -exec sh -c "rm -rf /tmp/x" \;                -> ALLOWED
find . -type d -name node_modules \
     -exec sh -c 'rm -rf "$1"' _ {} \;               -> ALLOWED
```

The last form is the idiomatic way to delete matched directories and is
exactly what an agent is likely to write. `find … -exec rm -rf {} +` (the
bare form, in the probe table) *is* blocked, which makes the gap easy to
miss. Failure scenario: the agent writes the idiomatic `sh -c` form, the
guard returns exit 0, and the recursive delete runs unattended.

Fix shape: factor the head-of-segment wrapper strip into a helper and run
the token slice after `-exec`/`-execdir` through it before `_is_rm`.

#### M1 — Privilege / session wrappers missing from `_WRAPPERS`

`scripts/hooks/rm-rf-guard.py:38-43`

```
setsid rm -rf /tmp/x     -> ALLOWED
doas rm -rf /tmp/x       -> ALLOWED
unshare rm -rf /tmp/x    -> ALLOWED
chroot / rm -rf /tmp/x   -> ALLOWED
ssh host rm -rf /tmp/x   -> ALLOWED
```

`doas` is the direct OpenBSD analogue of `sudo`, which *is* covered, so the
omission is asymmetric. `nsenter` and `parallel` are in the same family.
`ssh host rm -rf …` is remote rather than local, but it is still an
unattended recursive-force delete initiated by the agent.

Out of scope but worth recording: `echo "rm -rf /tmp/x" | bash` is allowed,
because the pipe splits the segment and the `echo` head is benign. Catching
that needs a different model than token scanning — not proposed here.

#### M2 — The `.mcp.json` spawnability regression test cannot fire without `pwsh`

`baton_mcp/tests/test_e2e_stdio.py:24-27` vs `:173-179`

`fa703f6` correctly stopped substituting `sys.executable` for `.mcp.json`'s
`command` and made a non-spawnable command `pytest.fail`. But the
module-level `pytestmark` skips *the whole file* when `pwsh` is missing, so
`test_mcp_json_bootstrap_launch` — including the `shutil.which(cmd)` check —
never runs there. Confirmed on this box: `2 skipped`.

Failure scenario: this is precisely how `command: "python"` shipped green.
On a CI runner or a fresh clone without `pwsh`, a `.mcp.json` whose
`command` is not on PATH still passes the suite. The spawnability assertion
does not need `pwsh` and should be its own test outside the module gate;
only the tool-call assertions need the bridge.

#### M3 — test-gate.sh misses a new `.ps1` inside a new untracked directory

`.claude/test-gate.sh:23-25`

`git status -z` collapses an untracked directory to a single entry, so a new
`scripts/newdir/foo-lib.ps1` is reported as `?? scripts/newdir/`. The sed
filter requires `\.ps1$`, so it matches nothing and the gate exits 0.
Verified: creating `scripts/newdir/foo-lib.ps1` yields `?? scripts/newdir/`
and the gate opens.

Failure scenario: a new library plus its new suite land in a fresh
subdirectory and the Stop gate never runs them. `git status -z -uall`
closes it.

#### M4 — Per-suite budget can exceed the gate's own timeout, which now fails closed

`.claude/test-gate.sh:49-52`, `scripts/hooks/test-gate.py:32`

Each selected suite gets `-TimeoutSeconds 120` and they run sequentially,
while `RUN_TIMEOUT` is 540 (`hooks.json` allows 600). Five or more selected
suites can therefore exceed the Python-side budget.

This was harmless while the timeout path returned 0; `fa703f6` deliberately
flipped it to **block**, so the same overrun now blocks the agent from
finishing with "did not finish within 540s" — a message that points at the
suite, not at the budget arithmetic. It blocks once (the `stop_hook_active`
short-circuit at `test-gate.py:51-52` is correct and ordered first), so this
is a friction/diagnosability problem rather than a wedge. The fail-closed
direction itself is right and should stay.

#### L1 — pwsh-guard now discards hook stdout on *any* non-zero exit (behaviour change)

`scripts/hooks/pwsh-guard.py:73-77`

`fa703f6` widened `if p.returncode in (126, 127)` to `if p.returncode != 0`
and changed `return p.returncode` to `return 0`. The fail-open intent is
right, but the new branch returns *before* the `sys.stdout.write(p.stdout)`
at `:79-80`, so a hook that produced good output and then exited non-zero
now has that output silently dropped, where it previously passed through.

`decision-detect.ps1:4` sets `$ErrorActionPreference = "Stop"`, so a
terminating error after it has already written its payload yields rc=1 and
the payload is discarded. All wrapped hooks document "always exits 0", so
this is within contract — but for `SessionStart` hooks the dropped stdout is
injected context, and its loss is invisible apart from a line in
`~/.baton/logs/hook-guard.log`. Emitting stdout before the rc check would
keep fail-open without the data loss.

#### L2 — Drain-timeout path leaves the child unreaped

`baton_mcp/bridge.py:79-86`

When the 5s drain also times out, the stream objects are closed but the
process is never waited on, leaving a zombie for the life of the MCP server.
On win32 (`start_new_session` is False and `communicate` uses reader
threads) closing the pipes from the main thread while those threads are
mid-`read()` can also raise inside them. Both are bounded and only reachable
after a `killpg`/`taskkill` has already failed — noted for completeness.

#### L3 — rm-rf-guard false positive on a quoted `rm -rf` inside `bash -c`

`scripts/hooks/rm-rf-guard.py:107-120`

```
bash -c "echo rm -rf /tmp/x"   -> BLOCKED
```

The flag-skip lookahead steps over `-c` and `echo` and lands on `rm`. For a
safety guard, over-blocking is the correct failure direction, and the probe
table's plain `echo rm -rf /tmp/x` and `echo 'sudo rm -fr /var/data'` rows
both pass. Recorded so it is not mistaken for a new bug later.

### Deferred items — status on `master`

All three are **genuinely still present**.

**Grok #5 — `.mcp.json` has no fallback if `uv` is missing/offline.** Still
present. `.mcp.json:4` is `"command": "uv"` with no alternative. If `uv` is
not on the MCP launcher's PATH the server does not start at all, and the
only test that would notice (`test_mcp_json_bootstrap_launch`) explicitly
`pytest.skip`s for `uv`/`uvx` — reasonable in isolation, but it means the
missing-`uv` case is untested in both directions. First `uv run --with …`
also needs the network unless the cache is warm.

**Grok #17 — `--with` vs `requirements.txt` drift.** The two are **currently
in sync** (`mcp>=1.25,<2`, `numpy`, `httpx` in both `.mcp.json:8-11` and
`requirements.txt:3-5`) — `fa703f6` updated `requirements.txt`. But nothing
enforces it: no test compares them (`test_e2e_stdio.py` reads `.mcp.json`
only for `command`/`args`/`env`; `requirements.txt` is referenced only by
`scripts/bootstrap.ps1`). The risk is latent, not resolved. A few lines
asserting the `--with` values parse to the `requirements.txt` set would
close it.

**Grok #12 — publish-guard `git add` matcher holes.** Still present. Probed
against a scratch repo containing an untracked `leaked.docx`
(`scripts/hooks/publish-guard.py:23-24`):

| Command | Result | |
| --- | --- | --- |
| `git add -A` | BLOCK | ✅ |
| `git add .` | BLOCK | ✅ |
| `git add --all -v` | BLOCK | ✅ |
| `git commit -am x` | BLOCK | ✅ |
| `git -C /path/no-space add -A` | BLOCK | ✅ |
| `git add -- .` | **allow** | ❌ hole |
| `git add -v --all` | **allow** | ❌ hole |
| `git commit --all -m x` | **allow** | ❌ hole |
| `git -C '/path with space' add -A` | **allow** | ❌ hole |
| `echo git add -A` | **BLOCK** | ❌ false positive |

`BLANKET_ADD` anchors its alternatives immediately after `add\s+`, so any
intervening token (`--`, `-v`) escapes it. `COMMIT_ALL` requires
`\s-[a-zA-Z]*a[a-zA-Z]*`, which `--all` cannot satisfy because the character
after `-` is another `-`. For the `-C` case, `(-C\s+\S+\s+)?` stops `\S+` at
the space inside the quoted path, and `DASH_C` separately captures the
truncated `'/path`, which fails `os.path.isdir` and returns 0 at `:81-82` —
so the guard no-ops twice over.

One calibration note on the `git commit --all` row: `git commit -a` stages
modified and deleted *tracked* files only and never adds untracked ones, so
the `COMMIT_ALL` branch cannot actually leak the material the guard exists
to protect. The matcher hole is real, but its impact is lower than the
`git add` holes beside it — the `-C`-with-space and `git add -- .` rows are
the ones worth fixing first.

The `echo git add -A` false positive is the mirror image: `BLANKET_ADD`
searches anywhere in the command string with no check that `git` is at a
statement head, so printing or documenting the command trips the deny. The
rm-rf-guard's segment-splitting approach (`_BOUNDARY` + head-of-segment
scan) already solves this and is the model to copy.
