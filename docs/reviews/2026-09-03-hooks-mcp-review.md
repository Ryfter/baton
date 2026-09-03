# Code review — `scripts/hooks/` and `baton_mcp/`

**Date:** 2026-09-03
**Scope:** full review of the files as they stand on `master` (@ `9ab8382`), not just the recent diff.

- `scripts/hooks/` — `publish-guard.py`, `rm-rf-guard.py`, `test-gate.py`, `pwsh-guard.py`, `kb-autoindex.ps1`, `baton-health-canary.ps1`, plus `.claude/test-gate.sh`
- `baton_mcp/` — `server.py`, `bridge.py`, `__main__.py`, `tests/`
- `.mcp.json` and `hooks/hooks.json` as they bear on the above

**Review only — no code under `scripts/` or `baton_mcp/` was changed.**

## Environment and what was actually executed

| Tool | Status |
| --- | --- |
| `python3` 3.x | available |
| `uv` | available at `/root/.local/bin/uv` |
| `bash` | 5.2.21 (**not** macOS 3.2.57 — see caveat) |
| `pwsh` | **absent** |

Executed against the real code:

- The `rm-rf-guard.py` regex + `flags_of()` were imported and driven over 27 crafted commands (bypass and false-positive corpora). Results in F3–F5 are observed, not inferred.
- `.mcp.json`'s bootstrap was spawned verbatim and completed a real MCP `initialize` handshake (1.1 s warm, 2.0 s cold on a purged `UV_CACHE_DIR`, 111 MB of wheels cached).
- `bridge.run_op()`'s timeout path was driven with a real grandchild process (F6). The hang is reproduced, not theorised.
- `python -m pytest baton_mcp/tests -q` was run to confirm the skip behaviour in F8.
- The proposed de-masking tests in F8 were written and run in a **pwsh-less** environment; both pass. They are not committed here (this PR is review-only).

**Not executed:** `pwsh` is absent, so `kb-autoindex.ps1`, `baton-health-canary.ps1`, `scripts/test-all.ps1`, and everything in `.claude/test-gate.sh` past its `command -v pwsh` line were reviewed **by inspection only**. F12 and F13 are read from the source and are flagged as unverified-at-runtime. Likewise, `test-gate.sh` was reasoned about for bash 3.2 but only *run* under bash 5.2; the constructs used (`case`, `${var%suffix}`, heredoc-fed `while read`, unquoted globs) are all 3.2-safe and no `mapfile`/`declare -A` appears, so the stated portability constraint looks met.

---

## Summary

