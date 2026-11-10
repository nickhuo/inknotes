// inknotes: read and edit Apple Notes natively through Notes' private NotesShared
// framework. This file holds the commands and dispatches to them; CLI.swift parses
// and validates arguments and renders help.

import Foundation

let version = "0.6.0"

// MARK: - Arguments

extension Args {
    /// The paragraph --after or --index names, or -1 for the end of the note.
    func afterParagraph(_ note: AnyObject) -> Int {
        if options["after"] == nil && options["index"] == nil { return -1 }
        return findParagraph(paragraphsJSON(bodyText(note)), text: options["after"], index: ints["index"])
    }
}

/// The dry-run / apply split every note write follows.
func writeNote(_ a: Args, _ note: AnyObject, plan: [String: Any], reason: String, _ edit: () -> Void) {
    Store.guardWritable(note)
    if !a.apply { emit(["dry_run": true, "plan": plan]); return }
    let snapshot = History.save(note, reason: reason)
    Store.commit(note, reason: reason) { _ in edit() }
    emit(["changed": true, "plan": plan, "note": noteJSON(note), "snapshot": snapshot])
}

// MARK: - Read commands

func cmdFind(_ a: Args) {
    var predicates: [NSPredicate] = []
    if let q = a.positional(0), !q.isEmpty { predicates.append(NSPredicate(format: "title CONTAINS[cd] %@", q)) }
    if let account = a.options["account"] { predicates.append(NSPredicate(format: "account.name ==[c] %@", account)) }
    var notes = Store.visibleNotes(predicates.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: predicates))
    if let f = a.options["folder"] {
        notes = notes.filter { n in
            let folder = kv(n, "folder") as AnyObject?
            return folderPath(folder).caseInsensitiveCompare(f) == .orderedSame || kv(folder, "identifier") as? String == f
        }
    }
    if let tag = a.options["tag"] {
        let standardized = tag.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        let attachments = Store.fetch("ICInlineAttachment", NSPredicate(format: "typeUTI == %@ AND tokenContentIdentifier ==[c] %@ AND markedForDeletion == NO",
                                                                        UTI.hashtag, standardized))
        let tagged = attachments.compactMap { kv($0, "note") as AnyObject? }
        notes = notes.filter { n in tagged.contains { $0 === n } }
    }
    if a.options["pinned"] != nil { notes = notes.filter(isPinned) }
    notes.sort { (kv($0, "modificationDate") as? Date ?? .distantPast) > (kv($1, "modificationDate") as? Date ?? .distantPast) }
    let out = notes.prefix(a.ints["limit"] ?? 20).map(noteSummary)
    emit(["notes": out, "count": out.count, "total": notes.count])
}

func cmdRead(_ a: Args) {
    let note = Store.note(a.positional[0])
    if a.options["format"] == "markdown" { FileHandle.standardOutput.write(Data(markdown(bodyText(note)).utf8)) }
    else { emit(noteJSON(note)) }
}

func cmdBacklinks(_ a: Args) {
    let note = Store.note(a.positional[0])
    let ident = kv(note, "identifier") as? String ?? ""
    let links = Store.fetch("ICInlineAttachment", NSPredicate(format: "typeUTI == %@ AND tokenContentIdentifier CONTAINS[c] %@ AND markedForDeletion == NO",
                                                              UTI.link, ident))
    var out: [[String: Any]] = []
    for link in links {
        guard let source = kv(link, "note") as AnyObject?,
              !(kv(source, "markedForDeletion") as? Bool ?? false), !isTrash(kv(source, "folder") as AnyObject?) else { continue }
        let token = kv(link, "tokenContentIdentifier") as? String ?? ""
        var entry: [String: Any] = ["from": noteSummary(source), "text": kv(link, "displayText") ?? "", "target": token]
        for item in URLComponents(string: token)?.queryItems ?? [] where item.name == "paragraphID" {
            entry["paragraph_id"] = item.value
            for p in paragraphsJSON(bodyText(note)) where p["paragraph_id"] as? String == item.value?.uppercased() {
                entry["paragraph"] = ["index": p["index"]!, "text": p["text"]!]
            }
        }
        // Where the link sits in the source note.
        for p in paragraphsJSON(bodyText(source)) {
            for attachment in p["attachments"] as? [[String: Any]] ?? [] where attachment["id"] as? String == kv(link, "identifier") as? String {
                entry["from_paragraph"] = ["index": p["index"]!, "text": p["text"]!]
            }
        }
        out.append(entry)
    }
    emit(["note": noteSummary(note), "backlinks": out, "count": out.count])
}

