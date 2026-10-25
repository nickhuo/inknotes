# Checking off Apple Notes to-dos from outside Notes: what's proven

Spike run on 2026-10-25, macOS 27.2 (build 26B5112a), against one test note in the On My Mac account.

**Bottom line:** a separate program on this Mac can mark a native Apple Notes to-do as done, using the private framework Notes itself uses. Notes.app shows the change, live if it's open, and keeps it. Whether that change reaches iCloud and your other devices is untested, and that's the biggest open question.

## What's proven

| Claim | Evidence |
|---|---|
| We can open Notes' own data model **read-only** and see what AppleScript can't: paragraph styles and each to-do's done state and identity. | The probe opened the store with every store reporting read-only, and printed `style=103 todo.done=0/1` plus a UUID for each checklist item. |
| We can **mark a to-do done while Notes.app is closed**, and Notes shows it on next launch. | "beta": the database read back `done=1` with the same UUID. You reopened Notes and saw it checked. |
| We can **mark a to-do done while Notes.app has that note open**, and Notes updates the screen by itself without overwriting the change. | "gamma": still `done=1` 45 s later, after Notes saved again. You saw it checked without touching anything. |
| Our writes **touched only the test note**. | A fingerprint of every other object and every other note body was identical before and after each write. |
| The to-do keeps its identity. Notes treats it as the same item, not a new one. | The UUID is unchanged after every write. |

### How a write works

```
1. Load Notes' private framework (NotesShared) into our own program
2. Open Notes' database through it            ← same database Notes.app uses
3. Find the note; refuse unless it's in On My Mac / "NotesShared Smoke Test"
4. Find the paragraph "gamma"; refuse unless it's an unchecked checklist item
5. Give it the same to-do, now marked done
6. Mark the note as edited (modification date + change count), save
7. Tell running Notes processes "another process saved"   ← what Notes' own editor extension does
```

## What we learned the hard way

- **Notes.app overwrote the first write.** The note was open, and Notes saved its stale in-memory copy over ours. Notes did notice the change: auto-sort moved beta to the bottom. It then put the old unchecked state back. Steps 6 and 7 above fixed it. Both were added at once, so we don't know which one is actually required.
- **On My Mac isn't fully isolated.** It lives in the same database file as your iCloud notes. It avoids iCloud sync, but a bug that damages the database itself would hit both accounts. That's why we backed up first.
- **Permissions:** reading Notes' database needs Full Disk Access. After granting it to Claude.app and restarting, only Claude's terminal panel got access. Claude's own shell runs as a separate program and still can't read the database.
- **Notes changes things on its own.** While Notes.app was running, it bumped change counters on about a dozen objects (some iCloud notes, both accounts, folders), with no change to their modification dates. It also purged 15 attachments that were already marked for deletion. None of this happened during our writes. It looks like routine bookkeeping, but it hasn't been checked row by row.

## What's left, highest risk first

1. **iCloud sync.** Does a change written outside Notes get uploaded to iCloud and show up on the iPhone? Notes' sync code runs inside Notes.app, and our program can't sync by itself. This is the biggest open question.
2. **Which fix is required.** Test step 6 and step 7 separately to find the smallest write path that works.
3. **Unchecking, and editing while typing.** We only tested marking items done, and never while someone was typing in the note.
4. **Everything besides to-dos:** creating checklist items, tags, links between notes, tables, formatting. Each is a separate write path that needs its own test.
5. **Surviving macOS updates.** Everything here comes from inspecting macOS 27.2. Every private call needs a check that the method still exists, and should stop if it doesn't.
6. **Packaging.** For daily use it would need a small signed app that holds the permissions, like RemCTL's Capability Host, so permissions don't depend on which terminal runs the tool.

## Current state of your Mac

- Backup: `~/Downloads/NoteStore-backup-20261025-011850.sqlite` (103 MB, integrity checked). A leftover `…sqlite-shm` file of 32 KB next to it is harmless and can be deleted.
- Test data: the folder "NotesShared Smoke Test" with the note "NotesShared smoke test" in On My Mac. beta and gamma are checked, alpha is unchecked. Safe to delete when you're done.
- Full Disk Access is still granted to Claude.app. You can revoke it in System Settings → Privacy & Security → Full Disk Access.

---

## Appendix: details for whoever builds this next

Exact identifiers, macOS 27.2. All found by disassembling `NotesShared.framework` at runtime.

**Opening a context**
- `+[ICNoteContext startSharedContextWithOptions:]`, then `+sharedContext` and `-managedObjectContext`.
- Option `0x40` → `-initWithOptions:` calls `setIsReadOnlyPersistentStore:`. Every store reports `isReadOnly=1`.
- Option `0` → a writable context with `crossProcessChangeCoordinator` set up.
- `startSharedContextWithOptions:` calls `resetAppState` / `resetAppContainer` / `useContainerNamed:` / `enableLocalAccount` only when `+[ICLaunchConfiguration currentConfiguration]` asks for it. In a plain process: `resetsState=0, resetsContainer=0, environment=0, container=nil`.

**Data model**
- Note lookup: `-[NSPersistentStoreCoordinator managedObjectIDForURIRepresentation:]` with the AppleScript id, for example `x-coredata://CE49A08E-…/ICNote/p21300`.
- Body: `-[ICNote mergeableString]` returns an `ICTTMergeableAttributedString`, a CRDT. Paragraph style attribute key: `TTStyle` (`ICTTParagraphStyle`).
- Styles seen: `3` title, `100` bulleted list, `103` checklist. Checklist state: `-[ICTTParagraphStyle todo]` returns an `ICTTTodo` with `uuid` and `done`.

**The write**
```
todo2 = [[ICTTTodo alloc] initWithIdentifier:todo.uuid done:YES]
style2 = [style mutableCopy]; [style2 setTodo:todo2]
[note beginEditing]; [mergeableString setAttributes:attrs range:paragraphRange]; [note endEditing]
[note didChangeNoteText]; [note saveNoteData]
[note setValue:NSDate.date forKey:@"modificationDate"]
[note updateChangeCountWithReason:@"…"]
[ctx save]
[ctx.crossProcessChangeCoordinator postEditorExtensionDidSaveNotification]   // posts ICEditorExtensionDidSaveNotification
```

**Files**

The spike's tools (`spike/probe.m`, `toggle.m`, `dump.m`, `survey.m`, `emphasis.m`, and the fingerprint scripts) were folded into `nnote` and its e2e tests, and removed. They are in the first commit (`9f69448`). `scripts/backup-notestore.sh` remains: a consistent `sqlite3 .backup` of the store into `~/Downloads`, with an integrity check.

**Test container (found later):** `+[ICNoteContext useContainerNamed:]` moves Notes' whole store to `…/group.com.apple.notes/Containers/<name>/NoteStore.sqlite`, the mechanism behind Notes' own UI-test launch arguments (`-Container X -ResetContainer 1`). `+[ICAccount newLocalAccountInContext:]` gives a fresh container an On My Mac account. (`+[ICNoteContext enableLocalAccount]` only sets the shared `LocalNotes` preference, so `nnote` doesn't call it.) The e2e tests run in such a container.

**Related prior art:** NotesCTL (Federico Viticci, MacStories) is a closed preview with an open-source release announced. RemCTL (`viticci/remctl`, open source) uses the same overall design for Reminders: a signed host app holds the permissions, reads go straight to SQLite, writes go through Apple's private framework, and it never writes the database directly.
