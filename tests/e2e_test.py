"""End-to-end tests: every nnote command, through its JSON interface, on a test store."""

import shutil

import pytest

from conftest import FIXTURES, FOLDER, NNoteError, attachments, paragraph, write_png


def errors(nnote, code: str, *args: str, **kw) -> str:
    with pytest.raises(NNoteError) as e:
        nnote(*args, **kw)
    assert e.value.code == code
    return str(e.value)


# CLI basics


def test_help_version_and_unknown_command(nnote):
    p = nnote.raw("help")
    assert p.returncode == 0 and "nnote: read and edit Apple Notes natively" in p.stdout
    assert nnote("version")["version"]
    errors(nnote, "usage", "frobnicate")


def test_note_references_resolve_to_the_same_note(nnote):
    note = nnote.create("# Reference note\nbody")
    by_id = nnote.read(note["id"])
    by_uri = nnote.read(note["uri"])
    by_pk = nnote.read(note["uri"].rsplit("/p", 1)[1])
    assert by_id == by_uri == by_pk
    errors(nnote, "note_not_found", "read", "99999999")
    errors(nnote, "note_not_found", "read", "00000000-0000-0000-0000-000000000000")


# Folders and finding notes


def test_create_folder_and_subfolder(nnote):
    plan = nnote("create-folder", "Projects")
    assert plan["dry_run"] and plan["plan"]["parent"] is None
    assert "Projects" not in [f["path"] for f in nnote("folders")["folders"]]

    top = nnote("create-folder", "Projects", "--apply")["folder"]
    sub = nnote("create-folder", "Reports", "--parent", "Projects", "--apply")["folder"]
    assert sub["path"] == "Projects/Reports"
    folders = {f["path"]: f for f in nnote("folders")["folders"]}
    assert folders["Projects/Reports"]["parent"] == top["id"]

    errors(nnote, "folder_exists", "create-folder", "Reports", "--parent", "Projects")
    errors(nnote, "bad_name", "create-folder", "a/b")
    errors(nnote, "folder_not_found", "create", "--folder", "Nope/Nowhere", "--markdown", "-", stdin="# x")

    note = nnote("create", "--folder", "Projects/Reports", "--markdown", "-", "--apply", stdin="# In a subfolder")["note"]
    assert note["folder"] == "Projects/Reports"
    found = nnote("find", "In a subfolder")
    assert [n["id"] for n in found["notes"]] == [note["id"]]
    assert nnote("find", "--folder", "Projects/Reports")["total"] == 1


# Building notes from Markdown


@pytest.fixture(scope="module")
def report(nnote, tmp_path_factory):
    """The research-report fixture, with its link target, image and drawing."""
    target = nnote.create("# E2E Target\nalpha\n## Section B\nsection body")
    work = tmp_path_factory.mktemp("report")
    for name in ("report.md", "house.svg"):
        shutil.copy(FIXTURES / name, work / name)
    write_png(work / "sample.png")
    md = str(work / "report.md")

    before = nnote("find")["total"]
    plan = nnote("create", "E2E Report", "--folder", FOLDER, "--markdown", md)
    assert plan["dry_run"] and nnote("find")["total"] == before, "a dry run must not create anything"
    note = nnote("create", "E2E Report", "--folder", FOLDER, "--markdown", md, "--apply")["note"]
    return {"note": note, "target": nnote.read(target), "plan": plan["plan"]}


def test_report_plan_lists_every_block(report):
    kinds = [b["kind"] for b in report["plan"]["blocks"]]
    for kind in ("para", "table", "divider", "url", "file", "drawing"):
        assert kind in kinds
    refs = [r for b in report["plan"]["blocks"] for r in b.get("refs", [])]
    assert {"link": "E2E Target", "paragraph": None} in refs
    assert {"link": "E2E Target", "paragraph": "Section B"} in refs
    assert {"tag": "e2ereport"} in refs


