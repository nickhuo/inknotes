// A note's text: reading it as paragraphs, and the primitives for editing it.
//
// Paragraph JSON: {index, text, style, paragraph_id, indent?, quote?, todo?,
// attachments?, formats?}. `text` shows tags and links by their displayed
// text and other attachments as "[type]". `paragraph_id` is the paragraph
// style's UUID, which paragraph links point to.

import Foundation

/// A paragraph's range without and with its trailing newline.
struct Para {
    let range: NSRange
    let enclosing: NSRange
}

func mergeable(_ note: AnyObject) -> ICTTMergeableString {
    guard let ms = view(note, as: ICNote.self).mergeableString() else { fail("unsupported_macos", "The note has no text object.") }
    return view(ms, as: ICTTMergeableString.self)
}

func bodyText(_ note: AnyObject) -> NSAttributedString { mergeable(note).attributedString() }

/// Returns nil instead of exiting when a note has no text object (e.g. attachment-only notes).
func bodyTextSafe(_ note: AnyObject) -> NSAttributedString? {
    guard let ms = view(note, as: ICNote.self).mergeableString() else { return nil }
    return view(ms, as: ICTTMergeableString.self).attributedString()
}

func paragraphRanges(_ text: NSAttributedString) -> [Para] {
    var out: [Para] = []
    (text.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                                  options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
        out.append(Para(range: range, enclosing: enclosing))
    }
    return out
}

/// The ICTTParagraphStyle at `range`.
func styleAt(_ text: NSAttributedString, _ range: NSRange) -> ICTTParagraphStyle? {
    guard text.length > 0, let style = text.attribute(Key.style, at: min(range.location, text.length - 1), effectiveRange: nil) else { return nil }
    return view(style as AnyObject, as: ICTTParagraphStyle.self)
}

func quoteLevel(_ style: ICTTParagraphStyle?) -> Int {
    guard let style, responds(style as AnyObject, "blockQuoteLevel") else { return 0 }
    return style.blockQuoteLevel()
}

private func type(forUTI uti: String) -> String {
    switch uti {
    case UTI.hashtag: return "tag"
    case UTI.link: return "link"
    case UTI.table: return "table"
    case UTI.url: return "url"
    default:
        if uti.hasPrefix("com.apple.paper") || uti.hasPrefix("com.apple.drawing") { return "drawing" }
        if uti.hasPrefix(UTI.inlinePrefix) { return String(uti.dropFirst(UTI.inlinePrefix.count)) }
        return "file"
    }
}

/// {id, uti, type, text?, target?, rows?, url?, title?}
func attachmentInfo(_ ttAttachment: AnyObject) -> [String: Any] {
    let tt = view(ttAttachment, as: ICTTAttachment.self)
    let uti = tt.attachmentUTI() ?? ""
    var info: [String: Any] = ["id": tt.attachmentIdentifier() ?? "", "uti": uti, "type": type(forUTI: uti)]
    if uti.hasPrefix(UTI.inlinePrefix) {
        if let inline = tt.inlineAttachment(in: Store.moc) {
            info["text"] = kv(inline, "displayText") ?? ""
            if uti == UTI.link { info["target"] = kv(inline, "tokenContentIdentifier") ?? "" }
        }
        return info
    }
    guard let attachment = tt.attachment(in: Store.moc) else { return info }
    let att = view(attachment, as: ICAttachment.self)
    if uti == UTI.table {
        if let model = att.tableModel(), let tableObject = view(model, as: ICAttachmentTableModel.self).table(),
           responds(tableObject, "rowCount"), responds(tableObject, "columnCount") {
            let table = view(tableObject, as: ICTable.self)
            info["rows"] = (0..<table.rowCount()).map { r in
                (0..<table.columnCount()).map { c -> String in
                    let cell = table.string(column: c, row: r)
                    return (cell as? NSAttributedString)?.string ?? cell?.description ?? ""
                }
            }
        }
    } else {
        if responds(attachment, "title"), let title = att.title(), !title.isEmpty { info["title"] = title }
        var url = responds(attachment, "urlString") ? att.urlString() : nil
        if url?.isEmpty ?? true, responds(attachment, "URL") { url = att.url()?.absoluteString }
        if let url, !url.isEmpty { info["url"] = url }
    }
    return info
}

/// Character formatting in a range, as spans of identical formatting.
private func formatSpans(_ text: NSAttributedString, _ range: NSRange) -> [[String: Any]] {
    var out: [[String: Any]] = []
    text.enumerateAttributes(in: range) { attrs, r, _ in
        if attrs[Key.attachment] != nil { return }
        var f: [String: Any] = [:]
        let hints = (attrs[Key.hints] as? Int) ?? 0
        if hints & 1 != 0 { f["bold"] = true }
        if hints & 2 != 0 { f["italic"] = true }
        if (attrs[Key.underline] as? Int ?? 0) != 0 { f["underline"] = true }
        if (attrs[Key.strike] as? Int ?? 0) != 0 { f["strike"] = true }
        if let e = attrs[Key.emphasis] as? Int, e != 0 { f["highlight"] = Highlight.name(e) }
        if let link = attrs[Key.link] { f["link"] = (link as AnyObject).description ?? "" }
        if f.isEmpty { return }
        f["text"] = (text.string as NSString).substring(with: r)
        out.append(f)
    }
    return out
}

