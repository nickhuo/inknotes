# Developing inknotes

## Build

- `zsh build.sh` builds `build/inknotes`, a Swift package built with `swift build` (Swift 6 from the Command Line Tools). `zsh build.sh install` also copies it to `~/.local/bin`.
- macOS 27.2. The private methods were found on build 26B5112a. Each call checks the method exists and fails with `unsupported_macos` if it doesn't.
- `INKNOTES_CONTAINER=<name>` makes `inknotes` use a separate store at `~/Library/Group Containers/group.com.apple.notes/Containers/<name>/` instead of your notes. The tests use this.
- To publish a release, run `zsh build.sh` and attach `build/inknotes` to a release tagged `v<version>` (the `version` in `Sources/inknotes/main.swift`).

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
| Folders | Created "inknotes Tests" and the subfolder "inknotes Tests/Reports" |
| Report from Markdown (`tests/fixtures/report.md`) | One note with headings, inline formatting, nested lists, quote, to-dos, code block, table, divider, note link, paragraph link, tag, link card, image and drawing, all created in one save and rendered correctly |
| Pin, set-style, bold/italic/underline on parts of a line | Rendered correctly |
| Highlights 1–5 | Rendered as purple, pink, orange, mint and blue; color names work in `format` and in Markdown, and `read` reports them |
| Paragraph link (`link --paragraph alpha`) | Points at alpha's `paragraph_id`, and `backlinks` reports it |
| SVG drawings, pen and marker ink with a color override | Native `com.apple.paper` drawings, shown in Notes.app |

After each write, a row-by-row diff of the database showed changes only to On My Mac objects: the edited notes, their new tag, link and attachment objects, folders, and the account's change counter. Across the whole run, one iCloud note's change counter moved with no change to its content or date, which matches Notes.app's own bookkeeping.

After the Swift rewrite (0.3.0), the installed binary created the report fixture and its link target in On My Mac. Notes.app rendered all of it correctly: headings, formatting, highlights, lists, quote, to-dos, code, table, divider, both links, tag, link card, image and drawing.

These rendering checks were done by hand in Notes.app. Regressions in what `inknotes` writes and reads are caught by the e2e tests below.

## Layout

| Path | Module | Interface |
|---|---|---|
| `Sources/inknotes/main.swift` | CLI | Command implementations and dispatch |
| `Sources/inknotes/CLI.swift` | CLI metadata | Command and option definitions, argument validation and help, without store access |
| `Sources/inknotes/Search.swift` | Search | Matching, snippets, truncation and skipped-body reporting |
| `Sources/inknotes/NotesShared.swift` | The private API | Every NotesShared method inknotes calls, declared as an `@objc protocol` with its exact selector. Objects are viewed through these protocols, so each message send is type-checked |
| `Sources/inknotes/Store.swift` | The Notes store | Open (read-only or writable), look up notes, folders and accounts, write guards, `commit` (one edit, saved the way Notes saves it). The seam to Notes: your store, or a test container |
| `Sources/inknotes/Document.swift` | A note's text | Paragraph JSON, finding a paragraph, inserting paragraphs, paragraph styles |
| `Sources/inknotes/Objects.swift` | Native objects | Make a tag, note or paragraph link, table, file, link card, drawing or divider in a note |
| `Sources/inknotes/Markdown.swift` | Markdown | Parse, plan (dry run), render into a note, export |
| `Sources/inknotes/SVG.swift` | SVG | SVG file → PencilKit drawing |
| `Sources/inknotes/Core.swift` | Shared | Attribute keys, style and highlight names, JSON output and errors |
| `tests/` | Tests | CLI contracts without store access, plus every command through the container |

## Tests

```bash
uv run pytest
```

- The suite builds `build/inknotes` and runs every command through its JSON interface: all writes, their dry runs, and their error codes. Set `INKNOTES_BIN` to test another binary.
- It runs against a fresh store in the test container `inknotes-e2e`, which it deletes before and after the run (`INKNOTES_E2E_KEEP=1` keeps it).
- It refuses to start if that store isn't empty. At the end, it checks that your real store has the same objects and note bodies as before.
- It needs Full Disk Access ([how to grant it](../README.md#get-started)); without it, the full run stops with a message. Run `uv run pytest tests/cli_test.py` for the help, parsing, error and search tests, which need no store access.
- Every change should keep `uv run pytest` green. A new command or option needs a test in `tests/e2e_test.py` or `tests/cli_test.py`.
- The tests only talk to the CLI, so they don't depend on the implementation language. Version 0.3.0 rewrote inknotes from Objective-C into Swift; the same 23 tests passed unchanged before and after. The store-free tests also compile a small Swift harness to cover parser values, error classification and unreadable search bodies.

## Calling a private method

Declare it in `NotesShared.swift`, with the selector written out, on the protocol for that class (class methods go on the `…Class` protocol). Then call it through `view(object, as: Protocol.self)` or `NotesShared.classObject(name, as:)`. If the method might be missing on some macOS versions, check `responds(object, "selector:")` first and fail with `unsupported_macos`. Avoid `init…` methods, whose memory ownership a protocol can't express; `-init` plus a copy method (such as `todoWithDone:`) usually does the job.
