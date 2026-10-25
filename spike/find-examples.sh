#!/bin/zsh
# Find notes that contain a native tag, note link or table, to use as read-only examples.
set -euo pipefail
DB="$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
sqlite3 -readonly -header -column "$DB" "
SELECT a.ZTYPEUTI1 AS uti, COUNT(*) AS n, MIN(a.ZNOTE1) AS example_note_pk
FROM ZICCLOUDSYNCINGOBJECT a
WHERE a.ZTYPEUTI1 LIKE 'com.apple.notes.inlinetextattachment.%'
GROUP BY a.ZTYPEUTI1;
SELECT a.ZTYPEUTI AS uti, COUNT(*) AS n, MIN(a.ZNOTE) AS example_note_pk
FROM ZICCLOUDSYNCINGOBJECT a
WHERE a.ZTYPEUTI = 'com.apple.notes.table'
GROUP BY a.ZTYPEUTI;"
