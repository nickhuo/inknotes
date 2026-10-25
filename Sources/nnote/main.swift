// nnote: read and edit Apple Notes natively through Notes' private NotesShared
// framework. This file is the command-line interface: arguments, commands, help.

import Foundation

let version = "0.3.0"

// MARK: - Arguments

struct Args {
    var command: String?
    var positional: [String] = []
    var options: [String: String] = [:]
    var apply = false

    static let flags: Set<String> = ["undo", "bold", "italic", "underline", "strike", "plain"]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let s = argv[i]
            if s == "--apply" { apply = true }
            else if s.hasPrefix("--"), Args.flags.contains(String(s.dropFirst(2))) { options[String(s.dropFirst(2))] = "1" }
            else if s.hasPrefix("--"), i + 1 < argv.count { options[String(s.dropFirst(2))] = argv[i + 1]; i += 1 }
            else if s.hasPrefix("--") { fail("usage", "\(s) needs a value.") }
            else if command == nil { command = s }
            else { positional.append(s) }
            i += 1
        }
    }

    func need(_ i: Int, _ what: String) -> String {
        if positional.count <= i { fail("usage", "Missing \(what). Run `nnote help`.") }
        return positional[i]
    }

    func positional(_ i: Int) -> String? { positional.count > i ? positional[i] : nil }

    /// The paragraph --after or --index names, or -1 for the end of the note.
    func afterParagraph(_ note: AnyObject) -> Int {
        if options["after"] == nil && options["index"] == nil { return -1 }
        return findParagraph(paragraphsJSON(bodyText(note)), text: options["after"], index: options["index"])
    }
}

/// The dry-run / apply split every note write follows.
func writeNote(_ a: Args, _ note: AnyObject, plan: [String: Any], reason: String, _ edit: () -> Void) {
    Store.guardWritable(note)
    if !a.apply { emit(["dry_run": true, "plan": plan]); return }
    Store.commit(note, reason: reason) { _ in edit() }
    emit(["changed": true, "plan": plan, "note": noteJSON(note)])
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
    let limit = a.options["limit"].flatMap { Int($0) } ?? 20
    let out = notes.prefix(max(limit, 0)).map(noteSummary)
    emit(["notes": out, "count": out.count, "total": notes.count])
}

func cmdRead(_ a: Args) {
    let note = Store.note(a.need(0, "note"))
    if a.options["format"] == "markdown" { FileHandle.standardOutput.write(Data(noteMarkdown(note).utf8)) }
    else { emit(noteJSON(note)) }
}

