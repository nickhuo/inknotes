"""End-to-end tests: every inknotes command, through its JSON interface, on a test store."""

import json
import shutil

import pytest

from conftest import FIXTURES, FOLDER, InkNotesError, attachments, paragraph, write_png


def errors(inknotes, code: str, *args: str, **kw) -> str:
    with pytest.raises(InkNotesError) as e:
        inknotes(*args, **kw)
    assert e.value.code == code
    return str(e.value)


# CLI basics


def test_help_version_and_unknown_command(inknotes):
    p = inknotes.raw("help")
    assert p.returncode == 0 and "Usage: inknotes" in p.stdout
    assert inknotes("version")["version"]
    errors(inknotes, "usage", "frobnicate")


def test_search_truncation_and_parser_forms(inknotes):
    first = inknotes.create("# CLI search first\nunique-cli-needle")
    second = inknotes.create("# CLI search second\nunique-cli-needle")
    limited = inknotes("search", "unique-cli-needle", "--limit=1")
    assert limited["count"] == 1 and limited["truncated"] is True
    assert limited["skipped"] == 0
    complete = inknotes("search", "--limit=2", "--", "unique-cli-needle")
    assert complete["count"] == 2 and complete["truncated"] is False
    assert complete["skipped"] == 0
    assert {n["id"] for n in complete["notes"]} == {first["id"], second["id"]}
    empty = inknotes("search", "unique-cli-no-match")
    assert empty["count"] == 0 and empty["truncated"] is False and empty["skipped"] == 0
    inknotes("pin", first["id"], "--apply")
    for options in [("--pinned",), ("--pinned", "1"), ("--pinned=1",)]:
        assert first["id"] in [n["id"] for n in inknotes("find", "--limit=100", *options)["notes"]]
    dry = inknotes("add-todo", first["id"], "--", "--literal-text")
    assert dry["dry_run"] is True and dry["plan"]["text"] == "--literal-text"


def test_missing_input_error_document_in_container(inknotes, tmp_path):
    note = inknotes.create("# CLI missing file")
    p = inknotes.raw("attach", note["id"], str(tmp_path / "missing.pdf"))
    assert p.returncode == 2 and p.stdout == ""
    doc = next(json.loads(line) for line in p.stderr.splitlines() if line.startswith('{"error"'))
    assert doc["error"] == "file_not_found"
    assert doc["status"] == "action_required" and doc["retryable"] is False


def test_note_references_resolve_to_the_same_note(inknotes):
    note = inknotes.create("# Reference note\nbody")
    by_id = inknotes.read(note["id"])
    by_uri = inknotes.read(note["uri"])
    by_pk = inknotes.read(note["uri"].rsplit("/p", 1)[1])
    assert by_id == by_uri == by_pk
    errors(inknotes, "note_not_found", "read", "99999999")
    errors(inknotes, "note_not_found", "read", "00000000-0000-0000-0000-000000000000")


# Folders and finding notes


def test_create_folder_and_subfolder(inknotes):
    plan = inknotes("create-folder", "Projects")
    assert plan["dry_run"] and plan["plan"]["parent"] is None
    assert "Projects" not in [f["path"] for f in inknotes("folders")["folders"]]

    top = inknotes("create-folder", "Projects", "--apply")["folder"]
    sub = inknotes("create-folder", "Reports", "--parent", "Projects", "--apply")["folder"]
    assert sub["path"] == "Projects/Reports"
    folders = {f["path"]: f for f in inknotes("folders")["folders"]}
    assert folders["Projects/Reports"]["parent"] == top["id"]

    errors(inknotes, "folder_exists", "create-folder", "Reports", "--parent", "Projects")
    errors(inknotes, "bad_name", "create-folder", "a/b")
    errors(inknotes, "folder_not_found", "create", "--folder", "Nope/Nowhere", "--markdown", "-", stdin="# x")

    note = inknotes("create", "--folder", "Projects/Reports", "--markdown", "-", "--apply", stdin="# In a subfolder")["note"]
    assert note["folder"] == "Projects/Reports"
    found = inknotes("find", "In a subfolder")
    assert [n["id"] for n in found["notes"]] == [note["id"]]
    assert inknotes("find", "--folder", "Projects/Reports")["total"] == 1


