// Markdown in and out of notes.
//
// Import is two steps so writes can be dry runs: parseMarkdown turns text into
// blocks, planBlocks validates them (links resolve, files exist) without
// writing, and renderBlocks builds the note text, creating tags, links and
// attachments. The syntax is listed in README.md.
//
// Text is handled as NSString (UTF-16) throughout, matching Notes' own ranges.

import Foundation

struct Block {
    enum Kind: String { case para, table, file, url, drawing, divider }
    var kind: Kind
    var style = Style.body
    var indent = 0
    var quote = 0
    var done = false
    var text = ""
    /// Code-block lines: kept verbatim, no inline Markdown.
    var raw = false
    var rows: [[String]] = []
    var value = ""
}

// MARK: - Export

private func inlineMarkdown(_ text: NSAttributedString, _ range: NSRange) -> String {
    var out = ""
    let ns = text.string as NSString
    text.enumerateAttributes(in: range) { attrs, r, _ in
        if let attachment = attrs[Key.attachment] {
            let info = attachmentInfo(attachment as AnyObject)
            let type = info["type"] as? String ?? ""
            switch type {
            case "tag": out += info["text"] as? String ?? ""
            case "link": out += "[\(info["text"] as? String ?? "")](\(info["target"] as? String ?? ""))"
            case "url": out += "<\(info["url"] as? String ?? "")>"
            case "table":
                let rows = info["rows"] as? [[String]] ?? []
                for (k, row) in rows.enumerated() {
                    out += (k > 0 ? "\n" : "") + "| \(row.joined(separator: " | ")) |"
                    if k == 0 { out += "\n| \(Array(repeating: "---", count: rows[0].count).joined(separator: " | ")) |" }
                }
            default: out += "![\(info["title"] as? String ?? type)](attachment:\(info["id"] ?? ""))"
            }
            return
        }
        let s = ns.substring(with: r)
        if s.trimmingCharacters(in: .whitespaces).isEmpty { out += s; return }
        var open = "", close = ""
        func wrap(_ marker: String) { open += marker; close = marker + close }
        let hints = attrs[Key.hints] as? Int ?? 0
        if hints & 1 != 0 { wrap("**") }
        if hints & 2 != 0 { wrap("*") }
        if (attrs[Key.strike] as? Int ?? 0) != 0 { wrap("~~") }
        let emphasis = attrs[Key.emphasis] as? Int ?? 0
        if emphasis != 0 {
            open += emphasis == 1 ? "==" : "=={\(Highlight.name(emphasis))}"
            close = "==" + close
        }
        var body = open + s + close
        if let link = attrs[Key.link] { body = "[\(body)](\((link as AnyObject).description ?? ""))" }
        out += body
    }
    return out
}

func noteMarkdown(_ note: AnyObject) -> String {
    let text = bodyText(note)
    let ns = text.string as NSString
    var md = ""
    var inCode = false
    var numbered = 0
    for p in paragraphRanges(text) {
        let style = styleAt(text, p.range)
        let s = style?.style() ?? Style.body
        let indent = style?.indent() ?? 0
        if s == Style.monospaced && !inCode { md += "```\n"; inCode = true }
        if s != Style.monospaced && inCode { md += "```\n"; inCode = false }
        numbered = s == Style.numbered ? numbered + 1 : 0
        let line = s == Style.monospaced ? ns.substring(with: p.range) : inlineMarkdown(text, p.range)
        let pad = String(repeating: " ", count: indent * 2)
        let q = String(repeating: "> ", count: quoteLevel(style))
        switch s {
        case Style.title: md += "# \(line)\n"
        case Style.heading: md += "## \(line)\n"
        case Style.subheading: md += "### \(line)\n"
        case Style.bullet, Style.dash: md += "\(q)\(pad)- \(line)\n"
        case Style.numbered: md += "\(q)\(pad)\(numbered). \(line)\n"
        case Style.checklist:
            let done = style?.todo().map { view($0, as: ICTTTodo.self).done() } ?? false
            md += "\(q)\(pad)- [\(done ? "x" : " ")] \(line)\n"
        default: md += "\(q)\(line)\n"
        }
    }
    if inCode { md += "```\n" }
    return md
}

// MARK: - Import

private func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }

private func firstMatch(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
    re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
}

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