def test_report_paragraph_styles(report):
    note = report["note"]
    assert note["title"] == "E2E Report" and note["folder"] == FOLDER
    assert paragraph(note, "E2E Report")["style"] == "title"
    assert paragraph(note, "Summary")["style"] == "heading"
    assert paragraph(note, "Open questions")["style"] == "subheading"
    assert [paragraph(note, t)["style"] for t in ("First finding", "Second finding", "Third finding")] == ["numbered"] * 3
    nested = paragraph(note, "nested bullet")
    assert nested["style"] == "bullet" and nested["indent"] == 1
    assert paragraph(note, "A quote.")["quote"] == 1
    assert paragraph(note, "Open item")["todo"]["done"] is False
    assert paragraph(note, "Closed item")["todo"]["done"] is True
    assert paragraph(note, "code line 1")["style"] == paragraph(note, "code line 2")["style"] == "monospaced"
    # Every paragraph has its own identity.
    ids = [p["paragraph_id"] for p in note["paragraphs"] if "paragraph_id" in p]
    assert len(ids) == len(set(ids)) == len(note["paragraphs"])


def test_report_inline_formatting(report):
    line = next(p for p in report["note"]["paragraphs"] if p["text"].startswith("Text can be"))
    spans = {f["text"]: f for f in line["formats"]}
    assert spans["bold"]["bold"] and spans["italic"]["italic"] and spans["struck"]["strike"]
    assert spans["highlighted"]["highlight"] == "purple"
    assert spans["minted"]["highlight"] == "mint"
    assert spans["web link"]["link"] == "https://www.apple.com/macos/"
    assert "**" not in line["text"] and "==" not in line["text"]


def test_report_native_objects(report):
    note, target = report["note"], report["target"]
    assert attachments(note, "table")[0]["rows"] == [["Feature", "Status"], ["Tables", "done"]]
    assert len(attachments(note, "dividerline")) == 1
    assert attachments(note, "url")[0]["url"] == "https://www.apple.com/"
    assert attachments(note, "file")[0]["uti"] == "public.png"
    assert attachments(note, "drawing")[0]["uti"] == "com.apple.paper"

    related = next(p for p in note["paragraphs"] if p["text"].startswith("Related:"))
    assert related["text"] == "Related: E2E Target and E2E Target → Section B #e2ereport"
    links = [a for a in related["attachments"] if a["type"] == "link"]
    assert links[0]["target"] == f"applenotes:note/{target['id'].lower()}"
    section = paragraph(target, "Section B")
    assert links[1]["target"].endswith(f"identifier={target['id']}&paragraphID={section['paragraph_id']}")
    assert [a["text"] for a in related["attachments"] if a["type"] == "tag"] == ["#e2ereport"]


def test_report_shows_up_in_backlinks_and_tags(nnote, report):
    back = nnote("backlinks", report["target"]["id"])["backlinks"]
    assert {b["from"]["id"] for b in back} == {report["note"]["id"]}
    assert sorted(b.get("paragraph", {}).get("text", "") for b in back) == ["", "Section B"]
    assert all(b["from_paragraph"]["text"].startswith("Related:") for b in back)
    tags = {t["tag"]: t for t in nnote("tags")["tags"]}
    assert tags["#e2ereport"]["notes"] == 1
    assert [n["id"] for n in nnote("find", "--tag", "e2ereport")["notes"]] == [report["note"]["id"]]


def test_markdown_export(nnote, report):
    md = nnote.markdown(report["note"]["id"])
    for line in ("# E2E Report", "## Summary", "### Open questions", "1. First finding", "  - nested bullet",
                 "> A quote.", "- [ ] Open item", "- [x] Closed item", "```", "code line 1",
                 "| Feature | Status |", "| --- | --- |", "<https://www.apple.com/>"):
        assert line in md.splitlines(), line
    assert "**bold**" in md and "*italic*" in md and "~~struck~~" in md
    assert "==highlighted==" in md and "=={mint}minted==" in md
    assert f"[E2E Target](applenotes:note/{report['target']['id'].lower()})" in md


