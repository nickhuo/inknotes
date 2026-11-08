# inknotes

**Let your AI agent work in Apple Notes the way you do: check off to-dos, tag notes, and link notes to each other.**

Agents can already reach Apple Notes through AppleScript and the tools built on it. That route only sees a note as text and HTML, so an agent can dump text into a note but can't keep a knowledge base there. A to-do comes out as a plain bullet, a `#tag` as plain text, and there is no way to link one note to another, so backlinks never exist.

inknotes edits notes through the same framework Notes.app itself uses. Everything it writes is a real Notes object: a to-do you can tick on your phone, a tag that shows up in the tag browser, a link that opens the other note.

## Before you install

- **Supported platform:** macOS 27.2 on Apple silicon.
- **It can break.** inknotes writes through NotesShared, a private Apple framework with no compatibility promise, so a macOS update can break it. Each call checks that the method it needs exists and fails with `unsupported_macos` if it doesn't. That check can't catch a method that still exists but behaves differently.
- **Your accounts share one file.** On My Mac notes and iCloud notes live in the same database file. Limiting writes to On My Mac keeps inknotes from editing your iCloud notes, but a bug that damaged the file would affect both.
- **Back up first.**

## Get started

You also need **Node.js 22.20 or later** and `npx` to install the agent skill.

**1. Install the CLI and agent skill together**:

```bash
curl -fsSL https://raw.githubusercontent.com/nickhuo/inknotes/main/install.sh | sh
```

This installs the latest CLI to `~/.local/bin/inknotes` and runs `npx skills@1.7.6 add` for the matching release's `use-apple-notes` skill. Run it in a terminal: the skills CLI keeps its native agent picker, installation-method choice, and confirmation prompts, with global scope already selected. The installer verifies GitHub's SHA-256 digest and the binary's version, and replaces an existing CLI only after the binary and skill checks pass. Cancelling the skill installation keeps the previous CLI in place.

Run the same command to update both. To preselect an agent, pass its [skills agent name](https://github.com/vercel-labs/skills/blob/main/docs/agents.md); repeat `--agent` to select several:

```bash
curl -fsSL https://raw.githubusercontent.com/nickhuo/inknotes/main/install.sh | sh -s -- --agent cursor
```

Add `--version v0.4.0` to install a specific release and its matching skill. If installation fails, fix the reported issue and rerun; skill installation may already have written files, but the previous CLI stays in place until all checks pass.

The binary isn't notarized, so macOS may block a copy downloaded in a browser. If `~/.local/bin` isn't on your `PATH`, the installer shows the line to add to `~/.zshrc` before opening a new terminal.

**2. Give your terminal Full Disk Access.** inknotes reads the Notes database directly, so the app that starts it needs this permission.

1. Open System Settings → Privacy &amp; Security → Full Disk Access.
2. Click **+**, choose your terminal app (Terminal is in Applications → Utilities), and turn it on.
3. Quit and reopen the terminal, because the permission applies only to newly started apps.

If your agent runs in a desktop app, add that app the same way. Some apps run commands in a process that doesn't get this access. If so, run inknotes from a terminal that has it.

Without this access, commands fail with `no_access`. Version 0.4.0 instead reports empty results, as if you had no notes; update to 0.5.0 or later for the explicit error.

**3. Ask your agent.** For example:

> Find my notes tagged #weekly, add a to-do "Plan next sprint" to the newest one, and link it to my Roadmap note.

> Write up what we learned today as a note in Research, with a table of the options we compared, and link it to the notes it builds on.

> Which notes link to my Roadmap note?

Three safeguards apply while you try it: every write is a dry run until `--apply` is passed, writes go only to the **On My Mac** account until you allow iCloud, and inknotes has no command that deletes anything.

### Using iCloud

iCloud is supported and opt-in. To let inknotes write to notes in iCloud, set `INKNOTES_WRITABLE_ACCOUNTS=iCloud` (or `On My Mac,iCloud`) in the environment your agent runs in.

## Use the CLI directly

Every command prints JSON, and help prints text. Writes only print their plan until you add `--apply`.

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

## License

[MIT](LICENSE)
