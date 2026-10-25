#!/bin/zsh
# One write test: snapshot rows, run nnote with the given arguments, summarize, diff rows.
# Usage: step.sh <nnote args...>
set -uo pipefail
here=${0:A:h}
snapfile=$(mktemp)
zsh "$here/rows.sh" snap "$snapfile" >/dev/null
echo "\$ nnote $*"
"$here/nnote" "$@" 2>&1 | grep -v '^CoreData' | python3 -I "$here/summarize.py"
echo "row changes:"
zsh "$here/rows.sh" diff "$snapfile"
rm -f "$snapfile"