def test_markdown_round_trip(nnote):
    source = nnote.create("# Round trip\n## Part\nSome **bold** and =={pink}pink== text #roundtrip\n"
                          "- [x] done item\n- open bullet\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n")
    copy = nnote.create(nnote.markdown(source["id"]))

    def shape(note):
        return [(p["style"], p["text"], p.get("todo", {}).get("done"), [f.get("highlight") or f.get("bold") for f in p.get("formats", [])],
                 [(a["type"], a.get("rows")) for a in p.get("attachments", [])]) for p in note["paragraphs"]]

    assert shape(copy) == shape(source)


# Checklists


def test_checklist_check_uncheck_and_add(nnote):
    note = nnote.create("# Todos\n- [ ] a\n- [ ] b\n- [ ] c")
    uuid_b = paragraph(note, "b")["todo"]["uuid"]

    assert nnote("check", note["id"], "b")["dry_run"]
    assert paragraph(nnote.read(note), "b")["todo"]["done"] is False

    done = nnote("check", note["id"], "b", "--apply")
    assert done["changed"] and paragraph(done["note"], "b")["todo"] == {"done": True, "uuid": uuid_b}
    assert nnote("check", note["id"], "b", "--apply")["changed"] is False
    undone = nnote("check", note["id"], "b", "--undo", "--apply")["note"]
    assert paragraph(undone, "b")["todo"] == {"done": False, "uuid": uuid_b}

    after_a = nnote("add-todo", note["id"], "a2", "--after", "a", "--apply")["note"]
    texts = [p["text"] for p in after_a["paragraphs"]]
    assert texts.index("a2") == texts.index("a") + 1
    new = paragraph(after_a, "a2")["todo"]
    assert new["done"] is False and new["uuid"] not in {paragraph(after_a, t)["todo"]["uuid"] for t in "abc"}

    last = nnote("add-todo", note["id"], "z", "--apply")["note"]
    todos = [p["text"] for p in last["paragraphs"] if "todo" in p]
    assert todos[-1] == "z"

    errors(nnote, "not_a_todo", "check", note["id"], "Todos")
    errors(nnote, "paragraph_not_found", "check", note["id"], "nope")
    errors(nnote, "bad_text", "add-todo", note["id"], "two\nlines")


def test_ambiguous_paragraphs_need_an_index(nnote):
    note = nnote.create("# Twins\n- [ ] same\n- [ ] same")
    message = errors(nnote, "ambiguous_paragraph", "check", note["id"], "same")
    assert "1, 2" in message
    result = nnote("check", note["id"], "--index", "2", "--apply")["note"]
    assert [p["todo"]["done"] for p in result["paragraphs"] if "todo" in p] == [False, True]
    errors(nnote, "bad_index", "check", note["id"], "--index", "99")


# Tags, links, tables


def test_add_tag(nnote):
    note = nnote.create("# Tagged\nbody")
    result = nnote("add-tag", note["id"], "#e2etag", "--apply")["note"]
    assert attachments(result, "tag")[0]["text"] == "#e2etag"
    assert {t["tag"]: t["notes"] for t in nnote("tags")["tags"]}["#e2etag"] == 1
    errors(nnote, "bad_tag", "add-tag", note["id"], "two words")