func parseMarkdown(_ markdown: String) -> [Block] {
    var blocks: [Block] = []
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    // Indent unit: the smallest leading indentation used by a list item.
    let listRe = regex("^( *)([-*+]|\\d+[.)]) ")
    var unit = 0
    for l in lines {
        let spaces = firstMatch(listRe, l)?.range(at: 1).length ?? 0
        if spaces > 0 && (unit == 0 || spaces < unit) { unit = spaces }
    }
    if unit == 0 { unit = 2 }
    let separatorRe = regex("^\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)*\\|?$")
    let imageRe = regex("^!\\[[^\\]]*\\]\\(([^)]+)\\)$")
    let urlRe = regex("^<?(https?://[^\\s>]+)>?$")
    let numberedRe = regex("^\\d+[.)] ")
    var inCode = false, lastBlank = false
    var i = 0
    while i < lines.count {
        defer { i += 1 }
        let raw = lines[i].replacingOccurrences(of: "\t", with: "    ")
        var t = trimmed(raw)
        if t.hasPrefix("```") { inCode.toggle(); continue }
        if inCode { blocks.append(Block(kind: .para, style: Style.monospaced, text: raw, raw: true)); continue }
        if t.isEmpty {
            if !lastBlank && !blocks.isEmpty { blocks.append(Block(kind: .para, text: "")) }
            lastBlank = true
            continue
        }
        lastBlank = false
        if t.hasPrefix("|") {
            var rows: [[String]] = []
            while i < lines.count && trimmed(lines[i]).hasPrefix("|") {
                var row = trimmed(lines[i])
                i += 1
                if firstMatch(separatorRe, row) != nil { continue }
                if row.hasPrefix("|") { row.removeFirst() }
                if row.hasSuffix("|") { row.removeLast() }
                rows.append(row.components(separatedBy: "|").map(trimmed))
            }
            i -= 1
            blocks.append(Block(kind: .table, rows: rows))
            continue
        }
        if t == "---" || t == "***" { blocks.append(Block(kind: .divider)); continue }
        if let m = firstMatch(imageRe, t) {
            let src = (t as NSString).substring(with: m.range(at: 1))
            blocks.append(Block(kind: (src as NSString).pathExtension.lowercased() == "svg" ? .drawing : .file, value: src))
            continue
        }
        if let m = firstMatch(urlRe, t) { blocks.append(Block(kind: .url, value: (t as NSString).substring(with: m.range(at: 1)))); continue }

        var quote = 0
        while t.hasPrefix(">") { quote += 1; t = trimmed(String(t.dropFirst())) }
        let lead = (raw as NSString).rangeOfCharacter(from: CharacterSet.whitespaces.inverted).location
        var indent = (lead == NSNotFound ? 0 : lead) / unit
        var style = Style.body
        var done = false
        let nt = t as NSString
        var text = t
        if t.hasPrefix("# ") { style = Style.title; text = nt.substring(from: 2) }
        else if t.hasPrefix("## ") { style = Style.heading; text = nt.substring(from: 3) }
        else if t.hasPrefix("### ") || t.hasPrefix("#### ") { style = Style.subheading; text = nt.substring(from: nt.range(of: " ").location + 1) }
        else if ["- [ ] ", "* [ ] ", "- [x] ", "- [X] ", "* [x] "].contains(where: t.hasPrefix) {
            style = Style.checklist; done = nt.character(at: 3) != 0x20; text = nt.substring(from: 6)
        }
        else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { style = Style.bullet; text = nt.substring(from: 2) }
        else if let n = firstMatch(numberedRe, t) { style = Style.numbered; text = nt.substring(from: n.range.length) }
        if style < Style.bullet { indent = 0 }
        blocks.append(Block(kind: .para, style: style, indent: indent, quote: quote, done: done, text: text))
    }
    while let last = blocks.last, last.kind == .para, last.text.isEmpty { blocks.removeLast() }
    return blocks
}

