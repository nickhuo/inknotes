// Snapshots of a note's text, saved before every applied edit so any edit can be undone.
//
// Each snapshot is the note's attributed text, archived with NSKeyedArchiver. Paragraph
// styles archive as they are, so a restore brings back paragraph and to-do identities;
// attachment characters are stored as {id, uti} and point at the same Notes objects
// again on restore. Only the newest `keep` snapshots of a note are kept.

import Foundation

enum History {
    static let keep = 5

    struct Snapshot {
        let id: String
        let reason: String
        let created: Date
        let text: NSAttributedString
    }

    /// INKNOTES_HISTORY_DIR, else $XDG_STATE_HOME/inknotes/history, else ~/.local/state/inknotes/history.
    static var root: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["INKNOTES_HISTORY_DIR"], !dir.isEmpty { return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath) }
        let state = env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.local/state"
        return URL(fileURLWithPath: state).appendingPathComponent("inknotes/history")
    }

    private static func directory(_ note: AnyObject) -> URL {
        root.appendingPathComponent(kv(note, "identifier") as! String)
    }

    /// Snapshot ids are UTC timestamps, so name order is time order.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return f
    }()

    /// The note's snapshot files, oldest first.
    static func files(_ note: AnyObject) -> [URL] {
        let dir = directory(note)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "snapshot" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch { fail("history_failed", "Cannot list \(dir.path): \(error.localizedDescription)") }
    }

    /// Saves the note's current text, then deletes all but the newest `keep` snapshots. Returns the snapshot id.
    static func save(_ note: AnyObject, reason: String) -> String {
        let text = NSMutableAttributedString(attributedString: bodyText(note))
        text.enumerateAttribute(Key.attachment, in: NSRange(location: 0, length: text.length)) { value, r, _ in
            guard let value else { return }
            let tt = view(value as AnyObject, as: ICTTAttachment.self)
            text.addAttribute(Key.attachment, value: ["id": tt.attachmentIdentifier() ?? "", "uti": tt.attachmentUTI() ?? ""] as NSDictionary, range: r)
        }
        let now = Date()
        let id = stamp.string(from: now)
        let dir = directory(note)
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: ["reason": reason, "created": now, "text": text] as NSDictionary,
                                                        requiringSecureCoding: false)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(id + ".snapshot"), options: .atomic)
            for old in files(note).dropLast(keep) { try FileManager.default.removeItem(at: old) }
        } catch { fail("history_failed", "Cannot save a snapshot in \(dir.path): \(error.localizedDescription)") }
        return id
    }

    static func load(_ file: URL) -> Snapshot {
        let record: NSDictionary
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: Data(contentsOf: file))
            unarchiver.requiresSecureCoding = false
            guard let decoded = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSDictionary else {
                fail("history_failed", "\(file.path) is not a snapshot.")
            }
            record = decoded
        } catch { fail("history_failed", "Cannot read \(file.path): \(error.localizedDescription)") }
        let text = NSMutableAttributedString(attributedString: record["text"] as! NSAttributedString)
        text.enumerateAttribute(Key.attachment, in: NSRange(location: 0, length: text.length)) { value, r, _ in
            guard let ref = value as? NSDictionary else { return }
            let char = objectChar(ref["id"] as! String, ref["uti"] as! String)
            text.addAttribute(Key.attachment, value: char.attribute(Key.attachment, at: 0, effectiveRange: nil)!, range: r)
        }
        return Snapshot(id: file.deletingPathExtension().lastPathComponent, reason: record["reason"] as! String,
                        created: record["created"] as! Date, text: text)
    }

    static func summary(_ snapshot: Snapshot) -> [String: Any] {
        ["id": snapshot.id, "reason": snapshot.reason, "created": ISO8601DateFormatter().string(from: snapshot.created),
         "title": snapshot.text.string.components(separatedBy: "\n").first ?? ""]
    }
}