# Building notes from Markdown


@pytest.fixture(scope="module")
def report(inknotes, tmp_path_factory):
    """The research-report fixture, with its link target and image."""
    target = inknotes.create("# E2E Target\nalpha\n## Section B\nsection body")
    work = tmp_path_factory.mktemp("report")
    shutil.copy(FIXTURES / "report.md", work / "report.md")
    write_png(work / "sample.png")
    md = str(work / "report.md")

    before = inknotes("find")["total"]
    plan = inknotes("create", "E2E Report", "--folder", FOLDER, "--markdown", md)
    assert plan["dry_run"] and inknotes("find")["total"] == before, "a dry run must not create anything"
    note = inknotes("create", "E2E Report", "--folder", FOLDER, "--markdown", md, "--apply")["note"]
    return {"note": note, "target": inknotes.read(target), "plan": plan["plan"]}


def test_report_plan_lists_every_block(report):
    kinds = [b["kind"] for b in report["plan"]["blocks"]]
    for kind in ("para", "table", "divider", "url", "file"):
        assert kind in kinds
    refs = [r for b in report["plan"]["blocks"] for r in b.get("refs", [])]
    assert {"link": "E2E Target", "paragraph": None} in refs
    assert {"link": "E2E Target", "paragraph": "Section B"} in refs
    assert {"tag": "e2ereport"} in refs


def test_report_paragraph_styles(report):
    note = report["note"]
    assert note["title"] == "E2E Report" and note["folder"] == FOLDER
    assert paragraph(note, "E2E Report")["style"] == "title"
    assert paragraph(note, "Here's to the crazy ones")["style"] == "heading"
    assert paragraph(note, "What you can't do")["style"] == "subheading"
    assert [paragraph(note, t)["style"] for t in ("The misfits.", "The rebels.", "The troublemakers.")] == ["numbered"] * 3
    nested = paragraph(note, "The round pegs in the square holes.")
    assert nested["style"] == "bullet" and nested["indent"] == 1
    assert paragraph(note, "Because the people who are crazy enough to think they can change the world, are the ones who do.")["quote"] == 1
    assert paragraph(note, "Ignore them")["todo"]["done"] is False
    assert paragraph(note, "Quote them")["todo"]["done"] is True
    assert paragraph(note, "Think different.")["style"] == paragraph(note, "Apple, 1997")["style"] == "monospaced"
    # Every paragraph has its own identity.
    ids = [p["paragraph_id"] for p in note["paragraphs"] if "paragraph_id" in p]
    assert len(ids) == len(set(ids)) == len(note["paragraphs"])


def test_report_inline_formatting(report):
    paragraphs = report["note"]["paragraphs"]
    spans = {f["text"]: f for p in paragraphs for f in p.get("formats", [])}
    assert spans["The ones who see things differently."]["bold"]
    assert spans["ignore"]["italic"] and spans["the crazy ones"]["strike"]
    for word, color in (("quote", "purple"), ("disagree", "pink"), ("glorify", "orange"),
                        ("genius", "mint"), ("vilify", "blue")):
        assert spans[word]["highlight"] == color
    assert spans["campaign history"]["link"] == "https://en.wikipedia.org/wiki/Think_different"
    assert not any("**" in p["text"] or "==" in p["text"] or "~~" in p["text"] for p in paragraphs)


def test_report_native_objects(report):
    note, target = report["note"], report["target"]
    assert attachments(note, "table")[0]["rows"] == [["Some see", "We see"], ["the crazy ones", "genius"]]
    assert len(attachments(note, "dividerline")) == 1
    assert attachments(note, "url")[0]["url"] == "https://www.apple.com/"
    assert attachments(note, "file")[0]["uti"] == "public.png"

    related = next(p for p in note["paragraphs"] if p["text"].startswith("Related:"))
    assert related["text"] == "Related: E2E Target and E2E Target → Section B #e2ereport"
    links = [a for a in related["attachments"] if a["type"] == "link"]
    assert links[0]["target"] == f"applenotes:note/{target['id'].lower()}"
    section = paragraph(target, "Section B")
    assert links[1]["target"].endswith(f"identifier={target['id']}&paragraphID={section['paragraph_id']}")
    assert [a["text"] for a in related["attachments"] if a["type"] == "tag"] == ["#e2ereport"]