/// Inline Markdown: **bold**, *italic*, ~~strike~~, ==highlight== (=={pink}…== for another
/// color), [text](url), [[Note title]] / [[Note title#Paragraph]] note links, applenotes: links,
/// and #tags. With `note` nil, links and tags are only validated (against `account`, when
/// given) and collected in `refs`.
func parseInline(_ s: String, note: AnyObject?, account: AnyObject?, refs: inout [[String: Any]]) -> NSAttributedString {
    let bold = NSAttributedString.Key("b"), italic = NSAttributedString.Key("i")  // merged into TTHints at the end
    let out = NSMutableAttributedString()
    var current: [NSAttributedString.Key: Any] = [:]
    let tagChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-/")
    let ns = s as NSString
    let n = ns.length
    var i = 0
    let buffer = NSMutableString()

    func isMember(_ set: CharacterSet, _ c: unichar) -> Bool { Unicode.Scalar(c).map(set.contains) ?? false }
    func append(_ c: unichar) { var c = c; CFStringAppendCharacters(buffer as CFMutableString, &c, 1) }
    func flush() {
        if buffer.length > 0 { out.append(NSAttributedString(string: buffer as String, attributes: current)); buffer.setString("") }
    }
    func closes(_ mark: String, from: Int) -> Bool { ns.range(of: mark, range: NSRange(location: from, length: n - from)).location != NSNotFound }
    func toggle(_ key: NSAttributedString.Key, _ value: Any) {
        flush()
        if current[key] != nil { current[key] = nil } else { current[key] = value }
    }

    while i < n {
        let c = ns.character(at: i)
        let rest = ns.substring(from: i)
        if c == 0x5C, i + 1 < n { append(ns.character(at: i + 1)); i += 2; continue }  // \x
        if rest.hasPrefix("[[") {
            let end = ns.range(of: "]]", range: NSRange(location: i + 2, length: n - i - 2))
            if end.location != NSNotFound {
                let inner = ns.substring(with: NSRange(location: i + 2, length: end.location - i - 2))
                let parts = inner.components(separatedBy: "#")
                refs.append(["link": parts[0], "paragraph": parts.count > 1 ? parts[1] : NSNull()])
                flush()
                if let note, let account {
                    let target = Store.note(titled: parts[0], in: account)
                    var paragraphID: UUID?
                    var paragraphName: String?
                    if parts.count > 1 {
                        let paragraphs = paragraphsJSON(bodyText(target))
                        let p = paragraphs[findParagraph(paragraphs, text: parts[1], index: nil)]
                        paragraphID = UUID(uuidString: p["paragraph_id"] as? String ?? "")
                        paragraphName = p["text"] as? String
                    }
                    out.append(makeNoteLink(note, target, paragraphID: paragraphID, paragraphName: paragraphName))
                } else if let account {
                    _ = Store.note(titled: parts[0], in: account)
                }
                i = end.location + 2
                continue
            }
        }
        if c == 0x5B {  // [text](href)
            let close = ns.range(of: "](", range: NSRange(location: i, length: n - i))
            let paren = close.location != NSNotFound ? ns.range(of: ")", range: NSRange(location: close.location, length: n - close.location)) : close
            if close.location != NSNotFound && paren.location != NSNotFound {
                let label = ns.substring(with: NSRange(location: i + 1, length: close.location - i - 1))
                let href = ns.substring(with: NSRange(location: close.location + 2, length: paren.location - close.location - 2))
                flush()
                if href.hasPrefix("applenotes:") {
                    // applenotes:note/<id> or applenotes://showNote?identifier=<id>&paragraphID=<uuid>
                    let items = URLComponents(string: href)?.queryItems ?? []
                    var noteID = items.first { $0.name == "identifier" }?.value
                    let paragraphID = items.first { $0.name == "paragraphID" }?.value
                    if noteID == nil { noteID = href.components(separatedBy: "note/").last?.components(separatedBy: "?").first }
                    refs.append(["link": noteID ?? href, "paragraph": paragraphID ?? NSNull()])
                    if let note {
                        let target = Store.note(noteID ?? "")
                        let name = paragraphID.flatMap { pid in
                            paragraphsJSON(bodyText(target)).last { $0["paragraph_id"] as? String == pid.uppercased() }?["text"] as? String
                        }
                        out.append(makeNoteLink(note, target, paragraphID: paragraphID.flatMap(UUID.init(uuidString:)), paragraphName: name))
                    } else if account != nil {
                        _ = Store.note(noteID ?? "")
                    }
                } else {
                    var attrs = current
                    if let url = URL(string: href) { attrs[Key.link] = url }
                    out.append(NSAttributedString(string: label, attributes: attrs))
                }
                i = paren.location + 1
                continue
            }
        }
        if rest.hasPrefix("**") && (current[bold] != nil || closes("**", from: i + 2)) { toggle(bold, true); i += 2; continue }
        if rest.hasPrefix("~~") && (current[Key.strike] != nil || closes("~~", from: i + 2)) { toggle(Key.strike, 1); i += 2; continue }
        if rest.hasPrefix("==") && (current[Key.emphasis] != nil || closes("==", from: i + 2)) {
            var color = 1, skip = 2
            if current[Key.emphasis] == nil && rest.hasPrefix("=={") {
                let brace = (rest as NSString).range(of: "}")
                let v = brace.location != NSNotFound ? Highlight.value((rest as NSString).substring(with: NSRange(location: 3, length: brace.location - 3))) : -1
                if v > 0 { color = v; skip = brace.location + 1 }
            }
            toggle(Key.emphasis, color)
            i += skip
            continue
        }
        if (c == 0x2A || c == 0x5F) && (current[italic] != nil || (i + 1 < n && !isMember(.whitespaces, ns.character(at: i + 1)) &&
                                                                  closes(String(utf16CodeUnits: [c], count: 1), from: i + 1) &&
                                                                  (c == 0x2A || i == 0 || !isMember(.alphanumerics, ns.character(at: i - 1))))) {
            toggle(italic, true); i += 1; continue
        }
        if c == 0x23 && (i == 0 || isMember(.whitespaces, ns.character(at: i - 1))) && i + 1 < n && isMember(tagChars, ns.character(at: i + 1)) {
            var j = i + 1
            while j < n && isMember(tagChars, ns.character(at: j)) { j += 1 }
            let tag = ns.substring(with: NSRange(location: i + 1, length: j - i - 1))
            refs.append(["tag": tag])
            flush()
            out.append(note.map { makeTag($0, tag) } ?? NSAttributedString(string: "#" + tag))
            i = j
            continue
        }
        append(c)
        i += 1
    }
    flush()
    // Bold and italic are one attribute in Notes: a bit mask of font traits.
    out.enumerateAttributes(in: NSRange(location: 0, length: out.length)) { attrs, r, _ in
        let hints = (attrs[bold] != nil ? 1 : 0) | (attrs[italic] != nil ? 2 : 0)
        out.removeAttribute(bold, range: r)
        out.removeAttribute(italic, range: r)
        if hints != 0 { out.addAttribute(Key.hints, value: hints, range: r) }
    }
    return out
}

