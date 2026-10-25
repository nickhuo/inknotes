#!/bin/zsh
# Rows that changed since a snapshot and belong to objects older than the
# On My Mac account (pk < 21296), i.e. iCloud data. Bodies are compared too.
set -uo pipefail
here=${0:A:h}
snap=${1:?usage: icloud-diff.sh <snapshot>}
now=$(mktemp)
zsh "$here/../rows.sh" snap "$now" >/dev/null
changed=$(diff <(sort "$snap") <(sort "$now") | grep -E '^[<>]' | awk -F'|' '$2 + 0 < 21296' || true)
echo "${changed:-no iCloud rows changed}"
echo "($(diff <(sort "$snap") <(sort "$now") | grep -cE '^[<>]') changed lines in total, all others are On My Mac objects)"
rm -f "$now"
