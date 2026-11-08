# inknotes reference

Every command, option and output format. For setup, see the [README](../README.md).

## How it behaves

- Results, including `version` and `--version`, print JSON to stdout; `read --format markdown` prints Markdown and help prints text. Errors print one sorted JSON line `{"error": code, "message": …, "retryable": false, "status": "action_required"|"error"}` to stderr. Exit codes: **0** success, **2** usage errors or missing input, **1** operational failures, including a note, folder or paragraph that isn't found.
- Write commands are **dry runs** unless `--apply` is passed. A dry run validates everything (paragraphs, link targets, files, SVGs), prints the plan, and opens the database read-only.
- Writes only touch accounts listed in `INKNOTES_WRITABLE_ACCOUNTS` (comma-separated). The default is `On My Mac`. iCloud is supported and opt-in: set the variable to `iCloud` (or `On My Mac,iCloud`) to write to it. Notes.app does the upload, usually within 15–90 seconds, though one edit once took several minutes.
- Renamed from `nnote` in 0.4.0: the binary is `inknotes` and the environment variables start with `INKNOTES_`.

## Help and parsing

`inknotes`, `inknotes --help`, `inknotes -h` and `inknotes help` show root help.
`inknotes <command> --help`, `inknotes <command> -h` and `inknotes help <command>`
show that command's usage, summary, options and example. Help and `--version`
work before any store access; help takes precedence over other validation.
`inknotes version` and `inknotes --version` both return `{"version": "0.4.0"}`.

Each command rejects unknown options and extra positional arguments before opening
Notes. Value options accept `--name value` and `--name=value`; repeated options
use the last value. `--` ends option parsing, so `inknotes find -- --help` searches
for the literal title text `--help`. Text that starts with `-` needs it too:
`inknotes add-todo <note> -- '- item'`. An option value that starts with `--` needs
the `=` form: `--after=--item`. Switches such as `--apply` take no value.
`find --pinned`, `--pinned 1` and `--pinned=1` select pinned notes.

`--limit` must be a positive integer (default 20); `--indent`, `--index` and
`--paragraph-index` must be non-negative integers. `--width` must be finite and
greater than zero (default 400 points). `--format` accepts only `json` or `markdown`.
Invalid values fail with exit 2 instead of silently choosing a default.

Input errors, including unreadable input files and ambiguous references
(`file_not_found`, `ambiguous_*`), exit 2 with `status: "action_required"`.
Arguments are checked before the store opens, so a bad argument is reported ahead of a
missing note. Things the store rules out exit 1 with `status: "action_required"`:
access restrictions (`no_access`, `account_not_writable`, `note_locked`, `note_deleted`),
not found (`note_not_found`, `folder_not_found`, `account_not_found`,
`paragraph_not_found`, `text_not_found`) and conflicts (`folder_exists`, `not_a_todo`).
Framework, fetch, save and object-creation failures exit 1 with `status: "error"`.
`retryable` is always false: no error promises that replaying a write is safe.
Existing `error` codes and the `error` and `message` keys are stable; match on the
code, because `message` wording can change.

## Examples

These run as written against `On My Mac`, the default writable account. To write to iCloud, prefix a write with `INKNOTES_WRITABLE_ACCOUNTS=iCloud` and pass `--account iCloud` to `create`, `create-folder`, `find`, `folders` and `tags`.

**Find and read**

```bash
inknotes folders                                   # folder paths, ids, note counts
inknotes tags                                      # tags and how many notes use each
inknotes find "Weekly review"                      # titles containing the text, newest first
inknotes find --tag weekly --limit 5
inknotes find --folder Projects/Reports --pinned 1
inknotes search "release notes" --limit 5          # words anywhere in the body, with a snippet around each match

NOTE=$(inknotes find "Weekly review" | jq -r '.notes[0].id')
inknotes read "$NOTE"                              # paragraphs, to-dos, formatting, links, tables as JSON
inknotes read "$NOTE" --format markdown            # the same note as Markdown
inknotes backlinks "$NOTE"                         # notes that link here
```

**Create a note from Markdown.** Without `--apply`, a write only prints its plan.

