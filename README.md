# inknotes

**Let your AI agent work in Apple Notes the way you do: check off to-dos, tag notes, and link notes to each other.**

Agents can already reach Apple Notes through AppleScript and the tools built on it. That route only sees a note as text and HTML, so an agent can dump text into a note but can't keep a knowledge base there. A to-do comes out as a plain bullet, a `#tag` as plain text, and there is no way to link one note to another, so backlinks never exist.

inknotes edits notes through the same framework Notes.app itself uses. Everything it writes is a real Notes object: a to-do you can tick on your phone, a tag that shows up in the tag browser, a link that opens the other note.

| Your agent wants to… | Through AppleScript | With inknotes |
|---|---|---|
| Add or check off a to-do | Writes a plain bullet | Native to-do, checked or unchecked |
| Tag a note | Writes the text `#tag` | Native tag, listed in Notes' tag browser |
| Link to another note, or to one paragraph in it | Not possible | Native note link or paragraph link |
| Ask "which notes link here?" | Not possible | `inknotes backlinks <note>` |
| Find a note by what it says | Title or body search | `inknotes search` returns a snippet around each match |
| Turn a Markdown report into a note | Plain HTML | Headings, highlights, tables, link cards, images and drawings, in one save |

## Get started

You need macOS 27.2 on Apple silicon and the [GitHub CLI](https://cli.github.com) (`gh`) signed in with access to this repo, which is private.

**1. Install the agent skill** (Claude Code, Codex and other agents that read skills):

```bash
npx skills add nickhuo/inknotes --skill use-apple-notes -g
```

The skill downloads the `inknotes` binary itself the first time your agent needs it. To install it by hand instead:

```bash
mkdir -p ~/.local/bin && gh release download --repo nickhuo/inknotes --pattern inknotes --output ~/.local/bin/inknotes --clobber && chmod +x ~/.local/bin/inknotes
```

**2. Give Full Disk Access** to the app your agent runs in: System Settings → Privacy & Security → Full Disk Access, then add your terminal app (or Claude.app). Without it, every command fails with `no_access`. In Claude's desktop app, only the Terminal panel gets this access.

**3. Ask your agent.** For example:

> Find my notes tagged #weekly, add a to-do "Plan next sprint" to the newest one, and link it to my Roadmap note.

> Write up what we learned today as a note in Research, with a table of the options we compared, and link it to the notes it builds on.

> Which notes link to my Roadmap note?

Your notes stay safe while you try it: every write is a dry run until `--apply` is passed, writes go only to the **On My Mac** account until you allow iCloud (below), and inknotes has no command that deletes anything.

To let it write to notes in iCloud, set `INKNOTES_WRITABLE_ACCOUNTS=iCloud` (or `On My Mac,iCloud`) in the environment your agent runs in.

## Use the CLI directly

Every command prints JSON. Writes only print their plan until you add `--apply`.

```bash
inknotes find "Weekly review"                     # notes by title
inknotes search "release notes"                   # notes by body text, with a snippet
NOTE=$(inknotes find "Weekly review" | jq -r '.notes[0].id')
ROADMAP=$(inknotes find "Roadmap" | jq -r '.notes[0].id')
inknotes read "$NOTE" --format markdown           # the note as Markdown
inknotes backlinks "$NOTE"                        # notes that link here

inknotes create --folder Projects --markdown review.md --apply   # a note from Markdown: to-dos, tags, [[links]], tables
inknotes check "$NOTE" "Publish the skill" --apply              # tick a to-do
inknotes link "$NOTE" "$ROADMAP" --paragraph "Q4 goals" --apply # link to one paragraph of another note
```

Not supported yet: deleting or moving notes, editing table cells, text color, and locked notes.

## More

- [Reference](docs/reference.md): every command, the Markdown it understands, output formats, error codes and limits
- [Development](docs/development.md): building, how a write works, tests
- [Agent skill](skills/use-apple-notes/SKILL.md): what your agent is taught