def test_links_paragraph_links_and_backlinks(nnote):
    source = nnote.create("# Link source\nbody")
    target = nnote.create("# Link target\nTarget para\nother")
    linked = nnote("link", source["id"], target["id"], "--apply")["note"]
    assert attachments(linked, "link")[0]["target"] == f"applenotes:note/{target['id'].lower()}"

    para = paragraph(target, "Target para")
    plan = nnote("link", source["id"], target["id"], "--paragraph", "Target para")
    assert plan["dry_run"] and plan["plan"]["target_paragraph"]["paragraph_id"] == para["paragraph_id"]
    linked = nnote("link", source["id"], target["id"], "--paragraph", "Target para", "--apply")["note"]
    assert attachments(linked, "link")[1]["text"] == "Link target → Target para"

    back = nnote("backlinks", target["id"])
    assert back["count"] == 2 and {b["from"]["id"] for b in back["backlinks"]} == {source["id"]}
    assert [b["paragraph"]["text"] for b in back["backlinks"] if "paragraph" in b] == ["Target para"]
    assert nnote("backlinks", source["id"])["count"] == 0
    errors(nnote, "bad_target", "link", source["id"], source["id"])


def test_add_table_from_stdin(nnote):
    note = nnote.create("# Table note\nbody")
    result = nnote("add-table", note["id"], "--tsv", "-", "--apply", stdin="h1\th2\nv1\tv2\n")["note"]
    assert attachments(result, "table")[0]["rows"] == [["h1", "h2"], ["v1", "v2"]]
    errors(nnote, "bad_table", "add-table", note["id"], "--tsv", "-", stdin="\n")


# Styles and formatting


def test_set_style_keeps_paragraph_identity(nnote):
    note = nnote.create("# Styles\nMake me a heading")
    pid = paragraph(note, "Make me a heading")["paragraph_id"]
    heading = paragraph(nnote("set-style", note["id"], "Make me a heading", "heading", "--apply")["note"], "Make me a heading")
    assert heading["style"] == "heading" and heading["paragraph_id"] == pid
    todo = paragraph(nnote("set-style", note["id"], "Make me a heading", "checklist", "--apply")["note"], "Make me a heading")
    assert todo["todo"]["done"] is False and todo["paragraph_id"] == pid
    errors(nnote, "bad_style", "set-style", note["id"], "Make me a heading", "huge")


def test_format_and_plain(nnote):
    note = nnote.create("# Format\nalpha beta gamma delta")
    line = "alpha beta gamma delta"
    nnote("format", note["id"], line, "--text", "beta", "--bold", "--apply")
    nnote("format", note["id"], line, "--text", "gamma", "--italic", "--underline", "--apply")
    nnote("format", note["id"], line, "--text", "delta", "--highlight", "blue", "--strike", "--apply")
    nnote("format", note["id"], line, "--text", "alpha", "--link", "https://example.com/", "--apply")
    spans = {f["text"]: f for f in paragraph(nnote.read(note), line)["formats"]}
    assert spans["beta"] == {"text": "beta", "bold": True}
    assert spans["gamma"] == {"text": "gamma", "italic": True, "underline": True}
    assert spans["delta"] == {"text": "delta", "highlight": "blue", "strike": True}
    assert spans["alpha"] == {"text": "alpha", "link": "https://example.com/"}

    nnote("format", note["id"], line, "--highlight", "3", "--apply")
    assert {f.get("highlight") for f in paragraph(nnote.read(note), line)["formats"]} == {"orange"}
    nnote("format", note["id"], line, "--plain", "--apply")
    assert "formats" not in paragraph(nnote.read(note), line)

    errors(nnote, "bad_highlight", "format", note["id"], line, "--highlight", "red")
    errors(nnote, "text_not_found", "format", note["id"], line, "--text", "omega", "--bold")
    errors(nnote, "usage", "format", note["id"], line)


# Pinning, attachments, drawings


def test_pin_and_unpin(nnote):
    note = nnote.create("# Pin me\nbody")
    assert nnote("pin", note["id"], "--apply")["note"]["pinned"] is True
    assert nnote("pin", note["id"], "--apply")["changed"] is False
    assert note["id"] in [n["id"] for n in nnote("find", "--pinned", "1")["notes"]]
    assert nnote("pin", note["id"], "--undo", "--apply")["note"]["pinned"] is False