```bash
inknotes create-folder Projects --apply
inknotes create-folder Reports --parent Projects --apply

cat > review.md <<'EOF'
# Weekly review

## Done
- [x] Ship inknotes 0.4.0
- [ ] Publish the skill

## Notes
The release went **well**; see ==the changelog==. Next steps are in [[Roadmap#Q4 goals]].

| Area | Status |
|---|---|
| CLI | done |
| Skill | in progress |

https://developer.apple.com/documentation/pencilkit

#weekly
EOF

inknotes create --folder Projects/Reports --markdown review.md           # dry run: check the plan
inknotes create --folder Projects/Reports --markdown review.md --apply   # write it
printf '## Next week\n- [ ] Plan 0.5.0\n' | inknotes append "$NOTE" --markdown - --apply
```

`[[Roadmap#Q4 goals]]` needs a note titled `Roadmap` with a paragraph `Q4 goals`; the dry run fails with `note_not_found` or `paragraph_not_found` otherwise.

**Edit to-dos, styles and formatting.** A paragraph is named by its text as `read` shows it, or by `--index N`.

```bash
inknotes check "$NOTE" "Publish the skill" --apply
inknotes check "$NOTE" "Publish the skill" --undo --apply
inknotes add-todo "$NOTE" "Write release notes" --after "Publish the skill" --apply
inknotes set-style "$NOTE" "Notes" subheading --apply
inknotes set-style "$NOTE" --index 1 --style subheading --apply   # "Done"; read lists each paragraph's index
inknotes format "$NOTE" "Done" --highlight mint --apply
inknotes format "$NOTE" "Write release notes" --text "release notes" --bold --link https://github.com/nickhuo/inknotes/releases --apply
inknotes pin "$NOTE" --apply
```

**Links, tags and objects**

```bash
ROADMAP=$(inknotes find "Roadmap" | jq -r '.notes[0].id')
inknotes link "$NOTE" "$ROADMAP" --apply                           # link to the note
inknotes link "$NOTE" "$ROADMAP" --paragraph "Q4 goals" --apply    # link to one paragraph
inknotes add-tag "$NOTE" release --apply

printf 'Version\tDate\n0.4.0\t2026-10-28\n' | inknotes add-table "$NOTE" --tsv - --apply
inknotes add-url "$NOTE" https://github.com/nickhuo/inknotes --apply
inknotes attach "$NOTE" screenshot.png --apply
inknotes draw "$NOTE" --svg architecture.svg --width 360 --ink marker --color '#1f6feb' --apply
```

## References

- `<note>`: a note's `id` (UUID, from `find`), its `uri` (`x-coredata://…/ICNote/pN`), or the number `N`.
- `<item>`: a paragraph's displayed `text`, exactly as `read` prints it. Pass `--index N` instead when several paragraphs read the same; the command fails with `ambiguous_paragraph` and lists the indexes.
- Folders: an `id` from `folders`, or a path such as `Projects/Reports`, inside `--account` (default `On My Mac`).
- Placement for anything added to an existing note: `--after <item>` or `--index N` puts it after that paragraph. Otherwise it goes at the end.

## Commands

### Read

