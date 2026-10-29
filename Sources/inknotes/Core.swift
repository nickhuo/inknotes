// Shared by every module: the names Notes uses for text attributes and
// attachment types, style and highlight names, and JSON output.

import Foundation

/// Text attribute keys, as stored by Notes (found by surveying every note).
enum Key {
    static let style = NSAttributedString.Key("TTStyle")              // ICTTParagraphStyle
    static let attachment = NSAttributedString.Key("NSAttachment")    // ICTTAttachment
    static let link = NSAttributedString.Key("NSLink")                // URL
    static let hints = NSAttributedString.Key("TTHints")              // font traits: 1 bold, 2 italic
    static let underline = NSAttributedString.Key("TTUnderline")      // 1
    static let strike = NSAttributedString.Key("TTStrikethrough")     // 1
    static let emphasis = NSAttributedString.Key("TTEmphasis")        // highlight color, 1-5
}

enum UTI {
    static let hashtag = "com.apple.notes.inlinetextattachment.hashtag"
    static let link = "com.apple.notes.inlinetextattachment.link"
    static let inlinePrefix = "com.apple.notes.inlinetextattachment."
    static let table = "com.apple.notes.table"
    static let url = "public.url"
}

/// ICTTParagraphStyle.style values.
enum Style {
    static let title = 0, heading = 1, subheading = 2, body = 3, monospaced = 4
    static let bullet = 100, dash = 101, numbered = 102, checklist = 103

    static let names: [String: Int] = ["title": 0, "heading": 1, "subheading": 2, "body": 3, "monospaced": 4,
                                       "bullet": 100, "dash": 101, "numbered": 102, "checklist": 103]

    static func name(_ style: Int) -> String {
        names.first { $0.value == style }?.key ?? "style\(style)"
    }
}

/// TTEmphasis values, confirmed in Notes.app's highlight menu (macOS 27.2).
enum Highlight {
    static let names = ["purple", "pink", "orange", "mint", "blue"]

    /// The color name, or the number if unknown.
    static func name(_ value: Int) -> Any { (1...5).contains(value) ? names[value - 1] : value }

    /// "pink" or "2" -> 2; "none" or "0" -> 0; anything else -> -1.
    static func value(_ text: String) -> Int {
        let s = text.lowercased()
        if let i = names.firstIndex(of: s) { return i + 1 }
        if s == "none" { return 0 }
        if let n = Int(s), String(n) == s, (0...5).contains(n) { return n }
        return -1
    }
}

/// Prints `object` as JSON to stdout.
func emit(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

/// Prints {"error": code, "message": message} to stderr, on one line with
/// "error" first, and exits with status 1.
func fail(_ code: String, _ message: String) -> Never {
    let data = try! JSONSerialization.data(withJSONObject: ["error": code, "message": message], options: [.sortedKeys])
    FileHandle.standardError.write(data + Data("\n".utf8))
    exit(1)
}