def test_attach_file_and_link_card(nnote, tmp_path):
    note = nnote.create("# Attachments\nbody")
    png = write_png(tmp_path / "pic.png")
    result = nnote("attach", note["id"], str(png), "--apply")["note"]
    assert attachments(result, "file")[0]["uti"] == "public.png"
    result = nnote("add-url", note["id"], "https://www.apple.com/", "--apply")["note"]
    assert attachments(result, "url")[0]["url"] == "https://www.apple.com/"
    errors(nnote, "file_not_found", "attach", note["id"], str(tmp_path / "missing.png"))
    errors(nnote, "bad_url", "add-url", note["id"], "not a url")


def test_draw_svg(nnote, tmp_path):
    note = nnote.create("# Drawing\nbody")
    svg = str(FIXTURES / "house.svg")
    plan = nnote("draw", note["id"], "--svg", svg, "--width", "300", "--ink", "marker", "--color", "#d946ef")["plan"]
    assert plan["drawing"]["strokes"] == 7 and plan["drawing"]["size"][0] == 300
    result = nnote("draw", note["id"], "--svg", svg, "--apply")["note"]
    assert attachments(result, "drawing")[0]["uti"] == "com.apple.paper"
    (tmp_path / "empty.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg"></svg>')
    errors(nnote, "bad_svg", "draw", note["id"], "--svg", str(tmp_path / "empty.svg"))


def test_append_markdown(nnote):
    note = nnote.create("# Append\nfirst\nlast")
    result = nnote("append", note["id"], "--markdown", "-", "--after", "first", "--apply",
                   stdin="## Inserted\n- [ ] inserted todo #appended\n")["note"]
    texts = [p["text"] for p in result["paragraphs"]]
    assert texts[texts.index("first") + 1:texts.index("last")] == ["Inserted", "inserted todo #appended"]
    assert paragraph(result, "Inserted")["style"] == "heading"
    errors(nnote, "usage", "append", note["id"], "--markdown", "-", stdin="\n")


# Safety


def test_dry_runs_change_nothing(nnote, tmp_path):
    note = nnote.create("# Dry\n- [ ] item\ntext")
    other = nnote.create("# Dry other\nbody")
    png = write_png(tmp_path / "dry.png")
    before = (nnote.read(note), nnote("find"), nnote("folders"), nnote("tags"))
    for args in (["check", "item"], ["add-todo", "new"], ["add-tag", "drytag"], ["link", other["id"]],
                 ["set-style", "text", "heading"], ["format", "text", "--bold"], ["pin"],
                 ["attach", str(png)], ["add-url", "https://example.com/"], ["draw", "--svg", str(FIXTURES / "house.svg")]):
        assert nnote(args[0], note["id"], *args[1:])["dry_run"], args
    assert nnote("add-table", note["id"], "--tsv", "-", stdin="a\tb")["dry_run"]
    assert nnote("append", note["id"], "--markdown", "-", stdin="more")["dry_run"]
    assert nnote("create-folder", "Dry folder")["dry_run"]
    assert (nnote.read(note), nnote("find"), nnote("folders"), nnote("tags")) == before


def test_writes_are_limited_to_writable_accounts(nnote):
    note = nnote.create("# Guarded\n- [ ] item")
    env = {"NNOTE_WRITABLE_ACCOUNTS": "Nowhere"}
    errors(nnote, "account_not_writable", "check", note["id"], "item", "--apply", env=env)
    errors(nnote, "account_not_writable", "check", note["id"], "item", env=env)
    errors(nnote, "account_not_writable", "create-folder", "Blocked", "--apply", env=env)
    errors(nnote, "account_not_writable", "create", "--folder", FOLDER, "--markdown", "-", stdin="# Blocked", env=env)
    assert nnote("check", note["id"], "item", "--apply", env={"NNOTE_WRITABLE_ACCOUNTS": "on my mac"})["changed"]
