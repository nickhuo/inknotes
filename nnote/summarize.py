"""Summarize `nnote` JSON output on stdin: the result, then one line per paragraph."""
import json
import sys

raw = sys.stdin.read()
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print(raw.strip())
    sys.exit(0)
if "error" in d:
    print(f"ERROR {d['error']}: {d['message']}")
    sys.exit(0)
if "paragraphs" in d:  # plain `read` output
    note = d
    print(f"{d['title']!r} ({d['account']} / {d['folder']}), modified {d['modified']}")
else:
    note = d.get("note", {})
    print("dry run" if d.get("dry_run") else f"changed: {d.get('changed')}")
for p in note.get("paragraphs", []):
    extra = ""
    if "todo" in p:
        extra = " [x]" if p["todo"]["done"] else " [ ]"
    for a in p.get("attachments", []):
        a = {k: v for k, v in a.items() if k in ("type", "text", "target", "rows")}
        extra += f" {a}"
    print(f"  {p['index']:>2} {p['style']:<9} {p['text']!r}{extra}")