func cmdFolders(_ a: Args) {
    var out: [[String: Any]] = []
    for account in Store.allAccounts() {
        let name = kv(account, "name") as? String ?? ""
        if let only = a.options["account"], name.caseInsensitiveCompare(only) != .orderedSame { continue }
        for f in Store.visibleFolders(of: account) {
            out.append(["id": kv(f, "identifier") ?? "", "title": kv(f, "title") ?? "", "path": folderPath(f), "account": name,
                        "parent": kvPath(f, "parent.identifier") ?? NSNull(), "notes": view(f, as: ICFolder.self).visibleNotesCount()])
        }
    }
    out.sort { ($0["account"] as! String, $0["path"] as! String) < ($1["account"] as! String, $1["path"] as! String) }
    emit(["folders": out, "count": out.count])
}

func cmdSearch(_ a: Args) {
    let query = a.positional[0]
    var notes = Store.visibleNotes()
    if let account = a.options["account"] {
        notes = notes.filter { (kvPath($0, "account.name") as? String ?? "").caseInsensitiveCompare(account) == .orderedSame }
    }
    if let f = a.options["folder"] {
        notes = notes.filter { n in
            let folder = kv(n, "folder") as AnyObject?
            return folderPath(folder).caseInsensitiveCompare(f) == .orderedSame || kv(folder, "identifier") as? String == f
        }
    }
    emit(searchResults(notes, query: query, limit: a.ints["limit"] ?? 20,
                       body: { view($0, as: ICNote.self).noteAsPlainText() }, summary: noteSummary))
}

func cmdTags(_ a: Args) {
    let attachments = Store.fetch("ICInlineAttachment", NSPredicate(format: "typeUTI == %@ AND markedForDeletion == NO", UTI.hashtag))
    var byTag: [String: (tag: String, account: String, notes: Set<String>)] = [:]
    for attachment in attachments {
        guard let note = kv(attachment, "note") as AnyObject?,
              !(kv(note, "markedForDeletion") as? Bool ?? false), !isTrash(kv(note, "folder") as AnyObject?) else { continue }
        let account = kvPath(note, "account.name") as? String ?? ""
        if let only = a.options["account"], account.caseInsensitiveCompare(only) != .orderedSame { continue }
        let key = "\(account)|\(kv(attachment, "tokenContentIdentifier") ?? "")"
        var entry = byTag[key] ?? (tag: kv(attachment, "displayText") as? String ?? "", account: account, notes: [])
        entry.notes.insert(kv(note, "identifier") as? String ?? "")
        byTag[key] = entry
    }
    let out: [[String: Any]] = byTag.values
        .sorted { $0.notes.count != $1.notes.count ? $0.notes.count > $1.notes.count : $0.tag < $1.tag }
        .map { ["tag": $0.tag, "account": $0.account, "notes": $0.notes.count] }
    emit(["tags": out, "count": out.count])
}

// MARK: - Write commands

func cmdCheck(_ a: Args) {
    let note = Store.note(a.positional[0])
    let paragraphs = paragraphsJSON(bodyText(note))
    let index = findParagraph(paragraphs, text: a.positional(1), index: a.ints["index"])
    let done = a.options["undo"] == nil
    let p = paragraphs[index]
    guard let todo = p["todo"] as? [String: Any] else { fail("not_a_todo", "Paragraph \(index) is not a checklist item.") }
    let plan: [String: Any] = ["action": done ? "check" : "uncheck", "paragraph": p, "note": noteSummary(note)]
    Store.guardWritable(note)
    if todo["done"] as? Bool == done { emit(["changed": false, "reason": "already in that state", "plan": plan]); return }
    writeNote(a, note, plan: plan, reason: "inknotes check") {
        let text = bodyText(note)
        let range = paragraphRanges(text)[index]
        guard let style = styleAt(text, range.range), let current = style.todo() else { fail("not_a_todo", "Paragraph \(index) is not a checklist item.") }
        // Same to-do identity, new state.
        let updated = (style as AnyObject as! NSObject).mutableCopy() as AnyObject
        view(updated, as: ICTTParagraphStyle.self).setTodo(view(current, as: ICTTTodo.self).todo(done: done))
        setParagraphStyle(note, text, range.enclosing, updated)
    }
}

