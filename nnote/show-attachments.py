"""Print only the attachment entries from `nnote read` JSON on stdin."""
import json
import sys

note = json.load(sys.stdin)
print(f"{note['title'][:30]!r} ({note['account']})")
for p in note["paragraphs"]:
    for a in p.get("attachments", []):
        a = dict(a)
        if "rows" in a:
            a["rows"] = f"{len(a['rows'])} rows x {len(a['rows'][0]) if a['rows'] else 0} cols, first row {a['rows'][0][:3] if a['rows'] else []}"
        print(f"  para {p['index']} [{p['style']}]: {a}")