/// Validates blocks and resolves links without writing; returns a summary.
func planBlocks(_ blocks: [Block], account: AnyObject) -> [[String: Any]] {
    blocks.map { b in
        var p: [String: Any] = ["kind": b.kind.rawValue]
        switch b.kind {
        case .para:
            var refs: [[String: Any]] = []
            let text = b.raw ? NSAttributedString(string: b.text) : parseInline(b.text, note: nil, account: account, refs: &refs)
            p["style"] = Style.name(b.style)
            p["text"] = text.string
            if b.style == Style.checklist { p["done"] = b.done }
            if b.indent != 0 { p["indent"] = b.indent }
            if b.quote != 0 { p["quote"] = b.quote }
            if !refs.isEmpty { p["refs"] = refs }
        case .table:
            p["rows"] = b.rows
        case .file, .url, .drawing:
            p["value"] = b.value
            if b.kind != .url && !FileManager.default.isReadableFile(atPath: resolvePath(b.value)) { fail("file_not_found", "Cannot read \(b.value).") }
        case .divider:
            break
        }
        return p
    }
}

/// Builds the text for `blocks`, creating tags, links and attachments in `note`.
func renderBlocks(_ blocks: [Block], note: AnyObject, account: AnyObject) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for (k, b) in blocks.enumerated() {
        let content: NSAttributedString
        let style: AnyObject
        if b.kind == .para {
            var refs: [[String: Any]] = []
            content = b.raw ? NSAttributedString(string: b.text) : parseInline(b.text, note: note, account: account, refs: &refs)
            style = newStyle(b.style, indent: b.indent, quote: b.quote, done: b.done)
        } else {
            style = newStyle(Style.body)
            switch b.kind {
            case .table: content = makeTable(note, b.rows)
            case .file: content = makeFile(note, b.value)
            case .url: content = makeURLCard(note, b.value)
            case .drawing: content = makeDrawing(note, svg: b.value)
            default: content = makeDivider(note)
            }
        }
        out.append(paragraph(content, style: style, newline: k + 1 < blocks.count))
    }
    return out
}

/// Reads a file, or stdin for "-"; relative paths in it then resolve against the file's folder.
func readInput(_ source: String?) -> String? {
    guard let source else { return nil }
    let data: Data?
    if source == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        data = FileManager.default.contents(atPath: (source as NSString).expandingTildeInPath)
        var dir = (((source as NSString).expandingTildeInPath as NSString).standardizingPath as NSString).deletingLastPathComponent
        if !(dir as NSString).isAbsolutePath { dir = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(dir) }
        if data != nil { setRelativePathBase(dir) }
    }
    guard let data else { fail("file_not_found", "Cannot read \(source).") }
    return String(data: data, encoding: .utf8) ?? ""
}