def test_report_shows_up_in_backlinks_and_tags(inknotes, report):
    back = inknotes("backlinks", report["target"]["id"])["backlinks"]
    assert {b["from"]["id"] for b in back} == {report["note"]["id"]}
    assert sorted(b.get("paragraph", {}).get("text", "") for b in back) == ["", "Section B"]
    assert all(b["from_paragraph"]["text"].startswith("Related:") for b in back)
    tags = {t["tag"]: t for t in inknotes("tags")["tags"]}
    assert tags["#e2ereport"]["notes"] == 1
    assert [n["id"] for n in inknotes("find", "--tag", "e2ereport")["notes"]] == [report["note"]["id"]]


def test_markdown_export(inknotes, report):
    md = inknotes.markdown(report["note"]["id"])
    for line in ("# E2E Report", "## Here's to the crazy ones", "### What you can't do", "1. The misfits.",
                 "  - The round pegs in the square holes.", "**The ones who see things differently.**",
                 "> Because the people who are crazy enough to think they can change the world, are the ones who do.",
                 "- [ ] Ignore them", "- [x] Quote them", "```", "Think different.",
                 "| Some see | We see |", "| --- | --- |", "<https://www.apple.com/>"):
        assert line in md.splitlines(), line
    assert "*ignore*" in md and "~~the crazy ones~~" in md and "==quote==" in md
    for word, color in (("disagree", "pink"), ("glorify", "orange"), ("genius", "mint"), ("vilify", "blue")):
        assert f"=={{{color}}}{word}==" in md
    assert f"[E2E Target](applenotes:note/{report['target']['id'].lower()})" in md


def test_markdown_round_trip(inknotes):
    source = inknotes.create("# Round trip\n## Part\nSome **bold** and =={pink}pink== text #roundtrip\n"
                          "- [x] done item\n- open bullet\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n")
    copy = inknotes.create(inknotes.markdown(source["id"]))

    def shape(note):
        return [(p["style"], p["text"], p.get("todo", {}).get("done"), [f.get("highlight") or f.get("bold") for f in p.get("formats", [])],
                 [(a["type"], a.get("rows")) for a in p.get("attachments", [])]) for p in note["paragraphs"]]

    assert shape(copy) == shape(source)


# Checklists


def test_checklist_check_uncheck_and_add(inknotes):
    note = inknotes.create("# Todos\n- [ ] a\n- [ ] b\n- [ ] c")
    uuid_b = paragraph(note, "b")["todo"]["uuid"]

    assert inknotes("check", note["id"], "b")["dry_run"]
    assert paragraph(inknotes.read(note), "b")["todo"]["done"] is False

    done = inknotes("check", note["id"], "b", "--apply")
    assert done["changed"] and paragraph(done["note"], "b")["todo"] == {"done": True, "uuid": uuid_b}
    assert inknotes("check", note["id"], "b", "--apply")["changed"] is False
    undone = inknotes("check", note["id"], "b", "--undo", "--apply")["note"]
    assert paragraph(undone, "b")["todo"] == {"done": False, "uuid": uuid_b}

    after_a = inknotes("add-todo", note["id"], "a2", "--after", "a", "--apply")["note"]
    texts = [p["text"] for p in after_a["paragraphs"]]
    assert texts.index("a2") == texts.index("a") + 1
    new = paragraph(after_a, "a2")["todo"]
    assert new["done"] is False and new["uuid"] not in {paragraph(after_a, t)["todo"]["uuid"] for t in "abc"}

    last = inknotes("add-todo", note["id"], "z", "--apply")["note"]
    todos = [p["text"] for p in last["paragraphs"] if "todo" in p]
    assert todos[-1] == "z"

    errors(inknotes, "not_a_todo", "check", note["id"], "Todos")
    errors(inknotes, "paragraph_not_found", "check", note["id"], "nope")
    errors(inknotes, "bad_text", "add-todo", note["id"], "two\nlines")


