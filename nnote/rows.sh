#!/bin/zsh
# Row-level change check for the Notes database. Read-only.
#   rows.sh snap <file>   save one line per object and per note body
#   rows.sh diff <file>   show rows added, removed or changed since that snapshot
set -euo pipefail
DB="$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"

snap() {
  sqlite3 -readonly -separator '|' "$DB" "
    SELECT 'obj', o.Z_PK, e.Z_NAME, o.Z_OPT, coalesce(o.ZMODIFICATIONDATE1, ''),
           substr(coalesce(o.ZTITLE1, o.ZTITLE2, o.ZTITLE, o.ZNAME, o.ZALTTEXT, o.ZTYPEUTI, o.ZTYPEUTI1, ''), 1, 40)
    FROM ZICCLOUDSYNCINGOBJECT o LEFT JOIN Z_PRIMARYKEY e ON e.Z_ENT = o.Z_ENT
    UNION ALL
    SELECT 'body', d.ZNOTE, 'ICNoteData', length(d.ZDATA), lower(hex(substr(d.ZDATA, -16))), ''
    FROM ZICNOTEDATA d
    ORDER BY 1, 2;"
}

case "${1:-}" in
  snap) snap > "$2"; echo "snapshot: $(wc -l < "$2" | tr -d ' ') rows -> $2" ;;
  diff)
    now=$(mktemp)
    snap > "$now"
    # Lines only in the old snapshot start with "-", only in the new one with "+".
    changes=$(diff <(sort "$2") <(sort "$now") | grep -E '^[<>]' | sed -e 's/^</-/' -e 's/^>/+/' || true)
    echo "${changes:-no changes}"
    rm -f "$now" ;;
  *) echo "usage: rows.sh snap|diff <file>" >&2; exit 2 ;;
esac
