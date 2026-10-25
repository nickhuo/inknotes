# nnote

A command-line tool for agents to read and edit Apple Notes **natively**. It works through Notes' own private framework (NotesShared), so it can do what AppleScript can't: real checklists, `#tags`, links between notes and to single paragraphs, tables, headings, highlights, pinning, subfolders, link cards, file attachments, and editable PencilKit drawings made from SVG. It can also build a whole note from Markdown, such as a research report.

- Every command prints JSON to stdout. Errors print `{"error": code, "message": …}` to stderr with exit code 1. `read --format markdown` prints Markdown instead.
- Write commands are **dry runs** unless `--apply` is passed. A dry run validates everything (paragraphs, link targets, files, SVGs), prints the plan, and opens the database read-only.
- Writes only touch accounts listed in `NNOTE_WRITABLE_ACCOUNTS` (comma-separated). The default is `On My Mac`, because syncing changes made this way to iCloud is untested.

## Requirements

- macOS 27.2. The private methods were found on build 26B5112a. Each call checks the method exists and fails with `unsupported_macos` if it doesn't.
- **Full Disk Access** for the process that runs `nnote`; without it you get `no_access`. In Claude's desktop app, only its Terminal panel inherits the grant given to Claude.app.
- Build: `zsh build.sh`, which uses `clang` from the Command Line Tools and links Foundation, CoreData, AppKit and PencilKit.

## References

- `<note>`: a note's `id` (UUID, from `find`), its `uri` (`x-coredata://…/ICNote/pN`), or the number `N`.
- `<item>`: a paragraph's displayed `text`, exactly as `read` prints it. Pass `--index N` instead when several paragraphs read the same; the command fails with `ambiguous_paragraph` and lists the indexes.
- Folders: an `id` from `folders`, or a path such as `Projects/Reports`, inside `--account` (default `On My Mac`).
- Placement for anything added to an existing note: `--after <item>` or `--index N` puts it after that paragraph. Otherwise it goes at the end.

## Commands

### Read

| Command | Output |
|---|---|
| `find [text] [--folder F] [--account A] [--tag T] [--pinned 1] [--limit N]` | Notes whose title contains `text`, newest first (default limit 20) |
| `read <note> [--format json\|markdown]` | Paragraphs with style, indent, quote level, to-do state, inline formatting, tags, links, tables and attachments |
| `backlinks <note>` | Notes that link to this note or to one of its paragraphs: where each link sits, and which paragraph it targets |
| `folders [--account A]` | Every folder and subfolder, with id, path, parent and note count |
| `tags [--account A]` | Every tag, with the number of notes using it |

### Write