| Command | Output |
|---|---|
| `find [text] [--folder F] [--account A] [--tag T] [--pinned [1]] [--limit N]` | Notes whose title contains `text`, newest first (default limit 20) |
| `search <text> [--folder F] [--account A] [--limit N]` | Notes whose body contains `text`, each with id, title, folder, account, modified date and a snippet of the first match with up to 80 characters on each side (default limit 20) |
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
| `draw <note> --svg FILE [--width PT] [--ink pen\|pencil\|marker] [--color #rrggbb]` | Native drawing that can be edited with the drawing tools (default 400 pt wide, pen, the SVG's own colors). The dry run reports how faithful it is: `max_deviation`, the farthest the drawn line strays from the SVG outline (in points), and `width_ratio`, the narrowest and widest strokes as drawn width ÷ SVG stroke width |

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
  "id": "…", "uri": "x-coredata://…/ICNote/p21311", "title": "inknotes research report",
  "account": "On My Mac", "folder": "inknotes Tests/Reports", "pinned": false, "modified": "2026-10-25T09:17:10Z",
  "paragraphs": [
    {"index": 3, "style": "body", "paragraph_id": "…", "text": "Text can be bold, italic, …",
     "formats": [{"text": "bold", "bold": true}, {"text": "highlighted", "highlight": "purple"}, {"text": "web link", "link": "https://…"}]},
    {"index": 9, "style": "bullet", "indent": 1, "text": "nested bullet under item 2"},
    {"index": 13, "style": "body", "quote": 1, "text": "A quote, kept as a Notes block quote."},
    {"index": 17, "style": "checklist", "text": "Does iCloud sync these changes?", "todo": {"done": false, "uuid": "…"}},
    {"index": 26, "style": "body", "text": "Related: NotesShared link target and NotesShared smoke test → alpha #inknotesreport",
     "attachments": [
       {"type": "link", "text": "NotesShared link target", "target": "applenotes:note/b1c37457-…"},
       {"type": "link", "text": "NotesShared smoke test → alpha", "target": "applenotes://showNote?identifier=…&paragraphID=A7600BB9-…"},
       {"type": "tag", "text": "#inknotesreport"}]},
    {"index": 22, "style": "body", "text": "[table]", "attachments": [{"type": "table", "rows": [["Feature", "Status"]]}]}
  ]
}
```

- `search` returns `notes` and `count`, plus `truncated` (another readable matching note exists beyond `--limit`) and `skipped` (selected notes whose body could not be read). It scans all selected bodies to report these accurately; `count: 0` with `skipped > 0` is incomplete coverage, not proof of no matches. `find` retains its `total` field.
- Attachment `type`: `tag`, `link`, `table`, `url` (link card), `file`, `drawing`, `dividerline`, or another inline type. Each also has `id` and `uti`.
- `paragraph_id` is the paragraph's identity, which paragraph links point to.
- Write results: `{"dry_run": true, "plan": …}`; `{"changed": true, "plan": …, "note": …}`; `{"changed": false, "reason": …}` when nothing needed changing.

Error codes: `usage`, `no_access`, `note_not_found`, `ambiguous_note`, `folder_not_found`, `ambiguous_folder`, `folder_exists`, `account_not_found`, `account_not_writable`, `paragraph_not_found`, `ambiguous_paragraph`, `bad_index`, `text_not_found`, `not_a_todo`, `bad_text`, `bad_tag`, `bad_target`, `bad_style`, `bad_highlight`, `bad_url`, `bad_table`, `bad_svg`, `bad_name`, `bad_parent`, `bad_folder`, `file_not_found`, `note_deleted`, `note_locked`, `unsupported_macos`, `framework_unavailable`, `store_not_read_only`, `fetch_failed`, `save_failed`, `create_failed`, `folder_failed`, `tag_failed`, `link_failed`, `attachment_failed`.

## Limits

- Not supported: deleting or moving notes, paragraphs or attachments; editing table cells; text color; locked notes.
- **SVG:** strokes only, so fills become outlines; gradients, `<use>` and CSS classes are ignored. Rounded rectangles (`rx`, `ry`) are supported. `<text>` and `<tspan>` are drawn as hollow glyph outlines in their fill color (CoreText, so Chinese falls back to PingFang), with `font-size`, `font-family`, bold, `text-anchor` and `dominant-baseline="middle"`. The dry run reports `text` (elements) and `glyphs` (characters drawn).
- **Bundle identifier:** PencilKit stores per-app state under the bundle identifier and crashes in a process without one, so the binary embeds `Sources/inknotes/Info.plist` (`dev.inknotes.cli`).
- **Drawing fidelity:** PencilKit treats stroke points as spline control points and its point size is not the drawn width, so inknotes samples every edge densely and converts each SVG stroke width into the size that ink draws at. Measured on the test fixtures: the pen stays within 0.7 pt of the outline at 0.98–1.04× the SVG width; pencil is 0.7–1.2× (textured edge); marker is 0.6–1.4× (a chisel nib, thinner across horizontal lines). The e2e tests check these bounds.
- **Link cards:** the URL is stored. Cards made before version 0.2.2 have no URL and show up empty. Whether Notes.app fetches the preview for a card added while it was closed hasn't been checked.
- Links between accounts (On My Mac → iCloud) haven't been tried.
