#!/bin/zsh
# Take a consistent snapshot of Apple Notes' NoteStore.sqlite (WAL included)
# into ~/Downloads, then verify it. Opens the live store read-only.
# Needs Full Disk Access for the process running it.
set -euo pipefail

SRC="$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
DST="$HOME/Downloads/NoteStore-backup-$(date +%Y%m%d-%H%M%S).sqlite"

[[ -r "$SRC" ]] || { echo "cannot read $SRC (Full Disk Access?)" >&2; exit 1; }
[[ -e "$DST" ]] && { echo "refusing to overwrite $DST" >&2; exit 1; }

sqlite3 -readonly "$SRC" ".backup '$DST'"
# The copy inherits WAL mode; make it one self-contained file.
sqlite3 "$DST" 'PRAGMA journal_mode=DELETE;' >/dev/null

echo "backup:    $DST ($(du -h "$DST" | cut -f1))"
echo "integrity: $(sqlite3 "$DST" 'PRAGMA integrity_check;')"

# Row counts must match between the live store and the snapshot.
q="SELECT (SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT) || ' objects, ' || (SELECT COUNT(*) FROM ZICNOTEDATA) || ' note bodies';"
src_counts=$(sqlite3 -readonly "$SRC" "$q")
dst_counts=$(sqlite3 "$DST" "$q")
echo "live:      $src_counts"
echo "snapshot:  $dst_counts"
[[ "$src_counts" == "$dst_counts" ]] && echo "OK: counts match" || echo "WARNING: counts differ (Notes may have written in between)"