func cmdSetStyle(_ a: Args) {
    let note = Store.note(a.positional[0])
    let style = a.ints["style"]!
    let paragraphs = paragraphsJSON(bodyText(note))
    let index = findParagraph(paragraphs, text: a.positional(1), index: a.ints["index"])
    let plan: [String: Any] = ["action": "set-style", "style": Style.name(style), "paragraph": paragraphs[index], "note": noteSummary(note)]
    writeNote(a, note, plan: plan, reason: "inknotes set-style") {
        let text = bodyText(note)
        let range = paragraphRanges(text)[index]
        // Keep the paragraph's identity (its UUID), so paragraph links keep working.
        let object = styleAt(text, range.range).map { ($0 as AnyObject as! NSObject).mutableCopy() as AnyObject } ?? newStyle(style)
        let s = view(object, as: ICTTParagraphStyle.self)
        s.setStyle(style)
        if style == Style.checklist { if s.todo() == nil { s.setTodo(newTodo(done: false)) } }
        else { s.setTodo(nil) }
        if style < Style.bullet { s.setIndent(0) }
        if let indent = a.ints["indent"] { s.setIndent(indent) }
        setParagraphStyle(note, text, range.enclosing, object)
    }
}

func cmdFormat(_ a: Args) {
    let note = Store.note(a.positional[0])
    let paragraphs = paragraphsJSON(bodyText(note))
    let index = findParagraph(paragraphs, text: a.positional(1), index: a.ints["index"])
    var changes: [String: Any] = [:]
    for k in ["bold", "italic", "underline", "strike", "plain"] where a.options[k] != nil { changes[k] = true }
    if let highlight = a.ints["highlight"] { changes["highlight"] = highlight }
    if let link = a.options["link"] { changes["link"] = link }
    // The text to format: the whole paragraph, or the first occurrence of --text in it.
    let before = bodyText(note)
    let ns = before.string as NSString
    let p = paragraphRanges(before)[index]
    var target = p.range
    if let sub = a.options["text"] {
        let hit = ns.range(of: sub, range: p.range)
        if hit.location == NSNotFound { fail("text_not_found", "\"\(sub)\" is not in paragraph \(index).") }
        target = hit
    }
    if target.length == 0 { fail("bad_text", "The paragraph is empty.") }
    let plan: [String: Any] = ["action": "format", "changes": changes, "text": ns.substring(with: target), "paragraph": paragraphs[index], "note": noteSummary(note)]
    writeNote(a, note, plan: plan, reason: "inknotes format") {
        let text = bodyText(note)
        text.enumerateAttributes(in: target) { attrs, r, _ in
            if attrs[Key.attachment] != nil { return }
            var m = attrs
            if changes["plain"] != nil { for k in [Key.hints, Key.underline, Key.strike, Key.emphasis, Key.link] { m[k] = nil } }
            let hints = (m[Key.hints] as? Int ?? 0) | (changes["bold"] != nil ? 1 : 0) | (changes["italic"] != nil ? 2 : 0)
            if hints != 0 { m[Key.hints] = hints }
            if changes["underline"] != nil { m[Key.underline] = 1 }
            if changes["strike"] != nil { m[Key.strike] = 1 }
            if let h = changes["highlight"] as? Int { m[Key.emphasis] = h != 0 ? h : nil }
            if let link = changes["link"] as? String { m[Key.link] = URL(string: link) }
            mergeable(note).setAttributes(m, range: r)
        }
    }
}

func cmdAddTodo(_ a: Args) {
    let note = Store.note(a.positional[0])
    let text = a.positional[1]
    if text.contains("\n") { fail("bad_text", "Todo text must be one line.") }
    let paragraphs = paragraphsJSON(bodyText(note))
    var after = a.afterParagraph(note)
    if after < 0, let last = paragraphs.last(where: { $0["todo"] != nil }) { after = last["index"] as! Int }  // after the last to-do
    let plan: [String: Any] = ["action": "add-todo", "text": text, "after_paragraph": after >= 0 ? paragraphs[after] : "end of note", "note": noteSummary(note)]
    writeNote(a, note, plan: plan, reason: "inknotes add-todo") {
        let body = bodyText(note)
        let base = after >= 0 ? styleAt(body, paragraphRanges(body)[after].range) : nil
        let indent = base?.style() == Style.checklist ? base!.indent() : 0
        var refs: [[String: Any]] = []
        let content = parseInline(text, note: note, account: kv(note, "account") as AnyObject?, refs: &refs)
        insertParagraphs(note, after: after, paragraph(content, style: newStyle(Style.checklist, indent: indent), newline: false))
    }
}