func cmdBacklinks(_ a: Args) {
    let note = Store.note(a.need(0, "note"))
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
    let note = Store.note(a.need(0, "note"))
    let paragraphs = paragraphsJSON(bodyText(note))
    let index = findParagraph(paragraphs, text: a.positional(1), index: a.options["index"])
    let done = a.options["undo"] == nil
    let p = paragraphs[index]
    guard let todo = p["todo"] as? [String: Any] else { fail("not_a_todo", "Paragraph \(index) is not a checklist item.") }
    let plan: [String: Any] = ["action": done ? "check" : "uncheck", "paragraph": p, "note": noteSummary(note)]
    Store.guardWritable(note)
    if todo["done"] as? Bool == done { emit(["changed": false, "reason": "already in that state", "plan": plan]); return }
    writeNote(a, note, plan: plan, reason: "nnote check") {
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
    let note = Store.note(a.need(0, "note"))
    let styleArg = a.options["style"] ?? a.positional(2)
    guard let style = styleArg.flatMap({ Style.names[$0.lowercased()] }) else {
        fail("bad_style", "Style must be one of: \(Style.names.keys.joined(separator: ", ")).")
    }
    let paragraphs = paragraphsJSON(bodyText(note))
    let index = findParagraph(paragraphs, text: a.positional(1), index: a.options["index"])
    let plan: [String: Any] = ["action": "set-style", "style": styleArg!.lowercased(), "paragraph": paragraphs[index], "note": noteSummary(note)]
    writeNote(a, note, plan: plan, reason: "nnote set-style") {
        let text = bodyText(note)
        let range = paragraphRanges(text)[index]
        // Keep the paragraph's identity (its UUID), so paragraph links keep working.
        let object = styleAt(text, range.range).map { ($0 as AnyObject as! NSObject).mutableCopy() as AnyObject } ?? newStyle(style)
        let s = view(object, as: ICTTParagraphStyle.self)
        s.setStyle(style)
        if style == Style.checklist { if s.todo() == nil { s.setTodo(newTodo(done: false)) } }
        else { s.setTodo(nil) }
        if style < Style.bullet { s.setIndent(0) }
        if let indent = a.options["indent"] { s.setIndent(Int(indent) ?? 0) }
        setParagraphStyle(note, text, range.enclosing, object)
    }
}

func cmdFormat(_ a: Args) {
    let note = Store.note(a.need(0, "note"))
    let paragraphs = paragraphsJSON(bodyText(note))
    let index = findParagraph(paragraphs, text: a.positional(1), index: a.options["index"])
    var changes: [String: Any] = [:]
    for k in ["bold", "italic", "underline", "strike", "plain"] where a.options[k] != nil { changes[k] = true }
    if let h = a.options["highlight"] {
        let value = Highlight.value(h)
        if value < 0 { fail("bad_highlight", "--highlight takes purple, pink, orange, mint or blue (or 1-5), or none to remove it.") }
        changes["highlight"] = value
    }
    if let link = a.options["link"] {
        if link.isEmpty || URL(string: link)?.scheme == nil { fail("bad_url", "--link needs a full URL.") }
        changes["link"] = link
    }
    if changes.isEmpty { fail("usage", "Pass at least one of --bold --italic --underline --strike --highlight N --link URL --plain.") }
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
    writeNote(a, note, plan: plan, reason: "nnote format") {
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
    let note = Store.note(a.need(0, "note"))
    let text = a.need(1, "todo text")
    if text.contains("\n") { fail("bad_text", "Todo text must be one line.") }
    let paragraphs = paragraphsJSON(bodyText(note))
    var after = a.afterParagraph(note)
    if after < 0, let last = paragraphs.last(where: { $0["todo"] != nil }) { after = last["index"] as! Int }  // after the last to-do
    let plan: [String: Any] = ["action": "add-todo", "text": text, "after_paragraph": after >= 0 ? paragraphs[after] : "end of note", "note": noteSummary(note)]
    writeNote(a, note, plan: plan, reason: "nnote add-todo") {
        let body = bodyText(note)
        let base = after >= 0 ? styleAt(body, paragraphRanges(body)[after].range) : nil
        let indent = base?.style() == Style.checklist ? base!.indent() : 0
        var refs: [[String: Any]] = []
        let content = parseInline(text, note: note, account: kv(note, "account") as AnyObject?, refs: &refs)
        insertParagraphs(note, after: after, paragraph(content, style: newStyle(Style.checklist, indent: indent), newline: false))
    }
}

func cmdAddTag(_ a: Args) {
    let note = Store.note(a.need(0, "note"))
    let tag = a.need(1, "tag").trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    if tag.isEmpty || tag.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { fail("bad_tag", "A tag is one word without spaces.") }
    let after = a.afterParagraph(note)
    writeNote(a, note, plan: ["action": "add-tag", "tag": "#" + tag, "note": noteSummary(note)], reason: "nnote add-tag") {
        insertParagraphs(note, after: after, paragraph(makeTag(note, tag), style: newStyle(Style.body), newline: false))
    }
}

func cmdLink(_ a: Args) {
    let note = Store.note(a.need(0, "note"))
    let target = Store.note(a.need(1, "target note"))
    let toParagraph = a.options["paragraph"] != nil || a.options["paragraph-index"] != nil
    if note === target && !toParagraph { fail("bad_target", "A note cannot link to itself (link to one of its paragraphs instead).") }
    var targetParagraph: [String: Any]?
    if toParagraph {
        let paragraphs = paragraphsJSON(bodyText(target))
        targetParagraph = paragraphs[findParagraph(paragraphs, text: a.options["paragraph"], index: a.options["paragraph-index"])]
        if targetParagraph?["paragraph_id"] == nil { fail("bad_target", "That paragraph has no identity to link to.") }
    }
    let after = a.afterParagraph(note)
    let plan: [String: Any] = ["action": toParagraph ? "link-paragraph" : "link", "note": noteSummary(note), "target": noteSummary(target),
                               "target_paragraph": targetParagraph ?? NSNull()]
    writeNote(a, note, plan: plan, reason: "nnote link") {
        let link = makeNoteLink(note, target, paragraphID: (targetParagraph?["paragraph_id"] as? String).flatMap(UUID.init(uuidString:)),
                                paragraphName: targetParagraph?["text"] as? String)
        insertParagraphs(note, after: after, paragraph(link, style: newStyle(Style.body), newline: false))
    }
}

func cmdAddTable(_ a: Args) {
    let note = Store.note(a.need(0, "note"))
    guard let source = a.options["tsv"] else { fail("usage", "Pass --tsv <file>, or --tsv - to read stdin. Rows are lines, cells are tab-separated.") }
    let tsv = (readInput(source) ?? "").trimmingCharacters(in: .newlines)
    if tsv.isEmpty { fail("bad_table", "The table is empty.") }
    let rows = tsv.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
    let after = a.afterParagraph(note)
    writeNote(a, note, plan: ["action": "add-table", "rows": rows, "note": noteSummary(note)], reason: "nnote add-table") {
        insertParagraphs(note, after: after, paragraph(makeTable(note, rows), style: newStyle(Style.body), newline: false))
    }
}

func cmdAttach(_ a: Args) {
    let note = Store.note(a.need(0, "note"))
    let path = a.need(1, "file")
    if !FileManager.default.isReadableFile(atPath: (path as NSString).expandingTildeInPath) { fail("file_not_found", "Cannot read \(path).") }
    let after = a.afterParagraph(note)
    writeNote(a, note, plan: ["action": "attach", "file": path, "note": noteSummary(note)], reason: "nnote attach") {
        insertParagraphs(note, after: after, paragraph(makeFile(note, path), style: newStyle(Style.body), newline: false))
    }
}

func cmdAddURL(_ a: Args) {
    let note = Store.note(a.need(0, "note"))
    let url = a.need(1, "URL")
    if (URL(string: url)?.scheme ?? "").isEmpty { fail("bad_url", "Not a URL: \(url)") }
    let after = a.afterParagraph(note)
    writeNote(a, note, plan: ["action": "add-url", "url": url, "note": noteSummary(note)], reason: "nnote add-url") {
        insertParagraphs(note, after: after, paragraph(makeURLCard(note, url), style: newStyle(Style.body), newline: false))
    }
}

func cmdDraw(_ a: Args) {
    let note = Store.note(a.need(0, "note"))
    guard let svg = a.options["svg"] else { fail("usage", "Pass --svg <file>.") }
    let options = ["width": a.options["width"] ?? "400", "ink": a.options["ink"] ?? "pen", "color": a.options["color"] ?? ""]
    let stats: [String: Any]
    switch drawingFromSVG(path: (svg as NSString).expandingTildeInPath, width: Double(options["width"]!) ?? 0, color: options["color"], ink: options["ink"]!) {
    case .success(let (_, s)): stats = s
    case .failure(let error): fail("bad_svg", error.message)
    }
    let after = a.afterParagraph(note)
    let plan: [String: Any] = ["action": "draw", "svg": svg, "drawing": stats, "options": options, "note": noteSummary(note)]
    writeNote(a, note, plan: plan, reason: "nnote draw") {
        let object = makeDrawing(note, svg: svg, options: options)
        let attachment = object.attribute(Key.attachment, at: 0, effectiveRange: nil) as AnyObject
        // The paper helper may place the attachment in the text itself.
        if !textHasAttachment(note, view(attachment, as: ICTTAttachment.self).attachmentIdentifier() ?? "") {
            insertParagraphs(note, after: after, paragraph(object, style: newStyle(Style.body), newline: false))
        }
    }
}

func cmdPin(_ a: Args) {
    let note = Store.note(a.need(0, "note"))
    let pin = a.options["undo"] == nil
    Store.guardWritable(note)
    let plan: [String: Any] = ["action": pin ? "pin" : "unpin", "note": noteSummary(note)]
    if isPinned(note) == pin { emit(["changed": false, "reason": "already in that state", "plan": plan]); return }
    if !a.apply { emit(["dry_run": true, "plan": plan]); return }
    Store.requireSelectors(note, ["setIsPinned:"])
    let n = view(note, as: ICNote.self)
    n.setIsPinned(pin)
    n.updateChangeCount(reason: pin ? "nnote pin" : "nnote unpin")
    Store.saveAndNotify()
    emit(["changed": true, "plan": plan, "note": noteSummary(note)])
}

func cmdCreateFolder(_ a: Args) {
    let title = a.need(0, "folder name")
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
    if responds(folder, "updateChangeCountWithReason:") { f.updateChangeCount(reason: "nnote create-folder") }
    Store.saveAndNotify()
    emit(["changed": true, "plan": plan, "folder": ["id": kv(folder, "identifier") ?? "", "path": folderPath(folder)]])
}

func cmdCreate(_ a: Args) {
    let folder = Store.folder(a.options["folder"] ?? "Notes", account: a.options["account"])
    let account = kv(folder, "account") as AnyObject
    Store.guardAccount(account)
    if isTrash(folder) { fail("bad_folder", "Cannot create a note in Recently Deleted.") }
    var markdown = readInput(a.options["markdown"]) ?? ""
    if let title = a.options["title"] ?? a.positional(0) { markdown = "# \(title)\n\(markdown)" }
    let blocks = parseMarkdown(markdown)
    if blocks.isEmpty { fail("usage", "Give the note a title or --markdown content.") }
    let plan: [String: Any] = ["action": "create", "folder": folderPath(folder), "account": kv(account, "name") ?? "",
                               "blocks": planBlocks(blocks, account: account)]
    if !a.apply { emit(["dry_run": true, "plan": plan]); return }
    guard let note = NotesShared.classObject("ICNote", as: ICNoteClass.self).newEmptyNote(in: folder) else {
        fail("create_failed", "Notes did not create the note.")
    }
    Store.commit(note, reason: "nnote create") { _ in insertParagraphs(note, after: -1, renderBlocks(blocks, note: note, account: account)) }
    emit(["changed": true, "plan": plan, "note": noteJSON(note)])
}

func cmdAppend(_ a: Args) {
    let note = Store.note(a.need(0, "note"))
    guard let markdown = readInput(a.options["markdown"]) else { fail("usage", "Pass --markdown <file>, or --markdown - to read stdin.") }
    let blocks = parseMarkdown(markdown)
    if blocks.isEmpty { fail("usage", "The Markdown is empty.") }
    let account = kv(note, "account") as AnyObject
    let after = a.afterParagraph(note)
    let plan: [String: Any] = ["action": "append", "blocks": planBlocks(blocks, account: account), "note": noteSummary(note)]
    writeNote(a, note, plan: plan, reason: "nnote append") { insertParagraphs(note, after: after, renderBlocks(blocks, note: note, account: account)) }
}

// MARK: - Main

let help = """
nnote: read and edit Apple Notes natively.
Every command prints JSON. Write commands are dry runs unless --apply is given.
Writes only touch notes in NNOTE_WRITABLE_ACCOUNTS (comma-separated, default "On My Mac").
<note> is a note id (UUID), an x-coredata:// URI, or a numeric primary key. <item> is a paragraph's text.
Placement: --after <item> or --index N puts new content after that paragraph; otherwise at the end.

Read
  find [text] [--folder PATH|ID] [--account A] [--tag T] [--pinned 1] [--limit N]
  read <note> [--format json|markdown]
  backlinks <note>                       notes that link to this note or its paragraphs
  folders [--account A]                  folders and subfolders with paths and note counts
  tags [--account A]                     tags with the number of notes using each

Write
  create [title] [--folder PATH|ID] [--account A] [--markdown FILE|-]   new note from Markdown
  append <note> --markdown FILE|-        add Markdown content
  create-folder <name> [--parent PATH|ID] [--account A]
  pin <note> [--undo]
  set-style <note> <item> <title|heading|subheading|body|monospaced|bullet|dash|numbered|checklist> [--index N] [--indent N]
  format <note> <item> [--index N] [--text SUBSTRING] [--bold] [--italic] [--underline] [--strike]
         [--highlight purple|pink|orange|mint|blue|none] [--link URL] [--plain]
  check <note> <item> [--index N] [--undo]
  add-todo <note> <text>
  add-tag <note> <tag>
  link <note> <target note> [--paragraph <target item> | --paragraph-index N]
  add-table <note> --tsv FILE|-
  add-url <note> <url>                   a link card
  attach <note> <file>                   an image, PDF or other file
  draw <note> --svg FILE [--width PT] [--ink pen|pencil|marker] [--color #rrggbb]   a native, editable drawing

Markdown: # ## ### headings, paragraphs, - lists, 1. lists, - [ ] / - [x] to-dos, > quotes, ``` code,
**bold** *italic* ~~strike~~ ==highlight== =={pink}highlight== [text](url), #tags, [[Note title]] and [[Note title#Paragraph]] links,
| tables |, --- dividers, ![](file) attachments, ![](drawing.svg) drawings, and a URL alone on a line as a link card.

Needs Full Disk Access for the process that runs it. Built against macOS 27.2.

"""

let reads: [String: (Args) -> Void] = ["find": cmdFind, "read": cmdRead, "backlinks": cmdBacklinks, "folders": cmdFolders, "tags": cmdTags]
let writes: [String: (Args) -> Void] = [
    "check": cmdCheck, "set-style": cmdSetStyle, "format": cmdFormat, "add-todo": cmdAddTodo, "add-tag": cmdAddTag,
    "link": cmdLink, "add-table": cmdAddTable, "attach": cmdAttach, "add-url": cmdAddURL, "draw": cmdDraw,
    "pin": cmdPin, "create-folder": cmdCreateFolder, "create": cmdCreate, "append": cmdAppend,
]

let args = Args(Array(CommandLine.arguments.dropFirst()))
switch args.command {
case nil, "help", "--help":
    FileHandle.standardOutput.write(Data(help.utf8))
case "version":
    emit(["version": version])
case let command?:
    guard let run = reads[command] ?? writes[command] else { fail("usage", "Unknown command \"\(command)\". Run `nnote help`.") }
    // Reads and dry runs open the store read-only.
    Store.open(writable: writes[command] != nil && args.apply)
    Store.moc.performAndWait { run(args) }
}
