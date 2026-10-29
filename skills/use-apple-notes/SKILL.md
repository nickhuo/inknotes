---
name: use-apple-notes
description: Manage the user's Apple Notes knowledge base (AI context, knowledge and task management) from the terminal with the inknotes CLI, which edits notes natively (checklists, tags, note and paragraph links, tables, headings, highlights, drawings). Use when the user asks to create, read, edit, search, or link Apple Notes, capture something to their notes, write a report into Notes, review a note's links/backlinks, or manage tasks and knowledge stored in Apple Notes.
---

# Apple Notes knowledge base

Apple Notes is the user's personal knowledge base: AI context, knowledge management, and task management. Operate it with `inknotes` (`~/.local/bin/inknotes`; source and full reference in `~/GitHub/inknotes/README.md`). It reads and writes Notes through Notes' own framework, so checklists, `#tags`, links, tables and formatting are real Notes objects, not imitations.

## Before you start

- **Install.** If `inknotes` is not on the PATH, download the latest release (private repo; needs `gh` signed in with access):
  ```bash
  mkdir -p ~/.local/bin && gh release download --repo nickhuo/inknotes --pattern inknotes --output ~/.local/bin/inknotes --clobber && chmod +x ~/.local/bin/inknotes
  ```
  Run the same command to update.
- **Full Disk Access.** inknotes needs it. In Claude's desktop app only the Terminal panel has it: run inknotes through the Terminal panel (`run_in_terminal`), not the Bash tool. Without it every command fails with `no_access`.
- **Output.** Every command prints JSON on stdout; errors print `{"error": code, "message": …}` on stderr with exit code 1. `read --format markdown` prints Markdown.
- **Dry run first.** Write commands only plan unless you pass `--apply`. Run once without it, check the `plan`, then run again with `--apply` and check the returned `note`.
- **Accounts.** Writes are limited to the accounts in `INKNOTES_WRITABLE_ACCOUNTS` (default `On My Mac`). The knowledge base is in **iCloud**, so prefix writes to it with `INKNOTES_WRITABLE_ACCOUNTS=iCloud`. Reads need nothing.
- **Sync.** Changes appear in Notes.app on this Mac at once. Notes.app uploads them to iCloud, usually within 15–90 seconds; don't promise the user their phone has a change the moment you make it.

## Finding and reading

```bash
inknotes find "words in the title" [--folder "A/B"] [--account iCloud] [--tag topic] [--pinned 1] [--limit N]
inknotes read <id>                    # JSON: paragraphs with style, to-do state, tags, links, tables, formatting
inknotes read <id> --format markdown  # the note as Markdown
inknotes backlinks <id>               # notes that link here, and to which paragraph
inknotes folders [--account iCloud]   # folder paths, ids, note counts
inknotes tags [--account iCloud]      # tags and how many notes use each
```

`find` matches titles only, not note bodies. `<id>` is the `id` from `find` (a UUID). A paragraph is named by its exact displayed `text` from `read`; when several paragraphs read the same, pass `--index N` instead of the text. With `--index`, `set-style` takes the style as `--style heading`, since there is no text argument before it.

## Writing

```bash
W="INKNOTES_WRITABLE_ACCOUNTS=iCloud"   # for notes in iCloud

env $W inknotes create "Title" --folder "Folder/Sub" --account iCloud --markdown note.md --apply
env $W inknotes append <id> --markdown - [--after "<paragraph text>"] --apply   # Markdown on stdin
env $W inknotes check <id> "<to-do text>" [--undo] --apply
env $W inknotes add-todo <id> "text" [--after "<paragraph text>"] --apply
env $W inknotes add-tag <id> topic --apply
env $W inknotes link <id> <target-id> [--paragraph "<target paragraph text>"] --apply
env $W inknotes set-style <id> "<paragraph text>" heading --apply
env $W inknotes format <id> "<paragraph text>" [--text "part"] --bold|--italic|--highlight pink|--link URL --apply
env $W inknotes pin <id> [--undo] --apply
env $W inknotes create-folder "Name" --parent "Folder" --account iCloud --apply
env $W inknotes add-table <id> --tsv - --apply      # rows on lines, cells tab-separated
env $W inknotes add-url <id> https://… --apply      # link card
env $W inknotes attach <id> /path/file.pdf --apply
env $W inknotes draw <id> --svg diagram.svg [--width 400] --apply   # native, editable drawing
```

Prefer `create`/`append` with Markdown for anything longer than a line: one save, every object native.

### Markdown it understands

- `# Title`, `## Heading`, `### Subheading` become Notes' title, heading and subheading styles.
- `- item`, `1. item` (indent with spaces to nest), `- [ ] to-do`, `- [x] done`, `> quote`, ```` ``` ```` code blocks.
- `**bold**`, `*italic*`, `~~strike~~`, `==highlight==` (purple) or `=={pink}text==` (pink, orange, mint, blue), `[text](https://…)`.
- `#tag` becomes a native tag. `[[Note title]]` and `[[Note title#Paragraph text]]` become native note and paragraph links; the title must be unique in the account.
- `| a | b |` tables become native tables; `---` becomes a divider; a URL alone on a line becomes a link card; `![alt](file.png)` attaches a file and `![alt](figure.svg)` a drawing (paths relative to the Markdown file).

### Formatting rules

- Keep the first line short: it is the note's title.
- Use headings for structure; they are real Notes headings.
- A blank line becomes one empty paragraph. Put one between blocks (paragraph, list, table) and none between items of the same list.
- No decorative emoji unless the user asks for them or they carry task-critical meaning.

## Links and backlinks: check before you edit or create

This knowledge base relies on links between notes.

1. **Before editing a note**, run `inknotes read <id>` and `inknotes backlinks <id>`. Keep its existing links (they show in `read` as attachments of type `link`), and keep its title stable when other notes link to it: renaming orphans those links.
2. **When creating or expanding a note on a topic**, `find` related notes and link them (`[[Title]]` in the Markdown, or `inknotes link`) so the new note is connected, not orphaned.
3. Link to a specific section with a paragraph link (`[[Title#Heading]]` or `link --paragraph`); it survives edits to the rest of that note.

## Limits

- No delete or move (notes, paragraphs, attachments), no editing of existing table cells, no text color, no locked notes. Do those in Notes.app or tell the user.
- Drawings: SVG strokes and text become PencilKit strokes; fills are drawn as outlines and text as hollow letters.
- Built against macOS 27.2. If a command fails with `unsupported_macos`, Notes' private API changed; tell the user instead of working around it.