func paragraphsJSON(_ text: NSAttributedString) -> [[String: Any]] {
    let ns = text.string as NSString
    return paragraphRanges(text).enumerated().map { i, p in
        var shown = ""
        var attachments: [[String: Any]] = []
        text.enumerateAttribute(Key.attachment, in: p.range) { value, r, _ in
            if let value {
                let info = attachmentInfo(value as AnyObject)
                attachments.append(info)
                shown += info["text"] as? String ?? "[\(info["type"]!)]"
            } else {
                shown += ns.substring(with: r)
            }
        }
        let style = styleAt(text, p.range)
        var para: [String: Any] = ["index": i, "text": shown, "style": Style.name(style?.style() ?? Style.body)]
        if let uuid = style?.uuid() { para["paragraph_id"] = uuid.uuidString }
        if let indent = style?.indent(), indent != 0 { para["indent"] = indent }
        if quoteLevel(style) != 0 { para["quote"] = quoteLevel(style) }
        if let todoObject = style?.todo() {
            let todo = view(todoObject, as: ICTTTodo.self)
            para["todo"] = ["uuid": todo.uuid()?.uuidString ?? "", "done": todo.done()]
        }
        if !attachments.isEmpty { para["attachments"] = attachments }
        let spans = formatSpans(text, p.range)
        if !spans.isEmpty { para["formats"] = spans }
        return para
    }
}

/// noteSummary plus paragraphs.
func noteJSON(_ note: AnyObject) -> [String: Any] {
    var d = noteSummary(note)
    d["paragraphs"] = paragraphsJSON(bodyText(note))
    return d
}

/// The paragraph at --index, or the one whose text equals `text`; callers pass one
/// of them. Fails with paragraph_not_found, ambiguous_paragraph (listing the
/// indexes) or bad_index.
func findParagraph(_ paragraphs: [[String: Any]], text: String?, index: Int?) -> Int {
    if let index {
        if index >= paragraphs.count { fail("bad_index", "Paragraph index out of range.") }
        return index
    }
    let text = text!
    let hits = paragraphs.filter { $0["text"] as? String == text }.map { $0["index"] as! Int }
    if hits.isEmpty { fail("paragraph_not_found", "No paragraph with text \"\(text)\".") }
    if hits.count > 1 {
        fail("ambiguous_paragraph", "\(hits.count) paragraphs read \"\(text)\"; pass --index (one of \(hits.map(String.init).joined(separator: ", "))).")
    }
    return hits[0]
}

// MARK: - Editing primitives, for use inside Store.commit

/// An ICTTTodo with a new identity.
func newTodo(done: Bool) -> AnyObject {
    view(NotesShared.make("ICTTTodo"), as: ICTTTodo.self).todo(done: done)
}

/// A paragraph style with a new identity (UUID).
func newStyle(_ style: Int, indent: Int = 0, quote: Int = 0, done: Bool = false) -> AnyObject {
    let object = NotesShared.make("ICTTMutableParagraphStyle")
    let s = view(object, as: ICTTParagraphStyle.self)
    s.setStyle(style)
    s.setUUID(UUID())
    if indent != 0 { s.setIndent(indent) }
    if quote != 0, responds(object, "setBlockQuoteLevel:") { s.setBlockQuoteLevel(quote) }
    s.setTodo(style == Style.checklist ? newTodo(done: done) : nil)
    return object
}

/// One paragraph: `content` styled with `style`, plus its newline.
func paragraph(_ content: NSAttributedString, style: AnyObject, newline: Bool) -> NSAttributedString {
    let line = NSMutableAttributedString(attributedString: content)
    if newline { line.append(NSAttributedString(string: "\n")) }
    line.addAttribute(Key.style, value: style, range: NSRange(location: 0, length: line.length))
    return line
}

/// Inserts whole paragraphs (each ending in "\n" except possibly the last)
/// after paragraph `afterIndex`, or at the end of the note when it is -1.
func insertParagraphs(_ note: AnyObject, after afterIndex: Int, _ content: NSAttributedString) {
    let text = bodyText(note)
    let ns = text.string as NSString
    var at = text.length
    if afterIndex >= 0 { at = NSMaxRange(paragraphRanges(text)[afterIndex].enclosing) }
    let insertion = NSMutableAttributedString()
    let previousEndsLine = at == 0 || ns.substring(with: NSRange(location: at - 1, length: 1)) == "\n"
    if !previousEndsLine {
        let previous = text.attribute(Key.style, at: at - 1, effectiveRange: nil)
        insertion.append(NSAttributedString(string: "\n", attributes: previous.map { [Key.style: $0] } ?? [:]))
    }
    let body = NSMutableAttributedString(attributedString: content)
    // Text follows the insertion point: the inserted block must end with a newline.
    if at < text.length, !body.string.hasSuffix("\n"), body.length > 0 {
        let last = body.attribute(Key.style, at: body.length - 1, effectiveRange: nil)
        body.append(NSAttributedString(string: "\n", attributes: last.map { [Key.style: $0] } ?? [:]))
    }
    insertion.append(body)
    mergeable(note).insert(insertion, at: at)
}

/// Replaces the paragraph style on every run of `range`, keeping other attributes.
func setParagraphStyle(_ note: AnyObject, _ text: NSAttributedString, _ range: NSRange, _ style: AnyObject) {
    text.enumerateAttributes(in: range) { attrs, r, _ in
        var updated = attrs
        updated[Key.style] = style
        mergeable(note).setAttributes(updated, range: r)
    }
}
