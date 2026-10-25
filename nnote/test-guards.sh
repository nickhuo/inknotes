#!/bin/zsh
# Negative and edge-case tests for nnote. Only the uncheck step writes (to the test note).
set -uo pipefail
here=${0:A:h}
N="$here/nnote"
run() { echo "\$ nnote $*"; "$N" "$@" 2>&1 | grep -v '^CoreData' | python3 -I "$here/summarize.py" | head -3; echo "  exit=${pipestatus[1]}"; }

echo "== iCloud note is refused, even as a dry run"
run check 13 anything
echo "== unknown paragraph"
run check 21300 nope
echo "== not a to-do"
run check 21300 '#nnotetest'
echo "== already done"
run check 21300 beta --apply
echo "== tag with a space"
run add-tag 21300 'two words'
echo "== link to itself"
run link 21300 21300
echo "== unknown note"
run read 99999999
echo "== uncheck gamma (writes)"
zsh "$here/step.sh" check 21300 gamma --undo --apply