func cmdAddTag(_ a: Args) {
    let note = Store.note(a.positional[0])
    let tag = a.positional[1].trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    if tag.isEmpty || tag.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { fail("bad_tag", "A tag is one word without spaces.") }
    let after = a.afterParagraph(note)
    writeNote(a, note, plan: ["action": "add-tag", "tag": "#" + tag, "note": noteSummary(note)], reason: "inknotes add-tag") {
        insertParagraphs(note, after: after, paragraph(makeTag(note, tag), style: newStyle(Style.body), newline: false))
    }
}

func cmdLink(_ a: Args) {
    let note = Store.note(a.positional[0])
    let target = Store.note(a.positional[1])
    let toParagraph = a.options["paragraph"] != nil || a.options["paragraph-index"] != nil
    if note === target && !toParagraph { fail("bad_target", "A note cannot link to itself (link to one of its paragraphs instead).") }
    var targetParagraph: [String: Any]?
    if toParagraph {
        let paragraphs = paragraphsJSON(bodyText(target))
        targetParagraph = paragraphs[findParagraph(paragraphs, text: a.options["paragraph"], index: a.ints["paragraph-index"])]
        if targetParagraph?["paragraph_id"] == nil { fail("bad_target", "That paragraph has no identity to link to.") }
    }
    let after = a.afterParagraph(note)
    let plan: [String: Any] = ["action": toParagraph ? "link-paragraph" : "link", "note": noteSummary(note), "target": noteSummary(target),
                               "target_paragraph": targetParagraph ?? NSNull()]
    writeNote(a, note, plan: plan, reason: "inknotes link") {
        let link = makeNoteLink(note, target, paragraphID: (targetParagraph?["paragraph_id"] as? String).flatMap(UUID.init(uuidString:)),
                                paragraphName: targetParagraph?["text"] as? String)
        insertParagraphs(note, after: after, paragraph(link, style: newStyle(Style.body), newline: false))
    }
}

func cmdAddTable(_ a: Args) {
    let note = Store.note(a.positional[0])
    let tsv = (readInput(a.options["tsv"]) ?? "").trimmingCharacters(in: .newlines)
    if tsv.isEmpty { fail("bad_table", "The table is empty.") }
    let rows = tsv.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
    let after = a.afterParagraph(note)
    writeNote(a, note, plan: ["action": "add-table", "rows": rows, "note": noteSummary(note)], reason: "inknotes add-table") {
        insertParagraphs(note, after: after, paragraph(makeTable(note, rows), style: newStyle(Style.body), newline: false))
    }
}

func cmdAttach(_ a: Args) {
    let note = Store.note(a.positional[0])
    let path = a.positional[1]
    if !FileManager.default.isReadableFile(atPath: (path as NSString).expandingTildeInPath) { fail("file_not_found", "Cannot read \(path).") }
    let after = a.afterParagraph(note)
    writeNote(a, note, plan: ["action": "attach", "file": path, "note": noteSummary(note)], reason: "inknotes attach") {
        insertParagraphs(note, after: after, paragraph(makeFile(note, path), style: newStyle(Style.body), newline: false))
    }
}

func cmdAddURL(_ a: Args) {
    let note = Store.note(a.positional[0])
    let url = a.positional[1]
    if (URL(string: url)?.scheme ?? "").isEmpty { fail("bad_url", "Not a URL: \(url)") }
    let after = a.afterParagraph(note)
    writeNote(a, note, plan: ["action": "add-url", "url": url, "note": noteSummary(note)], reason: "inknotes add-url") {
        insertParagraphs(note, after: after, paragraph(makeURLCard(note, url), style: newStyle(Style.body), newline: false))
    }
}

