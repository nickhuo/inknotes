#!/bin/zsh
# Write tests on the On My Mac smoke-test note (21300) and link target (21304).
set -uo pipefail
here=${0:A:h}
N="$here/../nnote"
S=21300
quiet() { "$N" "$@" 2>&1 | grep -v '^CoreData' | python3 -I -c "import json,sys; d=json.load(sys.stdin); print('  ', ' '.join(sys.argv[1:]), '->', d.get('error') or d.get('changed'))" "$@"; }

echo "== pin"
zsh "$here/../step.sh" pin $S --apply | tail -6
echo "== set-style: first line becomes a title"
quiet set-style $S 'NotesShared smoke test' title --apply
echo "== append the formatting lines"
quiet append $S --markdown "$here/highlights.md" --apply
echo "== five highlight colors"
for c in 1 2 3 4 5; do quiet format $S "Highlight color $c" --text "color $c" --highlight $c --apply; done
echo "== bold, italic, underline on parts of one line"
quiet format $S 'Bold italic underline sample' --text Bold --bold --apply
quiet format $S 'Bold italic underline sample' --text italic --italic --apply
quiet format $S 'Bold italic underline sample' --text underline --underline --apply
echo "== paragraph link from the link target note to alpha"
zsh "$here/../step.sh" link 21304 $S --paragraph alpha --apply | tail -8
echo "== drawing with marker ink in a single color"
zsh "$here/../step.sh" draw $S --svg "$here/house.svg" --ink marker --color '#d946ef' --width 300 --apply | tail -6
echo "== result"
"$N" read $S 2>/dev/null | python3 -I "$here/../summarize.py"