| # | Sev | Where | One-line |
| --- | --- | --- | --- |
| F1 | **Critical** | `hooks/hooks.json` | Neither new hook is wired — both guards are dead code for plugin users |
| F2 | **Critical** | `.claude/test-gate.sh` | Committed mode `100644`; `os.access(X_OK)` is False on every fresh clone → gate inert |
| F3 | **High** | `rm-rf-guard.py:22` | Newline-separated commands bypass the guard entirely |
| F4 | **High** | `rm-rf-guard.py:22` | `/bin/rm`, `\rm`, `env rm`, `(rm …)`, `do rm`, `then rm`, `$(rm …)` all bypass |
| F5 | **High** | `rm-rf-guard.py:25` | `[^;&\|]*` crosses newlines → later lines' flags block benign commands |
| F6 | **High** | `bridge.py:58-59` | Unix timeout path hangs forever when pwsh leaves a grandchild on the pipe |
| F7 | **High** | `.mcp.json:4` | `command: "uv"` reintroduces the PATH fragility that `command: "python"` had |
| F8 | Medium | `test_e2e_stdio.py:24-27` | The pwsh skipmark, not the `sys.executable` swap, is what masked the launch bug |
| F9 | Medium | `test-gate.py:56-59` | Same grandchild-hang class as F6; 180 s vs ~200 s leaves no margin |
| F10 | Medium | `test-gate.sh:20` | Git-quoted and renamed porcelain paths are mis-parsed → suites silently skipped |
| F11 | Medium | `test-gate.sh:16,20` | Gate covers only `scripts/*.ps1`; no pwsh → total no-op. Would not have caught F7 |
| F12 | Medium | `kb-autoindex.ps1:22,27` | Windows-only `\` separator → silent no-op on macOS/Linux |
| F13 | Medium | `baton-health-canary.ps1:44` | Probes a path that does not exist → false CRITICAL every session start |
| F14 | Medium | `.mcp.json:7` | Floating `mcp>=1.25,<2`, no `--python` pin, no lockfile |
| F15 | Medium | `server.py:18` | `_DEFAULT_INDEX_DIR` ignores `BATON_HOME` |
| F16 | Low | `bridge.py:68` | Only `FileNotFoundError` is caught; other `OSError`s escape as exceptions |
| F17 | Low | `bridge.py:65` | Last-line JSON parse tolerates leading chatter only |
| F18 | Low | `publish-guard.py:41` vs `rm-rf-guard.py:61` | Two different deny protocols; publish-guard's stdout JSON is dead on the exit-2 path |
| F19 | Low | `rm-rf-guard.py:70` | Fast path is case-sensitive while the regex is `re.I` |
| F20 | Low | `bridge.py:37` | No `-NonInteractive`; a prompting script blocks until timeout |
| F21 | Low | `.mcp.json:11` | Plugin-cache fallback sorts by mtime, not version |
| F22–F27 | Nit | various | Import-time `main()`, dead reload, unused imports, `filter` shadowing, unreviewable `-c` blob, no `tool_name` check |

---

## Critical

### F1 — Neither new hook is wired; both guards are dead code
`hooks/hooks.json` (whole file) · `scripts/hooks/rm-rf-guard.py:1` · `scripts/hooks/test-gate.py:1`

`hooks/hooks.json` is the plugin's hook manifest. Its `PreToolUse` block wires exactly one hook (`publish-guard.py`), and its `Stop` block wires exactly one (`decision-detect.ps1`). Neither `rm-rf-guard.py` nor `test-gate.py` appears anywhere in it — nor in any other JSON in the repo:

```
$ grep -rn "rm-rf-guard\|test-gate.py" --include=*.json .
(no matches)
```

**Failure scenario.** A user installs the Baton plugin at `1.21.1`, reads the `rm-rf-guard.py` docstring ("blocked unconditionally"), and relies on it. The agent runs `rm -rf build/`. Nothing intercepts it — the hook is never invoked, because nothing in the shipped manifest names it. Same for `test-gate.py`: the Stop event fires `decision-detect.ps1` only, so a red test suite never blocks a finish. Both features are, as shipped, inert.

`test-gate.py:29` says "settings.json wires this hook at ~200", which suggests it is wired in a machine-local `~/.claude/settings.json`. That is not visible in the repo and does not ship to plugin users, so the feature works only on the author's box. This is the highest-value fix in the review: two commits' worth of guard logic currently protects nobody.

**Fix.** Add to `hooks/hooks.json`, matching the existing `python3 "${CLAUDE_PLUGIN_ROOT}/…"` style:

```json
"PreToolUse": [
  { "matcher": "Bash", "hooks": [
      { "type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/publish-guard.py\"" },
      { "type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/rm-rf-guard.py\"" }
  ]}
],
"Stop": [
  { "matcher": "*", "hooks": [
      { "type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/pwsh-guard.py\" \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/decision-detect.ps1\"" },
      { "type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/test-gate.py\"", "timeout": 200 }
  ]}
]
```

Note `test-gate.py` must **not** go behind `pwsh-guard.py` — it is a Python hook, and `pwsh-guard.py` would try to run it under pwsh. Also wire `SubagentStop` if the docstring's promise is meant to hold there.

Add a test that every `scripts/hooks/*.py` is referenced by `hooks/hooks.json`, or is on an explicit opt-out list. That single assertion catches this whole class.

### F2 — `.claude/test-gate.sh` is committed non-executable, so the gate never runs
`.claude/test-gate.sh:1` · gate condition at `scripts/hooks/test-gate.py:52`

```
$ git ls-files -s .claude/test-gate.sh
100644 ae170fbc… 0    .claude/test-gate.sh          # not 100755

$ python3 -c "import os;print(os.access('.claude/test-gate.sh', os.X_OK))"
False
```

`test-gate.py:52` requires `os.path.isfile(script) and os.access(script, os.X_OK)`. The mode bit is `100644` in the index, `core.fileMode` is `true`, so **every fresh clone gets a non-executable script** and the hook takes the `return 0` "project hasn't opted in" path.

**Failure scenario.** Even after F1 is fixed, on a fresh checkout of `master` a developer leaves `scripts/routing-lib.ps1` with failing tests and finishes the turn. `test-gate.py` finds `.claude/test-gate.sh`, sees `X_OK == False`, returns 0, and the agent stops with red tests. The gate has never once fired for anyone who did not manually `chmod +x` after cloning.

This is compounded by the escape hatch documented at `test-gate.py:74` — "drop its +x bit" is the documented *bypass*, and the committed state is permanently in the bypassed position.

**Fix.** `git update-index --chmod=+x .claude/test-gate.sh` and commit. Add a test asserting the mode is `100755` in the index (`git ls-files -s`), because a future `git add` from a Windows checkout can silently drop it again. Consider also relaxing `test-gate.py:52` to `os.path.isfile(script)` alone and treating a non-executable script as opted-in — the file is invoked as `["bash", script]`, so the exec bit is not functionally required, only used as a signal. If the signal is kept, it is worth noting that `os.access(X_OK)` is close to meaningless on Windows, where it returns True for any readable file — so the opt-out is Unix-only.

---

## High

### F3 — Newline-separated commands bypass `rm-rf-guard` entirely
`scripts/hooks/rm-rf-guard.py:22-26`

`RM_SEG` requires `rm` to follow `^`, `[;&|]`, `&&`, `||`, `xargs …`, `-exec `, or `sudo `. The pattern is compiled with `re.I` but **not** `re.M`, so `^` matches only at string start, and `\n` is not in the boundary class. Multi-line scripts are the normal shape of a `Bash` tool call.

**Observed:**

```
PASS   'echo hi\nrm -rf /tmp/x'        # BYPASS — should block
BLOCK  'rm -rf /tmp/x'                 # only the first line is guarded
```

**Failure scenario.** The agent issues a two-line Bash call:

```bash
cd /home/user/baton
rm -rf .git
```

The first line is consumed by `^`; the second `rm` has no qualifying boundary. `finditer` returns no match, `main()` falls through to `sys.exit(0)`, the delete runs. The guard's central promise — "in any segment of a compound command" — does not hold for the single most common way to write a compound command.

**Fix.** Add `re.M` and put `\n` in the boundary class. Better, stop hand-rolling the tokenizer: `shlex.split(cmd, posix=True)` then scan for a token whose `os.path.basename` is `rm`, resetting at each `;`/`&&`/`||`/`|`/newline separator. `shlex` also fixes F4 and F5 in one move, and correctly declines to see `rm` inside a quoted string.

### F4 — Common `rm` spellings bypass the boundary regex
`scripts/hooks/rm-rf-guard.py:22-26`

Every one of these was observed to **PASS** (i.e. not be blocked):

```
/bin/rm -rf /tmp/x                     # absolute path
\rm -rf /tmp/x                         # alias-escape, a documented idiom
env rm -rf /tmp/x
time rm -rf /tmp/x
nohup rm -rf /tmp/x
cd /tmp && (rm -rf x)                  # subshell
for d in a b; do rm -rf $d; done       # after `do`
if true; then rm -rf /tmp/x; fi        # after `then`
$(rm -rf /tmp/x)                       # command substitution
bash -c 'rm -rf /tmp/x'                # nested shell
```

**Failure scenario.** The agent writes the idiomatic cleanup loop `for d in build dist; do rm -rf $d; done`. `;` matches the boundary, `\s*` matches the space, then the pattern needs `rm` but sees `do`. No match, no block, both trees deleted. `\rm -rf` is worse: it is the standard way to defeat an `rm` alias, so it is exactly what a careful shell user types when they mean it.

The docstring claims the guard is unconditional. It is closer to a speed bump against the two or three spellings that were tested.

**Fix.** As F3: tokenize, then match on `basename(token).lstrip('\\') == "rm"` at any command position, where "command position" is "start of input, or immediately after one of `; & | && || ( ) { do then else newline`", and after skipping a known prefix set (`sudo env time nohup command exec xargs nice ionice`). Nested `bash -c '…'` needs a recursive pass on the quoted argument, or an explicit decision to accept that gap and say so in the docstring.

### F5 — Argument capture crosses newlines, causing false-positive blocks
`scripts/hooks/rm-rf-guard.py:25` (`rm\s+([^;&|]*)`) · `flags_of()` at `:35-52`

`[^;&|]` matches `\n`. So the capture for an `rm` on line 1 runs to the end of the *entire* command, and `flags_of()` splits it on whitespace and collects `-r`/`-f` from **unrelated later lines**.

**Observed:**

```
BLOCK  'rm docs/old.md\ngrep -rf patterns.txt src/'      # FALSE POSITIVE
BLOCK  'rm -i one.txt\ncp -rf a b'                       # FALSE POSITIVE
BLOCK  'rm old.txt\nchmod -R 755 dir\nchmod -f x y'      # FALSE POSITIVE
BLOCK  "git commit -m 'cleanup; rm -rf temp handling'"   # FALSE POSITIVE (quoted prose)
```

**Failure scenario.** The agent runs:

```bash
rm docs/old-notes.md
grep -rf patterns.txt src/
```

A single-file, non-recursive, non-forced `rm` plus a `grep`. `flags_of` sees `-rf` from the `grep` line, sets both flags, and the guard denies with `command : rm docs/old-notes.md\ngrep -rf patterns.txt src/` — a "command" that was never typed. The reason text is garbled, so the user is told to hand Kevin a command that does not exist.

The `git commit -m '…; rm -rf …'` case is the same defect from the other side: `;` inside quotes is treated as a separator, so writing *about* `rm -rf` in a commit message is blocked.

Note that F5 and F3/F4 pull in opposite directions and compound each other: the guard is simultaneously too loose (misses real deletes) and too tight (blocks safe ones). That is the signature of regex-over-shell; both disappear under `shlex`.

**Fix.** Terminate the capture at `\n` as well: `([^;&|\n]*)`. That is the one-line patch. The real fix is `shlex.split` per F3, which also stops treating separators inside quotes as separators.

### F6 — `bridge.run_op` hangs forever on timeout (Unix)
`baton_mcp/bridge.py:50-60`, specifically `proc.kill()` at `:58` and the untimed `proc.communicate()` at `:59`

On `TimeoutExpired` the Windows branch does `taskkill /T /F` — the whole tree. The Unix branch does `proc.kill()`, which signals **only the direct `pwsh` child**. If pwsh has spawned a provider CLI that inherited the stdout pipe, that grandchild keeps the pipe open, and the follow-up `proc.communicate()` at `:59` has **no timeout** — it blocks until the pipe closes.

**Reproduced.** Driving `run_op("capabilities", timeout=2)` against a child that spawns a 600 s grandchild and exits:

```
$ timeout 45 python3 …            # run_op called with timeout=2
shell exit=124                    # 124 = the 45 s outer timeout fired;
                                  # run_op never returned
```

**Failure scenario.** `baton_fleet_test` dispatches to a provider whose CLI wedges on a network read. `run_op` is called with `timeout=300`. At 300 s the bridge kills pwsh, then blocks on `communicate()` behind the still-running provider process. FastMCP's stdio loop is awaiting that synchronous call, so **the tool call never returns and the whole MCP server stops answering** — not just this tool. The user sees Baton hang with no error, and the `{"ok": false, "error": "… timed out after 300s"}` envelope at `:60` is never reached.

The existing tests cannot catch this: `_make_popen_timeout` (`test_bridge.py:28-38`) returns `("", "")` from the second `communicate()` immediately, so the drain is mocked away in `test_timeout_expired_returns_ok_false` and `test_timeout_uses_kill_on_non_win32`.

**Fix.** Put the child in its own process group and kill the group, then bound the drain:

```python
proc = subprocess.Popen(cmd, …, start_new_session=(sys.platform != "win32"))
…
except subprocess.TimeoutExpired:
    if sys.platform == "win32":
        subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True)
    else:
        os.killpg(proc.pid, signal.SIGKILL)     # requires start_new_session=True
    try:
        proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    return {"ok": False, "error": f"bridge op '{op}' timed out after {timeout}s"}
```

Add a test that uses a real grandchild rather than a mock — the mock is what hid this.

### F7 — `command: "uv"` reintroduces the PATH fragility it was meant to fix
`.mcp.json:4`

`9ab8382`'s stated reason for abandoning `command: "python"` is that it "isn't on PATH under Claude Code's MCP launcher". `uv` is subject to the *same* constraint, and is more likely to fail it: `uv` installs to `~/.local/bin` or `~/.cargo/bin`, neither of which is on a GUI-launched macOS app's default `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`). `/usr/bin/python3`, by contrast, ships with macOS.

**Measured in this container**, simulating a launcher's minimal PATH:

```
$ env PATH=/usr/bin:/bin python3 -c "import shutil; print(shutil.which('python'), shutil.which('uv'))"
/usr/bin/python None
```

Under a launcher-like PATH the *old* command resolves and the *new* one does not. The fix may be strictly worse on the platform it was written for.

**Failure scenario.** Kevin installs the plugin on a Mac where `uv` is at `~/.local/bin/uv` and launches Claude Code from Spotlight rather than a shell. The MCP launcher `execvp`s `uv`, gets `ENOENT`, and the `baton` server fails to start — the identical symptom `9ab8382` was fixing, with no `python` to fall back to.

**Fix, in order of preference.**
1. Resolve `uv` at install time and write an absolute path into `.mcp.json` (a `scripts/install-mcp.ps1`/`.sh` step), which removes PATH from the equation.
2. Or make the command a small committed shim (`scripts/mcp-launch.sh` / `.cmd`) that searches `~/.local/bin`, `~/.cargo/bin`, `/opt/homebrew/bin`, `/usr/local/bin` before falling back to `PATH`, then `exec`s `uv`. The shim's own path is derivable from `CLAUDE_PLUGIN_ROOT`.
3. At minimum, document the requirement ("`uv` must be on the PATH the desktop app inherits") in the install docs and fail loudly with a readable message rather than a silent non-start.

Whichever is chosen, F8's `shutil.which(command)` assertion should be evaluated under a *minimal* PATH, not the developer's shell PATH — otherwise it will keep passing on the machine where the bug does not reproduce.

---

## Medium

### F8 — The pwsh skipmark, not the `sys.executable` swap, is what masked the launch bug
`baton_mcp/tests/test_e2e_stdio.py:24-27` (module skipmark) and `:171` (the substitution)

The brief identifies `:171` — `command=sys.executable if server["command"] == "python" else server["command"]` — as the reason the `command: "python"` bug shipped green. That is half the story, and now the less important half: with `command` currently `"uv"`, the ternary no longer fires, so the test *does* spawn the real command today. The substitution is now dead code, but it is a trap — if `command` ever reverts to `"python"`, the masking silently returns.

The larger mechanism is the **module-level skipmark at `:24-27`**. It skips *the entire module* when `pwsh` is absent, including `test_mcp_json_bootstrap_launch` — the only test that touches `.mcp.json`'s `command` at all. Observed here:

```
$ python -m pytest baton_mcp/tests -q -rs
SKIPPED [1] baton_mcp/tests/test_e2e_stdio.py:141: pwsh is required for the MCP bridge
SKIPPED [1] baton_mcp/tests/test_e2e_stdio.py:185: pwsh is required for the MCP bridge
```

**Failure scenario.** CI (or any macOS/Linux dev box) has no pwsh. `.mcp.json` is edited to a command that cannot be spawned. The full suite is green — both e2e tests skipped — and the broken launch ships. That is precisely what happened, and it will happen again on the next `.mcp.json` edit regardless of `:171`.

The skipmark is over-broad because it conflates two different dependencies. `initialize` and `list_tools` never reach `bridge.run_op`, so **they need no pwsh at all**; only the `baton_fleet_list` / `baton_capabilities` assertions do.

**Concrete fix — verified.** Split the launch assertion out from under the pwsh guard, keeping a `uv`-specific skip. Written and run in this pwsh-less container: **2 passed**.

```python
def _spec() -> dict:
    return json.loads((REPO / ".mcp.json").read_text(encoding="utf-8"))["mcpServers"]["baton"]


def test_mcp_json_command_is_launchable() -> None:
    """.mcp.json's `command` must resolve on PATH. NOT under the pwsh skipmark."""
    cmd = _spec()["command"]
    assert shutil.which(cmd) is not None, (
        f".mcp.json command {cmd!r} is not on PATH; Claude Code's MCP "
        f"launcher will fail to start the server"
    )


@pytest.mark.skipif(shutil.which(_spec()["command"]) is None,
                    reason="launcher for .mcp.json command not installed")
def test_mcp_json_bootstrap_handshakes(tmp_path: Path) -> None:
    """Spawn the server EXACTLY as .mcp.json says and complete a handshake.
    No pwsh needed: initialize + list_tools never reach the bridge."""
    home = tmp_path / "baton"; home.mkdir()
    names = asyncio.run(_handshake(home))       # command=server["command"], no substitution
    assert "baton_fleet_list" in names
```

Alongside that:

1. **Delete the `sys.executable if … == "python"` ternary at `:171`** and pass `server["command"]` unconditionally. It is now dead and only preserves the trap.
2. **Move the module skipmark off the module** and onto the two tests that genuinely need pwsh (`test_stdio_round_trip`, and the tool-call half of `test_mcp_json_bootstrap_launch`). Keep the existing `uv`/`pwsh` skips — but scoped, so that "no pwsh" no longer means "no launch coverage".
3. Note the caveat from F7: `shutil.which` under the developer's PATH would still have passed for `command: "python"` on a box where `python` exists. To catch the real bug, run the check under a launcher-like PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), or assert the command is an absolute path.

Point 3 is the one that actually closes the original hole; points 1–2 close the "green because skipped" hole.

### F9 — `test-gate.py` can hang past its own hook timeout
`scripts/hooks/test-gate.py:56-59`

Same defect class as F6, from the other direction. `subprocess.run(["bash", script], capture_output=True, timeout=180)` kills only the `bash` child on timeout; `subprocess.run` internally then calls `communicate()` **without a timeout** to drain. `.claude/test-gate.sh:49` spawns `pwsh`, which spawns Pester and whatever the suites launch — all inheriting the pipe.

**Failure scenario.** A `test-*.ps1` suite wedges on a network call. At 180 s the gate kills `bash`; `pwsh` and its children survive and hold stdout open; the drain blocks. The hook overruns the ~200 s harness timeout described at `:29`. The `except Exception: return 0` at `:60-61` never gets the chance to fail open, because the process is stuck inside `subprocess.run`, not raising from it.

**Fix.** Use the `Popen` + `start_new_session` + `killpg` + bounded-drain pattern from F6. The two files should share one helper — `bridge.py` already has most of it, and duplicating the weaker version here is the reuse gap noted in F27.

Secondary: 180 s against a ~200 s harness budget leaves 20 s for the drain and for the gate's own `pwsh` timeout of 120 s per suite (`test-gate.sh:49`), which multiplies across suites. With three changed scripts the inner budget alone is 360 s — well past 180 s — so a multi-suite run reliably hits the outer timeout and fails open. Either cap total inner runtime in `test-gate.sh` or raise `RUN_TIMEOUT` and the hook timeout together.

### F10 — `test-gate.sh` mis-parses quoted and renamed porcelain paths
`.claude/test-gate.sh:20`

```bash
changed=$(git status --porcelain -- scripts/ 2>/dev/null | sed 's/^...//' | sed 's/.* -> //')
```

Two problems, both observed:

```
raw=["scripts/we ird.ps1"]   base=[we ird.ps1"]     # trailing quote survives
raw=[scripts/newdir/]        base=[newdir]          # untracked dir, not its files
```

Git C-quotes any path containing a space, quote, or non-ASCII byte. `sed 's/^...//'` strips the `XY ` prefix but leaves the surrounding `"…"`, so `base` ends with `"` and the glob `scripts/test-we ird.ps1"*.ps1` matches nothing. The suite is silently skipped and the gate passes.

The second `sed 's/.* -> //'` is greedy and unanchored, and runs on **every** line, not only rename lines — a path legitimately containing ` -> ` is truncated to its tail.

Third: `git status --porcelain` collapses untracked directories to a single `scripts/newdir/` entry, so a newly added directory of scripts contributes one basename (`newdir`) and none of its actual files are matched to suites.

**Failure scenario.** A contributor adds `scripts/new helper.ps1` with a matching `scripts/test-new helper.ps1`, and breaks it. The gate resolves `base` to `new helper.ps1"`, finds no suite, `suites` stays empty, `:44` exits 0, and the agent finishes with the suite red — the exact outcome the gate exists to prevent.

**Fix.** Use `-z` and NUL-delimited reads, which sidesteps quoting entirely and is bash-3.2-safe:

```bash
while IFS= read -r -d '' f; do
    …
done < <(git status --porcelain -z -u -- scripts/ 2>/dev/null)
```

Note `-z` changes the rename encoding (two NUL-separated fields rather than ` -> `), so the rename handling needs adjusting alongside. Add `-u`/`--untracked-files=all` so untracked directories expand to files. If process substitution is unwanted (it *is* available in bash 3.2, but the heredoc form is more portable to `sh`), keep the heredoc and just fix the quoting with `git status --porcelain=v1 -z`.

### F11 — Gate scope excludes `baton_mcp/` and no-ops entirely without pwsh
`.claude/test-gate.sh:16` and `:20`

`:16` — `command -v pwsh >/dev/null 2>&1 || exit 0` — means the whole gate is a **no-op on any machine without PowerShell**, which is most Linux boxes and any Mac that has not installed it. `:20` scopes the change detection to `scripts/` only, and the suite mapping at `:30-34` only ever produces `.ps1` suite names.

Consequences, taken together: changes to `baton_mcp/`, `kb/`, `dashboard/`, and `.mcp.json` are **never** gated, even though `baton_mcp/tests/` is a real pytest suite that runs with no pwsh at all. Changes to `scripts/hooks/*.py` are also skipped — `base=${base%.ps1}` leaves `rm-rf-guard.py` intact, so the glob becomes `scripts/test-rm-rf-guard.py*.ps1` and matches nothing.

**Failure scenario.** This review's own subject matter: `9ab8382` changed `.mcp.json`, and `43596ab` and `b95359a` added Python hooks. Under the current gate, all three are outside scope; the gate would have exited 0 at `:21` and blocked nothing. The gate as written could not have caught any of the three bugs it was contemporaneous with.

**Fix.** Add a Python arm that is independent of pwsh, and move the pwsh check to guard only the pwsh arm:

```bash
rc=0
# Python arm — no pwsh required
if ! git diff --quiet HEAD -- baton_mcp/ kb/ 2>/dev/null || \
   [ -n "$(git status --porcelain -- baton_mcp/ kb/ 2>/dev/null)" ]; then
    echo "== test-gate: pytest baton_mcp kb"
    python3 -m pytest baton_mcp kb -q || rc=1
fi
# PowerShell arm — only when pwsh exists
if command -v pwsh >/dev/null 2>&1; then
    …existing suite resolution and loop…
fi
exit $rc
```

This also lets the gate protect the very code reviewed here. Keep the "no suite → don't block" property so a new file without tests never wedges the gate.

### F12 — `kb-autoindex.ps1` uses a Windows-only separator and no-ops on macOS/Linux
`scripts/hooks/kb-autoindex.ps1:22` and `:27` — *inspection only, pwsh unavailable*

```powershell
$knowledgeRoot = [IO.Path]::GetFullPath((Join-Path $HOME '.claude\knowledge')).TrimEnd('\', '/')
…
$rootPrefix = "$knowledgeRoot\"
```

`Join-Path $HOME '.claude\knowledge'` on macOS/Linux yields `/Users/kevin/.claude\knowledge` — the backslash is an ordinary filename character there, not a separator, so `GetFullPath` returns a path to a single directory literally named `.claude\knowledge`. A real touched file resolves to `/Users/kevin/.claude/knowledge/x.md`, which does not start with that prefix, so the `StartsWith` test at `:28` fails and the hook exits 0 at `:29` every time. Line `:27`'s hardcoded `"\"` suffix has the same problem.

**Failure scenario.** On droid (macOS), the agent writes `~/.claude/knowledge/projects/baton/lesson.md`. The PostToolUse hook fires, computes a prefix that can never match, and exits silently. The KB index is never refreshed, and `baton_kb_search` keeps returning stale results with no error anywhere.

This is the same defect `baton-health-canary.ps1:29` was written to detect — the canary scans *settings files* for `/Users/…\segment`, but the bug is in the hook source itself, where the canary does not look.

**Fix.** `Join-Path $HOME '.claude' 'knowledge'` (multi-segment form, correct on both platforms), and build the prefix with `[IO.Path]::DirectorySeparatorChar` rather than a literal `\`. Verify on macOS — this could not be run here.

### F13 — Health canary probes a path that does not exist → false CRITICAL every session
`scripts/hooks/baton-health-canary.ps1:44-47` — *inspection only, pwsh unavailable*

```powershell
$guard = Join-Path $HOME 'dev/Baton/scripts/hooks/_pwsh-guard.ps1'
if (-not (Test-Path -LiteralPath $guard)) {
    $issues.Add("Missing $guard — dead-pwsh fail-open not installed in source.")
}
```

No such file exists in the repo. The guard is `scripts/hooks/pwsh-guard.py` — different name (no leading underscore), different extension (`.py`, and deliberately so: the docstring at `pwsh-guard.py:3-8` explains that a PowerShell guard "dies with the thing it guards"). The canary is checking for a predecessor that was replaced.

```
$ git ls-files | grep -i pwsh-guard
scripts/hooks/pwsh-guard.py
```

It also hardcodes `$HOME/dev/Baton`, which is machine- and case-specific (this checkout is at `/home/user/baton`; on a case-sensitive filesystem `dev/Baton` ≠ `dev/baton`).

**Failure scenario.** Every `SessionStart` on every machine, the canary appends a `CRITICAL` line to `~/.baton/logs/health-canary.log` and writes `BATON HEALTH CRITICAL: Missing …/_pwsh-guard.ps1` to stderr. Because it is unconditional and always wrong, it trains the reader to ignore canary output — which defeats a component whose stated purpose (`:2`) is "visibility". A genuine issue from checks 1 or 2 arrives in the same breath as a permanent false alarm.

**Fix.** Point the probe at `scripts/hooks/pwsh-guard.py`, and locate it relative to `$PSScriptRoot` rather than a hardcoded `$HOME/dev/Baton`:

```powershell
$guard = Join-Path $PSScriptRoot 'pwsh-guard.py'
```

Add a smoke test that runs the canary against a healthy tree and asserts the log line starts with `OK` — the absence of such a test is why a permanently-firing check went unnoticed.

### F14 — `.mcp.json` pins nothing reproducibly
`.mcp.json:5-9`

```json
"run", "--quiet", "--no-project",
"--with", "mcp>=1.25,<2", "--with", "numpy", "--with", "httpx",
```

`mcp>=1.25,<2` floats across the whole 1.x line; `numpy` and `httpx` are entirely unpinned; there is no `--python` pin, so uv selects (or downloads) whatever interpreter it likes; and there is no lockfile.

**Failure scenario.** `mcp` 1.40 ships a regression or a behavioural change in `FastMCP`. uv's resolution cache expires or the user runs on a second machine, uv resolves to 1.40, and the Baton server breaks or misbehaves at next launch with no change to the repo and nothing in `git log` to explain it. The `<2` pin (correctly added for the `mcp.server.fastmcp` removal) shows the team already knows this dependency moves under them; `<2` is not a tight enough fence for that.

Related cost: the measured cold start pulls 111 MB of wheels (2.0 s on this container's link; on a slow connection this is comfortably tens of seconds). Claude Code's MCP startup timeout — `MCP_TIMEOUT`, default 30 s — applies to that first launch, so a first-run-on-a-slow-link failure is plausible.

`numpy` is also worth questioning: it is the largest wheel in the set and is needed only by `kb.search`, which is used by exactly one of the eight tools. Everything else works without it.

**Fix.** Pin exact versions (`mcp==1.25.1`, `numpy==2.x.y`, `httpx==0.28.z`) or, better, commit a `scripts/mcp-requirements.txt` and use `uv run --with-requirements`. Add `--python 3.12` so the interpreter is not a free variable. Document `MCP_TIMEOUT` and a warm-up step (`uv run … python -c "pass"`) in the install docs. Consider dropping `numpy` from the default set and letting `baton_kb_search` return its existing structured `{"ok": false, "error": …}` when the import fails — which `server.py:70-71` already handles gracefully.

### F15 — `baton_kb_search` ignores `BATON_HOME`
`baton_mcp/server.py:18`, used at `:64`

```python
_DEFAULT_INDEX_DIR = Path.home() / ".claude" / "knowledge" / ".index"
```

Every other tool routes through `run_op` → `mcp-bridge.ps1`, which honours `BATON_HOME`. `baton_kb_search` alone hardcodes the real user's home directory, evaluated at **import time**.

**Failure scenario.** `test_e2e_stdio.py:100` sets `BATON_HOME` to a temp fixture dir to isolate the test. If a kb-search assertion is ever added there, it reads the developer's *real* `~/.claude/knowledge/.index` — passing or failing based on machine state rather than the fixture, and reading real KB content inside a test. The same applies to any user who relocates `BATON_HOME`: seven tools follow them, one does not.

**Fix.** Resolve at call time from the same source of truth the bridge uses:

```python
def _index_dir() -> Path:
    base = os.environ.get("BATON_HOME")
    if base:
        return Path(base) / "knowledge" / ".index"
    return Path.home() / ".claude" / "knowledge" / ".index"
```

Confirm the layout against `mcp-bridge.ps1`'s own `BATON_HOME` interpretation before settling on the subpath.

---

## Low

### F16 — `run_op` catches only `FileNotFoundError`
`baton_mcp/bridge.py:68-69`

`except FileNotFoundError` covers "pwsh not installed". It does not cover `PermissionError` (pwsh present but not executable — common after a partial install or a `noexec` mount), `NotADirectoryError` (a stale `BATON_MCP_BRIDGE` pointing through a file), or `OSError: [Errno 8] Exec format error`.

**Failure scenario.** `~/.local/bin/pwsh` exists with mode `644`. `Popen` raises `PermissionError`, which is not caught, propagates out of `run_op`, and surfaces to the MCP client as an unhandled tool exception rather than the `{"ok": false, "error": …}` envelope every other failure path produces. The `finally` still cleans up the temp file, so only the error contract breaks — but it breaks for all seven bridge-backed tools at once.

**Fix.** `except OSError as e: return {"ok": False, "error": f"could not launch pwsh: {e}"}` — `FileNotFoundError` and `PermissionError` are both `OSError` subclasses, so this strictly widens the existing behaviour.

### F17 — Last-line JSON parse only tolerates *leading* chatter
`baton_mcp/bridge.py:65`

```python
return json.loads(out.splitlines()[-1])
```

The docstring at `:3-4` says "we parse the last stdout line so stray lib chatter can't break it". That holds only for chatter emitted *before* the envelope. Anything printed after it — a PowerShell warning, a module's cleanup message, a trailing progress line — makes the last line non-JSON.

**Failure scenario.** A lib emits a deprecation warning to stdout during teardown, after `mcp-bridge.ps1` has written the envelope. `json.loads` raises, and the caller gets `{"ok": false, "error": "bridge output was not JSON: …"}` with a truncated 400-char preview, even though a perfectly good envelope is sitting one line up.

**Fix.** Scan lines in reverse for the first that parses:

```python
for line in reversed(out.splitlines()):
    line = line.strip()
    if line.startswith(("{", "[")):
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            continue
return {"ok": False, "error": f"bridge output was not JSON: {out[:400]}"}
```

### F18 — Two different deny protocols between the two PreToolUse guards
`scripts/hooks/publish-guard.py:35-41` vs `scripts/hooks/rm-rf-guard.py:55-61`

The two `deny()` functions are byte-identical except for the exit code: `publish-guard` exits **2**, `rm-rf-guard` exits **0**.

Both block, but by different mechanisms. Exit 0 with `hookSpecificOutput.permissionDecision == "deny"` is the JSON protocol — the harness reads stdout and shows `permissionDecisionReason`. Exit 2 is the exit-code protocol — the harness shows **stderr** and does not parse stdout as JSON. So `publish-guard`'s carefully constructed JSON on stdout at `:36-39` is dead weight on its own code path; the message the user sees is the `sys.stderr.write` at `:40`. It works, but by accident of the redundant stderr write.

**Failure scenario.** Someone removes the "redundant" `sys.stderr.write` from `publish-guard.deny()` on the reasonable belief that the JSON carries the reason. The guard still blocks, but with an empty explanation — the user is denied with no stated cause.

**Fix.** Pick one protocol and factor `deny()` into a shared `scripts/hooks/_hooklib.py` alongside the identical `read_command`/fail-open scaffolding. Exit 0 + JSON (rm-rf-guard's form) is the more explicit contract. This is the largest single duplication in the hook directory: `deny()`, the stdin-parse-and-fail-open preamble, and the `if __name__` fail-open wrapper are each written twice or three times across `publish-guard.py`, `rm-rf-guard.py`, and `test-gate.py`.

### F19 — Fast path is case-sensitive while the regex is not
`scripts/hooks/rm-rf-guard.py:70`

`if not cmd or "rm" not in cmd: sys.exit(0)` is case-sensitive; `RM_SEG` is compiled `re.I` (`:25`). A command containing only `RM -rf x` short-circuits before the case-insensitive matcher ever runs. Low impact on Linux/macOS (`RM` is not a command), but it means the `re.I` flag is partly unreachable, which is a latent inconsistency on case-insensitive filesystems.

**Fix.** `if not cmd or "rm" not in cmd.lower():` — or drop `re.I`, since a case-insensitive `rm` match is not meaningful on the platforms that matter.

### F20 — No `-NonInteractive` on the pwsh invocation
`baton_mcp/bridge.py:37`

`["pwsh", "-NoProfile", "-File", …]` omits `-NonInteractive`. A lib that hits `Read-Host`, a credential prompt, or a `Confirm` on an unexpected code path will block on stdin — which is a closed pipe here, so behaviour depends on the cmdlet, and the best case is that it stalls until the F6 timeout (which then hangs).

**Fix.** Add `-NonInteractive`. Consider `-NoLogo` too. The same applies to `.claude/test-gate.sh:49`'s `pwsh -NoProfile -File`.

### F21 — Plugin-cache fallback picks by mtime, not version
`.mcp.json:11` (the `sorted(glob.glob(pat), key=os.path.getmtime, reverse=True)` branch)

When `CLAUDE_PLUGIN_ROOT` is unset, the bootstrap globs `~/.claude/plugins/cache/ryfter/baton/*/baton_mcp` and takes the most recently *modified* directory. mtime is not version order: a `pip install -e` touch, an editor save, or a backup restore into an older version's directory makes it the newest, and the bootstrap silently loads the older server.

**Failure scenario.** Both `1.20.0` and `1.21.1` are in the plugin cache. A tool touches a file under `1.20.0`. The next launch without `CLAUDE_PLUGIN_ROOT` loads `1.20.0` — an older tool surface, silently, with no version reported anywhere the user sees.

**Fix.** Sort by parsed version (the directory name), falling back to mtime only on a tie or a parse failure. Given F7's suggestion to resolve paths at install time, this fallback may be removable entirely.

---

## Nits

- **F22** — `baton_mcp/__main__.py:1-3` calls `main()` at import time with no `if __name__ == "__main__"` guard, so merely importing `baton_mcp.__main__` starts a stdio server. It also duplicates `server.py:111-112`. Either add the guard or make `__main__.py` `from baton_mcp.server import main; main()` only under the guard.
- **F23** — `baton_mcp/tests/test_bridge.py:52-64`: the `importlib.reload(bridge_mod)` dance is unnecessary — `bridge_script()` reads `os.environ` at call time (`bridge.py:19`), as `test_unexpanded_template_override_is_ignored` at `:66-78` already demonstrates by *not* reloading. The reload also mutates module state for every later test in the session. Delete it and keep `monkeypatch.setenv` alone.
- **F24** — Unused imports: `test_bridge.py:8,10` (`tempfile`, `patch`), `:6-7` (`os`, `sys` are shadowed by function-local re-imports); `test_server.py:4-7` (`Path`, `MagicMock`, `pytest`). `test_server.py:257-259` has a stray `import importlib` plus two dead comments inside `test_calls_run_search_and_wraps_hits`. `test_e2e_stdio.py:52-67` defines `_TOOLS_YAML` and writes it at `:86`, but no assertion depends on tools.yaml content — either assert on it or drop the fixture.
- **F25** — `baton_mcp/server.py:81` names a parameter `filter`, shadowing the builtin. It becomes the MCP schema field name, so renaming is a surface change; `filter_` with an explicit schema alias would be cleaner if the SDK supports it.
- **F26** — `.mcp.json:11` embeds an 11-line Python program as a single `\n`-escaped JSON string. It cannot be linted, tested, or diffed readably — the F7/F21 defects in it are invisible in review. Since `CLAUDE_PLUGIN_ROOT` is the very thing being discovered, a file cannot be referenced directly; but the `-c` body can be reduced to a two-line locator that `runpy`s a real, testable `scripts/mcp_bootstrap.py` once the root is known.
- **F27** — Duplication worth factoring, beyond F18's `deny()`: `bridge.py:50-60` and `test-gate.py:56-59` are two different-quality implementations of "run a subprocess with a timeout and don't leak children" (see F6/F9); `publish-guard.py:126-132`, `test-gate.py:80-85`, and `rm-rf-guard.py:64-68` are three copies of the fail-open wrapper. `rm-rf-guard.py` also never checks `tool_name` (contrast `publish-guard.py:73`), which is harmless under the `"matcher": "Bash"` wiring proposed in F1 but makes the file's correctness depend on config it does not state.

---

## Suggested order of work

1. **F1 + F2** — wire the hooks and fix the mode bit. Until these land, F3–F5 and F9–F11 are all theoretical: the code does not run.
2. **F7** — decide the launcher story before more is built on `uv`.
3. **F3–F5** — rewrite `rm-rf-guard` detection on `shlex`; all three collapse into that one change.
4. **F6 + F9** — one shared timeout helper with process-group kill and a bounded drain.
5. **F8** — land the de-masking tests so F7's fix is verifiable and cannot silently regress.
6. **F10–F15**, then the Lows.