func cmdPin(_ a: Args) {
    let note = Store.note(a.positional[0])
    let pin = a.options["undo"] == nil
    Store.guardWritable(note)
    let plan: [String: Any] = ["action": pin ? "pin" : "unpin", "note": noteSummary(note)]
    if isPinned(note) == pin { emit(["changed": false, "reason": "already in that state", "plan": plan]); return }
    if !a.apply { emit(["dry_run": true, "plan": plan]); return }
    Store.requireSelectors(note, ["setIsPinned:"])
    let n = view(note, as: ICNote.self)
    n.setIsPinned(pin)
    n.updateChangeCount(reason: pin ? "inknotes pin" : "inknotes unpin")
    Store.saveAndNotify()
    emit(["changed": true, "plan": plan, "note": noteSummary(note)])
}

func cmdCreateFolder(_ a: Args) {
    let title = a.positional[0]
    if title.contains("/") { fail("bad_name", "Folder names cannot contain \"/\"; use --parent for subfolders.") }
    let parent = a.options["parent"].map { Store.folder($0, account: a.options["account"]) }
    let account = parent.map { kv($0, "account") as AnyObject } ?? Store.account(named: a.options["account"] ?? "On My Mac")
    Store.guardAccount(account)
    if isTrash(parent) { fail("bad_parent", "Cannot create a folder in Recently Deleted.") }
    for f in Store.visibleFolders(of: account) where (kv(f, "parent") as AnyObject?) === parent
        && (kv(f, "title") as? String ?? "").caseInsensitiveCompare(title) == .orderedSame {
        fail("folder_exists", "\"\(title)\" already exists there (id \(kv(f, "identifier") ?? "")).")
    }
    let plan: [String: Any] = ["action": "create-folder", "title": title, "account": kv(account, "name") ?? "",
                               "parent": parent.map { folderPath($0) } ?? NSNull()]
    if !a.apply { emit(["dry_run": true, "plan": plan]); return }
    let folders = NotesShared.classObject("ICFolder", as: ICFolderClass.self)
    guard let folder = parent.map({ folders.newFolder(inParent: $0) }) ?? folders.newFolder(inAccount: account) else {
        fail("folder_failed", "Notes did not create the folder.")
    }
    let f = view(folder, as: ICFolder.self)
    f.setTitle(title)
    if responds(folder, "updateChangeCountWithReason:") { f.updateChangeCount(reason: "inknotes create-folder") }
    Store.saveAndNotify()
    emit(["changed": true, "plan": plan, "folder": ["id": kv(folder, "identifier") ?? "", "path": folderPath(folder)]])
}

func cmdCreate(_ a: Args) {
    let folder = Store.folder(a.options["folder"] ?? "Notes", account: a.options["account"])
    let account = kv(folder, "account") as AnyObject
    Store.guardAccount(account)
    if isTrash(folder) { fail("bad_folder", "Cannot create a note in Recently Deleted.") }
    let blocks = parseMarkdown(readInput(a.options["markdown"]) ?? "")
    if blocks.isEmpty { fail("usage", "The Markdown is empty.") }
    let plan: [String: Any] = ["action": "create", "folder": folderPath(folder), "account": kv(account, "name") ?? "",
                               "blocks": planBlocks(blocks, account: account)]
    if !a.apply { emit(["dry_run": true, "plan": plan]); return }
    guard let note = NotesShared.classObject("ICNote", as: ICNoteClass.self).newEmptyNote(in: folder) else {
        fail("create_failed", "Notes did not create the note.")
    }
    Store.commit(note, reason: "inknotes create") { _ in insertParagraphs(note, after: -1, renderBlocks(blocks, note: note, account: account)) }
    emit(["changed": true, "plan": plan, "note": noteJSON(note)])
}

func cmdAppend(_ a: Args) {
    let note = Store.note(a.positional[0])
    let blocks = parseMarkdown(readInput(a.options["markdown"]) ?? "")
    if blocks.isEmpty { fail("usage", "The Markdown is empty.") }
    let account = kv(note, "account") as AnyObject
    let after = a.afterParagraph(note)
    let plan: [String: Any] = ["action": "append", "blocks": planBlocks(blocks, account: account), "note": noteSummary(note)]
    writeNote(a, note, plan: plan, reason: "inknotes append") { insertParagraphs(note, after: after, renderBlocks(blocks, note: note, account: account)) }
}

