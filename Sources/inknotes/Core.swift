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

/// One registry for exit codes and recovery semantics. Retrying is never
/// automatic: even an operational write failure may have partially saved.
enum FailureKind {
    case input, actionRequired, operational

    static func classify(_ code: String) -> FailureKind {
        switch code {
        case "usage", "bad_index", "bad_style", "bad_highlight", "bad_url",
             "bad_text", "bad_tag", "bad_target", "bad_table",
             "bad_name", "bad_parent", "bad_folder", "file_not_found",
             "ambiguous_note", "ambiguous_folder", "ambiguous_paragraph":
            return .input
        case "no_access", "account_not_writable", "note_locked", "note_deleted",
             // Not found and conflict: the input was well formed, but the store disagrees.
             "note_not_found", "folder_not_found", "account_not_found",
             "paragraph_not_found", "text_not_found", "folder_exists", "not_a_todo":
            return .actionRequired
        default:
            return .operational
        }
    }

    var exitCode: Int32 { self == .input ? 2 : 1 }
    var status: String { self == .operational ? "error" : "action_required" }
}

/// Prints a single-line JSON error to stderr, with "error" first.
func fail(_ code: String, _ message: String) -> Never {
    let kind = FailureKind.classify(code)
    let data = try! JSONSerialization.data(withJSONObject: ["error": code, "message": message,
                                                           "status": kind.status, "retryable": false], options: [.sortedKeys])
    FileHandle.standardError.write(data + Data("\n".utf8))
    exit(kind.exitCode)
}
