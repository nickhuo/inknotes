#!/bin/zsh
# Fingerprint every Notes object except one note (default: the smoke-test note),
# so a before/after diff shows whether anything else changed. Read-only.
set -euo pipefail
DB="$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
PK="${1:-21300}"
objects=$(sqlite3 -readonly "$DB" "SELECT Z_PK, Z_ENT, Z_OPT, ZMODIFICATIONDATE1 FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK <> $PK ORDER BY Z_PK;" | md5 -q)
bodies=$(sqlite3 -readonly "$DB" "SELECT ZNOTE, length(ZDATA), hex(ZDATA) FROM ZICNOTEDATA WHERE ZNOTE IS NOT $PK ORDER BY Z_PK;" | md5 -q)
echo "objects: $objects ($(sqlite3 -readonly "$DB" "SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK <> $PK;") rows)"
echo "bodies:  $bodies"
sqlite3 -readonly "$DB" "SELECT 'test note: Z_OPT ' || Z_OPT || ', modified ' || datetime(ZMODIFICATIONDATE1 + 978307200, 'unixepoch', 'localtime') FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = $PK;"
