#!/usr/bin/env bash
# Baton test-gate -- invoked by scripts/hooks/test-gate.py on a Stop event.
#
# Contract: exit 0 => the agent may finish; non-zero => it is blocked and this
# script's output tail is shown to it.
#
# Scope: only gates when a file under scripts/ changed vs the working tree's
# last commit. Other trees (docs/, dashboard/, references/) are not covered by
# the .ps1 suites, so a change confined to them leaves the gate open. For each
# changed script it runs only the matching test-*.ps1 suite(s) via
# scripts/test-all.ps1 -Filter; a changed script with no suite of its own does
# not block. Written for bash 3.2 (macOS system bash) -- no mapfile / assoc arrays.
set -u

cd "$(dirname "$0")/.." || exit 0                 # repo root; fail open
command -v pwsh >/dev/null 2>&1 || exit 0         # no pwsh -> fail open

# Changed paths under scripts/ (staged, unstaged, untracked). Strip the porcelain
# "XY " prefix and any rename "old -> new" arrow.
changed=$(git status --porcelain -- scripts/ 2>/dev/null | sed 's/^...//' | sed 's/.* -> //')
[ -z "$changed" ] && exit 0

# Resolve each changed script to the test suite(s) that cover it. A changed
# script with no matching suite file is skipped, so a new lib without a test yet
# never wedges the gate.
suites=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    base=$(basename "$f"); base=${base%.ps1}
    case "$base" in
        test-*) pat="$base" ;;
        *-lib)  pat="test-${base%-lib}" ;;
        *)      pat="test-$base" ;;
    esac
    for s in scripts/${pat}*.ps1; do
        [ -e "$s" ] || continue
        sb=$(basename "$s")
        case " $suites " in *" $sb "*) ;; *) suites="$suites $sb" ;; esac
    done
done <<EOF
$changed
EOF

[ -z "$suites" ] && exit 0                        # nothing testable changed

rc=0
for sb in $suites; do
    echo "== test-gate: scripts/test-all.ps1 -Filter '$sb'"
    pwsh -NoProfile -File scripts/test-all.ps1 -Filter "$sb" -TimeoutSeconds 120 || rc=1
done
exit $rc