func cmdEdit(_ a: Args) {
    let note = Store.note(a.positional[0])
    let paragraphs = paragraphsJSON(bodyText(note))
    let first = findParagraph(paragraphs, text: a.positional(1), index: a.ints["index"])
    let count = a.ints["count"] ?? 1
    if first + count > paragraphs.count { fail("bad_index", "--count \(count) from paragraph \(first) runs past the last paragraph (\(paragraphs.count - 1)).") }
    let blocks = parseMarkdown(readInput(a.options["markdown"]) ?? "")
    if blocks.isEmpty { fail("usage", "The Markdown is empty.") }
    let account = kv(note, "account") as AnyObject
    let plan: [String: Any] = ["action": "edit", "replaces": Array(paragraphs[first..<first + count]),
                               "blocks": planBlocks(blocks, account: account), "note": noteSummary(note)]
    writeNote(a, note, plan: plan, reason: "inknotes edit") {
        let text = bodyText(note)
        let ranges = paragraphRanges(text)
        let last = ranges[first + count - 1]
        let start = ranges[first].enclosing.location
        let content = NSMutableAttributedString(attributedString: renderBlocks(blocks, note: note, account: account))
        // Paragraph links to the first replaced paragraph keep working.
        if let uuid = styleAt(text, ranges[first].range)?.uuid(), let style = content.attribute(Key.style, at: 0, effectiveRange: nil) {
            view(style as AnyObject, as: ICTTParagraphStyle.self).setUUID(uuid)
        }
        // Text follows the replaced paragraphs: the new block must end with a newline too.
        if NSMaxRange(last.enclosing) > NSMaxRange(last.range) {
            let style = content.attribute(Key.style, at: content.length - 1, effectiveRange: nil)
            content.append(NSAttributedString(string: "\n", attributes: style.map { [Key.style: $0] } ?? [:]))
        }
        replaceText(note, NSRange(location: start, length: NSMaxRange(last.enclosing) - start), with: content)
    }
}

func cmdHistory(_ a: Args) {
    let note = Store.note(a.positional[0])
    let snapshots = History.files(note).reversed().map { History.summary(History.load($0)) }
    emit(["note": noteSummary(note), "snapshots": snapshots, "count": snapshots.count])
}

func cmdRestore(_ a: Args) {
    let note = Store.note(a.positional[0])
    let files = History.files(note)
    let file: URL
    if let id = a.positional(1) {
        guard let match = files.first(where: { $0.deletingPathExtension().lastPathComponent == id }) else {
            fail("snapshot_not_found", "No snapshot \(id) for this note. Run `inknotes history <note>`.")
        }
        file = match
    } else {
        guard let latest = files.last else { fail("snapshot_not_found", "This note has no snapshots.") }
        file = latest
    }
    // Loaded before writeNote saves a new snapshot, which may prune this one.
    let snapshot = History.load(file)
    var plan: [String: Any] = ["action": "restore", "snapshot": History.summary(snapshot), "markdown": markdown(snapshot.text), "note": noteSummary(note)]
    // Notes may have purged an attachment since; its character would come back empty.
    let missing = attachmentObjects(snapshot.text).filter { $0.object == nil }.map(\.id)
    if !missing.isEmpty { plan["missing_attachments"] = missing }
    writeNote(a, note, plan: plan, reason: "inknotes restore") {
        replaceText(note, NSRange(location: 0, length: bodyText(note).length), with: snapshot.text)
    }
}

// MARK: - Main

let handlers: [String: (Args) -> Void] = [
    "find": cmdFind, "search": cmdSearch, "read": cmdRead, "backlinks": cmdBacklinks, "folders": cmdFolders, "tags": cmdTags,
    "history": cmdHistory, "edit": cmdEdit, "restore": cmdRestore, "check": cmdCheck, "set-style": cmdSetStyle, "format": cmdFormat, "add-todo": cmdAddTodo, "add-tag": cmdAddTag,
    "link": cmdLink, "add-table": cmdAddTable, "attach": cmdAttach, "add-url": cmdAddURL,
    "pin": cmdPin, "create-folder": cmdCreateFolder, "create": cmdCreate, "append": cmdAppend,
]

let args = Args(Array(CommandLine.arguments.dropFirst()))
if args.helpRequested {
    let help = args.command.map { CommandSpec.named($0).help } ?? CommandSpec.rootHelp
    FileHandle.standardOutput.write(Data(help.utf8))
} else if args.command == "version" {
    emit(["version": version])
} else {
    guard let command = args.command, let run = handlers[command] else { fatalError("Every command needs a handler.") }
    // Reads and dry runs open read-only.
    Store.open(writable: CommandSpec.named(command).writes && args.apply)
    Store.moc.performAndWait { run(args) }
}
