"""Check details of the report note: `nnote read <report>` JSON on stdin, smoke-test note JSON in argv[1]."""
import json
import sys

report = json.load(sys.stdin)
smoke = json.load(open(sys.argv[1]))
paras = report["paragraphs"]
for p in paras:
    keys = {k: p[k] for k in ("indent", "quote", "formats") if k in p}
    if keys:
        print(f"para {p['index']} {p['style']} {p['text'][:40]!r}: {keys}")
alpha = next(p for p in smoke["paragraphs"] if p["text"] == "alpha")
link = next(a for p in paras for a in p.get("attachments", []) if "paragraphID" in a.get("target", ""))
print("alpha paragraph_id:", alpha.get("paragraph_id"))
print("link points at:    ", link["target"].split("paragraphID=")[1])
for p in paras:
    for a in p.get("attachments", []):
        if a["type"] in ("url", "file", "drawing"):
            print(a["type"], {k: v for k, v in a.items() if k != "type"})