def test_ambiguous_paragraphs_need_an_index(inknotes):
    note = inknotes.create("# Twins\n- [ ] same\n- [ ] same")
    message = errors(inknotes, "ambiguous_paragraph", "check", note["id"], "same")
    assert "1, 2" in message
    result = inknotes("check", note["id"], "--index", "2", "--apply")["note"]
    assert [p["todo"]["done"] for p in result["paragraphs"] if "todo" in p] == [False, True]
    errors(inknotes, "bad_index", "check", note["id"], "--index", "99")


# Tags, links, tables


def test_add_tag(inknotes):
    note = inknotes.create("# Tagged\nbody")
    result = inknotes("add-tag", note["id"], "#e2etag", "--apply")["note"]
    assert attachments(result, "tag")[0]["text"] == "#e2etag"
    assert {t["tag"]: t["notes"] for t in inknotes("tags")["tags"]}["#e2etag"] == 1
    errors(inknotes, "bad_tag", "add-tag", note["id"], "two words")


def test_links_paragraph_links_and_backlinks(inknotes):
    source = inknotes.create("# Link source\nbody")
    target = inknotes.create("# Link target\nTarget para\nother")
    linked = inknotes("link", source["id"], target["id"], "--apply")["note"]
    assert attachments(linked, "link")[0]["target"] == f"applenotes:note/{target['id'].lower()}"

    para = paragraph(target, "Target para")
    plan = inknotes("link", source["id"], target["id"], "--paragraph", "Target para")
    assert plan["dry_run"] and plan["plan"]["target_paragraph"]["paragraph_id"] == para["paragraph_id"]
    linked = inknotes("link", source["id"], target["id"], "--paragraph", "Target para", "--apply")["note"]
    assert attachments(linked, "link")[1]["text"] == "Link target → Target para"

    back = inknotes("backlinks", target["id"])
    assert back["count"] == 2 and {b["from"]["id"] for b in back["backlinks"]} == {source["id"]}
    assert [b["paragraph"]["text"] for b in back["backlinks"] if "paragraph" in b] == ["Target para"]
    assert inknotes("backlinks", source["id"])["count"] == 0
    errors(inknotes, "bad_target", "link", source["id"], source["id"])


def test_add_table_from_stdin(inknotes):
    note = inknotes.create("# Table note\nbody")
    result = inknotes("add-table", note["id"], "--tsv", "-", "--apply", stdin="h1\th2\nv1\tv2\n")["note"]
    assert attachments(result, "table")[0]["rows"] == [["h1", "h2"], ["v1", "v2"]]
    errors(inknotes, "bad_table", "add-table", note["id"], "--tsv", "-", stdin="\n")


# Styles and formatting


def test_set_style_keeps_paragraph_identity(inknotes):
    note = inknotes.create("# Styles\nMake me a heading")
    pid = paragraph(note, "Make me a heading")["paragraph_id"]
    heading = paragraph(inknotes("set-style", note["id"], "Make me a heading", "heading", "--apply")["note"], "Make me a heading")
    assert heading["style"] == "heading" and heading["paragraph_id"] == pid
    todo = paragraph(inknotes("set-style", note["id"], "Make me a heading", "checklist", "--apply")["note"], "Make me a heading")
    assert todo["todo"]["done"] is False and todo["paragraph_id"] == pid
    errors(inknotes, "bad_style", "set-style", note["id"], "Make me a heading", "huge")


def test_format_and_plain(inknotes):
    note = inknotes.create("# Format\nalpha beta gamma delta")
    line = "alpha beta gamma delta"
    inknotes("format", note["id"], line, "--text", "beta", "--bold", "--apply")
    inknotes("format", note["id"], line, "--text", "gamma", "--italic", "--underline", "--apply")
    inknotes("format", note["id"], line, "--text", "delta", "--highlight", "blue", "--strike", "--apply")
    inknotes("format", note["id"], line, "--text", "alpha", "--link", "https://example.com/", "--apply")
    spans = {f["text"]: f for f in paragraph(inknotes.read(note), line)["formats"]}
    assert spans["beta"] == {"text": "beta", "bold": True}
    assert spans["gamma"] == {"text": "gamma", "italic": True, "underline": True}
    assert spans["delta"] == {"text": "delta", "highlight": "blue", "strike": True}
    assert spans["alpha"] == {"text": "alpha", "link": "https://example.com/"}

    inknotes("format", note["id"], line, "--highlight", "3", "--apply")
    assert {f.get("highlight") for f in paragraph(inknotes.read(note), line)["formats"]} == {"orange"}
    inknotes("format", note["id"], line, "--plain", "--apply")
    assert "formats" not in paragraph(inknotes.read(note), line)

    errors(inknotes, "bad_highlight", "format", note["id"], line, "--highlight", "red")
    errors(inknotes, "text_not_found", "format", note["id"], line, "--text", "omega", "--bold")
    errors(inknotes, "usage", "format", note["id"], line)


