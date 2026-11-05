import Foundation

/// Scan every selected note so skipped covers the whole selection and truncated
/// means an additional readable match exists, rather than just reaching the cap.
/// Keep body lookup injectable to test unreadable notes without opening Notes.
func searchResults<Note>(_ notes: [Note], query: String, limit: Int,
                         body: (Note) -> String?, summary: (Note) -> [String: Any]) -> [String: Any] {
    var results: [[String: Any]] = []
    var skipped = 0
    var truncated = false
    for note in notes {
        guard let text = body(note) else { skipped += 1; continue }
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
        if results.count >= limit { truncated = true; continue }
        var entry = summary(note)
        entry["snippet"] = searchSnippet(text, around: range)
        results.append(entry)
    }
    return ["notes": results, "count": results.count, "truncated": truncated, "skipped": skipped]
}

func searchSnippet(_ body: String, around range: Range<String.Index>) -> String {
    let pad = 80
    let lo = body.distance(from: body.startIndex, to: range.lowerBound)
    let hi = body.distance(from: body.startIndex, to: range.upperBound)
    let startOff = max(0, lo - pad)
    let endOff = min(body.count, hi + pad)
    let start = body.index(body.startIndex, offsetBy: startOff)
    let end = body.index(body.startIndex, offsetBy: endOff)
    var snippet = String(body[start..<end])
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")
    if startOff > 0 { snippet = "…" + snippet }
    if endOff < body.count { snippet += "…" }
    return snippet
}
