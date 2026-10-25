#!/bin/zsh
# List Notes objects whose change counter or modification date differs from a backup.
# Usage: changed-since-backup.sh <backup.sqlite>. Read-only.
set -euo pipefail
DB="$HOME/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
BACKUP="${1:?usage: changed-since-backup.sh <backup.sqlite>}"
sqlite3 -readonly -header -column "$DB" "
ATTACH '$BACKUP' AS b;
SELECT o.Z_PK AS pk, e.Z_NAME AS entity, bo.Z_OPT || '->' || o.Z_OPT AS opt,
       datetime(o.ZMODIFICATIONDATE1 + 978307200, 'unixepoch', 'localtime') AS modified,
       substr(coalesce(o.ZTITLE1, o.ZTITLE2, o.ZNAME, ''), 1, 30) AS name
FROM main.ZICCLOUDSYNCINGOBJECT o
JOIN b.ZICCLOUDSYNCINGOBJECT bo ON bo.Z_PK = o.Z_PK
LEFT JOIN main.Z_PRIMARYKEY e ON e.Z_ENT = o.Z_ENT
WHERE bo.Z_OPT IS NOT o.Z_OPT OR bo.ZMODIFICATIONDATE1 IS NOT o.ZMODIFICATIONDATE1
ORDER BY o.Z_PK;"