# Pinning and attachments


def test_pin_and_unpin(inknotes):
    note = inknotes.create("# Pin me\nbody")
    assert inknotes("pin", note["id"], "--apply")["note"]["pinned"] is True
    assert inknotes("pin", note["id"], "--apply")["changed"] is False
    assert note["id"] in [n["id"] for n in inknotes("find", "--pinned", "1")["notes"]]
    assert inknotes("pin", note["id"], "--undo", "--apply")["note"]["pinned"] is False


def test_attach_file_and_link_card(inknotes, tmp_path):
    note = inknotes.create("# Attachments\nbody")
    png = write_png(tmp_path / "pic.png")
    result = inknotes("attach", note["id"], str(png), "--apply")["note"]
    assert attachments(result, "file")[0]["uti"] == "public.png"
    result = inknotes("add-url", note["id"], "https://www.apple.com/", "--apply")["note"]
    assert attachments(result, "url")[0]["url"] == "https://www.apple.com/"
    errors(inknotes, "file_not_found", "attach", note["id"], str(tmp_path / "missing.png"))
    errors(inknotes, "bad_url", "add-url", note["id"], "not a url")


def test_append_markdown(inknotes):
    note = inknotes.create("# Append\nfirst\nlast")
    result = inknotes("append", note["id"], "--markdown", "-", "--after", "first", "--apply",
                   stdin="## Inserted\n- [ ] inserted todo #appended\n")["note"]
    texts = [p["text"] for p in result["paragraphs"]]
    assert texts[texts.index("first") + 1:texts.index("last")] == ["Inserted", "inserted todo #appended"]
    assert paragraph(result, "Inserted")["style"] == "heading"
    errors(inknotes, "usage", "append", note["id"], "--markdown", "-", stdin="\n")


# Safety


def test_dry_runs_change_nothing(inknotes, tmp_path):
    note = inknotes.create("# Dry\n- [ ] item\ntext")
    other = inknotes.create("# Dry other\nbody")
    png = write_png(tmp_path / "dry.png")
    before = (inknotes.read(note), inknotes("find"), inknotes("folders"), inknotes("tags"))
    for args in (["check", "item"], ["add-todo", "new"], ["add-tag", "drytag"], ["link", other["id"]],
                 ["set-style", "text", "heading"], ["format", "text", "--bold"], ["pin"],
                 ["attach", str(png)], ["add-url", "https://example.com/"]):
        assert inknotes(args[0], note["id"], *args[1:])["dry_run"], args
    assert inknotes("add-table", note["id"], "--tsv", "-", stdin="a\tb")["dry_run"]
    assert inknotes("append", note["id"], "--markdown", "-", stdin="more")["dry_run"]
    assert inknotes("create-folder", "Dry folder")["dry_run"]
    assert (inknotes.read(note), inknotes("find"), inknotes("folders"), inknotes("tags")) == before


def test_writes_are_limited_to_writable_accounts(inknotes):
    note = inknotes.create("# Guarded\n- [ ] item")
    env = {"INKNOTES_WRITABLE_ACCOUNTS": "Nowhere"}
    errors(inknotes, "account_not_writable", "check", note["id"], "item", "--apply", env=env)
    errors(inknotes, "account_not_writable", "check", note["id"], "item", env=env)
    errors(inknotes, "account_not_writable", "create-folder", "Blocked", "--apply", env=env)
    errors(inknotes, "account_not_writable", "create", "--folder", FOLDER, "--markdown", "-", stdin="# Blocked", env=env)
    assert inknotes("check", note["id"], "item", "--apply", env={"INKNOTES_WRITABLE_ACCOUNTS": "on my mac"})["changed"]