| Command | Does |
|---|---|
| `create [title] [--folder F] [--account A] [--markdown FILE\|-]` | New note from Markdown (default folder `Notes`) |
| `append <note> --markdown FILE\|-` | Add Markdown content |
| `create-folder <name> [--parent F] [--account A]` | New folder or subfolder |
| `pin <note> [--undo]` | Pin or unpin |
| `set-style <note> <item> <style> [--indent N]` | `title`, `heading`, `subheading`, `body`, `monospaced`, `bullet`, `dash`, `numbered` or `checklist`. The paragraph keeps its identity, so paragraph links to it keep working |
| `format <note> <item> [--text SUBSTRING] [--bold] [--italic] [--underline] [--strike] [--highlight COLOR] [--link URL] [--plain]` | Character formatting on the paragraph, or on the first occurrence of `--text` in it. `COLOR` is `purple`, `pink`, `orange`, `mint` or `blue` (or `1`–`5`), or `none` to remove it. `--plain` clears all formatting first |
| `check <note> <item> [--undo]` | Check or uncheck a to-do |
| `add-todo <note> <text>` | Unchecked to-do; default position is after the last to-do |
| `add-tag <note> <tag>` | Native tag on its own line |
| `link <note> <target> [--paragraph <item> \| --paragraph-index N]` | Native link to another note, or to one of its paragraphs (shown as "Note → paragraph") |
| `add-table <note> --tsv FILE\|-` | Native table; rows are lines, cells are tab-separated |
| `add-url <note> <url>` | Link card |
| `attach <note> <file>` | Image, PDF or any file |
| `draw <note> --svg FILE [--width PT] [--ink pen\|pencil\|marker] [--color #rrggbb]` | Native drawing that can be edited with the drawing tools (default 400 pt wide, pen, the SVG's own colors) |

## Markdown

`create` and `append` understand:

| Markdown | Becomes |
|---|---|
| `# T`, `## H`, `### S` (or deeper) | Title, heading, subheading |
| `- x`, `* x`, `1. x` | Bulleted or numbered list; leading spaces nest it |
| `- [ ] x`, `- [x] x` | Native to-do, unchecked or checked |
| `> x` | Block quote |
| ` ``` ` fences | Monospaced lines |
| `**b**`, `*i*`, `~~s~~`, `[text](https://…)` | Bold, italic, strikethrough, web link |
| `==h==`, `=={pink}h==` | Purple highlight; `{pink}`, `{orange}`, `{mint}` or `{blue}` picks another color |
| `#tag` | Native tag |
| `[[Note title]]`, `[[Note title#Paragraph text]]` | Native note link, or paragraph link. The title must be unique in the account |
| `[text](applenotes:note/<id>)`, `[text](applenotes://showNote?identifier=<id>&paragraphID=<uuid>)` | The same links, by id: this is how `read --format markdown` exports them |
| `\| a \| b \|` rows | Native table; the `---` separator row is skipped |
| `---` | Divider line |
| a URL alone on a line | Link card |
| `![alt](file.png)` | File attachment; paths are relative to the Markdown file |
| `![alt](drawing.svg)` | Native drawing |

Blank lines become one empty paragraph.

## Output of `read`

```json
{
  "id": "…", "uri": "x-coredata://…/ICNote/p21311", "title": "nnote research report",
  "account": "On My Mac", "folder": "nnote Tests/Reports", "pinned": false, "modified": "2026-10-25T09:17:10Z",
  "paragraphs": [
    {"index": 3, "style": "body", "paragraph_id": "…", "text": "Text can be bold, italic, …",
     "formats": [{"text": "bold", "bold": true}, {"text": "highlighted", "highlight": "purple"}, {"text": "web link", "link": "https://…"}]},
    {"index": 9, "style": "bullet", "indent": 1, "text": "nested bullet under item 2"},
    {"index": 13, "style": "body", "quote": 1, "text": "A quote, kept as a Notes block quote."},
    {"index": 17, "style": "checklist", "text": "Does iCloud sync these changes?", "todo": {"done": false, "uuid": "…"}},
    {"index": 26, "style": "body", "text": "Related: NotesShared link target and NotesShared smoke test → alpha #nnotereport",
     "attachments": [
       {"type": "link", "text": "NotesShared link target", "target": "applenotes:note/b1c37457-…"},
       {"type": "link", "text": "NotesShared smoke test → alpha", "target": "applenotes://showNote?identifier=…&paragraphID=A7600BB9-…"},
       {"type": "tag", "text": "#nnotereport"}]},
    {"index": 22, "style": "body", "text": "[table]", "attachments": [{"type": "table", "rows": [["Feature", "Status"]]}]}
  ]
}
```

- Attachment `type`: `tag`, `link`, `table`, `url` (link card), `file`, `drawing`, `dividerline`, or another inline type. Each also has `id` and `uti`.
- `paragraph_id` is the paragraph's identity, which paragraph links point to.
- Write results: `{"dry_run": true, "plan": …}`; `{"changed": true, "plan": …, "note": …}`; `{"changed": false, "reason": …}` when nothing needed changing.

Error codes: `usage`, `no_access`, `note_not_found`, `ambiguous_note`, `folder_not_found`, `ambiguous_folder`, `folder_exists`, `account_not_found`, `account_not_writable`, `paragraph_not_found`, `ambiguous_paragraph`, `bad_index`, `text_not_found`, `not_a_todo`, `bad_text`, `bad_tag`, `bad_target`, `bad_style`, `bad_highlight`, `bad_url`, `bad_table`, `bad_svg`, `bad_name`, `bad_parent`, `bad_folder`, `file_not_found`, `note_deleted`, `note_locked`, `unsupported_macos`, `framework_unavailable`, `store_not_read_only`, `fetch_failed`, `save_failed`, `create_failed`, `folder_failed`, `tag_failed`, `link_failed`, `attachment_failed`.

## Agent workflows

**Edit a note:** `find` → `read` → run the write without `--apply` → check the `plan` → run it again with `--apply` → check the returned `note`.

**Write a research report:**
1. Write the report as Markdown, linking existing notes with `[[Title]]`, drawings as `![](figure.svg)`, and sources as bare URLs (link cards) or `[text](url)`.
2. `nnote create --folder Research --markdown report.md` to validate. The plan lists every block and every resolved link; it fails on a missing note, file or invalid SVG.
3. Run it again with `--apply`.
4. Use `nnote backlinks <report>` later to see what refers to it.

## How a write works

1. Open Notes' database through NotesShared with a writable context. Reads and dry runs use the read-only option `0x40`.
2. Edit the note's text through Notes' own merge-safe text object, between `beginEditing` and `endEditing`. Objects are created with Notes' own constructors:
   - tags and links: `+[ICInlineAttachment newHashtagAttachment…]`, `newLinkAttachment…toNote:`, `newParagraphLinkAttachment…paragraphID:`
   - tables: `-[ICNote addTableAttachmentWithText:]`, which needs NotesUI loaded
   - files and link cards: `addAttachmentWithFileURL:`, `addAttachmentWithUTI:withURL:`
   - drawings: `+[ICPaperAttachmentCreationHelper createSystemPaperAttachmentWithPKDrawing:inNote:]`
   - folders and notes: `+[ICFolder newFolderInParentFolder:]`, `+[ICNote newEmptyNoteInFolder:]`

   Each object is inserted as an attachment character.
3. Set the modification date, bump the change count, and save. Pinning bumps only the change count.
4. Post `ICEditorExtensionDidSaveNotification`, so a running Notes.app reloads the note instead of overwriting it with its open copy.

Character formatting is stored as text attributes: `TTHints` (bit 1 bold, bit 2 italic), `TTUnderline`, `TTStrikethrough`, `TTEmphasis` (highlight: 1 purple, 2 pink, 3 orange, 4 mint, 5 blue, matching the order of Notes' highlight menu and confirmed in Notes.app) and `NSLink`.

## Tested (2026-10-25, On My Mac, Notes.app open)

| Area | Result |
|---|---|
| Checklists: add, check, uncheck | Notes.app shows them; to-dos keep their UUID |
| Tags, note links, tables | Native objects; the links open their notes |
| Folders | Created "nnote Tests" and the subfolder "nnote Tests/Reports" |
| Report from Markdown (`test/report.md`) | One note with headings, inline formatting, nested lists, quote, to-dos, code block, table, divider, note link, paragraph link, tag, link card, image and drawing, all created in one save and rendered correctly |
| Pin, set-style, bold/italic/underline on parts of a line | Rendered correctly |
| Highlights 1–5 | Rendered as purple, pink, orange, mint and blue; color names work in `format` and in Markdown, and `read` reports them |
| Paragraph link (`link --paragraph alpha`) | Points at alpha's `paragraph_id`, and `backlinks` reports it |
| SVG drawings, pen and marker ink with a color override | Native `com.apple.paper` drawings, shown in Notes.app |

After each write, a row-by-row diff of the database showed changes only to On My Mac objects: the edited notes, their new tag, link and attachment objects, folders, and the account's change counter. Across the whole run, one iCloud note's change counter moved with no change to its content or date, which matches Notes.app's own bookkeeping.

Test scripts: `test/test-writes.sh`, `test-guards.sh`, `step.sh` (one write plus a row diff), `rows.sh` (row snapshots), `test/icloud-diff.sh`.

## Not supported or untested

- **iCloud:** untested. It's blocked by default; add it to `NNOTE_WRITABLE_ACCOUNTS` only after testing sync.
- Not supported: deleting or moving notes, paragraphs or attachments; editing table cells; text color; locked notes.
- **SVG:** strokes only, so fills become outlines; text, gradients, `<use>` and CSS classes are ignored.
- **Link cards:** whether the preview image is fetched while Notes.app is closed hasn't been checked.
- Links between accounts (On My Mac → iCloud) haven't been tried.
