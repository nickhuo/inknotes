// The Notes store, reached through Notes' private NotesShared framework.
//
// This is the seam to Notes. It has two adapters, chosen by the environment:
// the user's store, or (NNOTE_CONTAINER=<name>) a separate store at
// …/group.com.apple.notes/Containers/<name>/NoteStore.sqlite, which Notes'
// own UI tests use and the e2e tests use. A fresh container gets an
// On My Mac account when first opened for writing.
//
// Everything here runs inside Store.moc.performAndWait, after Store.open.
// Failures exit through fail() with a JSON error.

import CoreData
import Foundation

enum Store {
    /// -[ICNoteContext initWithOptions:]: 0x40 opens every store read-only.
    private static let readOnlyOption = 0x40
    private static var context: ICNoteContext!
    /// The store's managed object context. Valid after open.
    static private(set) var moc: NSManagedObjectContext!

    /// Opens the store. Read-only opens every persistent store with Notes'
    /// read-only option and fails if any store is writable anyway.
    static func open(writable: Bool) {
        if let error = NotesShared.load() { fail("framework_unavailable", error) }
        let contextClass: AnyObject = NSClassFromString("ICNoteContext") as AnyObject? ?? { fail("unsupported_macos", "ICNoteContext is missing.") }()
        for sel in ["startSharedContextWithOptions:", "sharedContext"] where !responds(contextClass, sel) {
            fail("unsupported_macos", "ICNoteContext lacks \(sel)")
        }
        let contexts = view(contextClass, as: ICNoteContextClass.self)
        let container = ProcessInfo.processInfo.environment["NNOTE_CONTAINER"] ?? ""
        if !container.isEmpty { contexts.useContainer(named: container) }
        contexts.startSharedContext(options: writable ? 0 : readOnlyOption)
        guard let shared = contexts.sharedContext(), let moc = view(shared, as: ICNoteContext.self).managedObjectContext() else {
            fail("no_access", "Could not open the Notes database. Does this process have Full Disk Access?")
        }
        context = view(shared, as: ICNoteContext.self)
        self.moc = moc
        // A fresh container has no accounts; create its On My Mac account in that store.
        let accounts = NotesShared.classObject("ICAccount", as: ICAccountClass.self)
        if !container.isEmpty && writable && accounts.localAccount(in: moc) == nil {
            moc.performAndWait {
                if accounts.newLocalAccount(in: moc) == nil { fail("account_failed", "Could not create the test container's account.") }
                do { try moc.save() } catch { fail("save_failed", error.localizedDescription) }
            }
        }
        if !writable, moc.persistentStoreCoordinator?.persistentStores.contains(where: { !$0.isReadOnly }) ?? false {
            fail("store_not_read_only", "Refusing to read through a writable store.")
        }
    }

    static func fetch(_ entity: String, _ predicate: NSPredicate) -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = predicate
        do { return try moc.fetch(request) } catch { fail("fetch_failed", error.localizedDescription) }
    }

    // MARK: Lookups. Each fails with a not-found or ambiguity error instead of returning nil.

    static func allAccounts() -> [AnyObject] {
        objects(NotesShared.classObject("ICAccount", as: ICAccountClass.self).allActiveAccounts(in: moc))
    }

    static func account(named name: String) -> AnyObject {
        if let a = allAccounts().first(where: { (kv($0, "name") as? String)?.caseInsensitiveCompare(name) == .orderedSame }) { return a }
        fail("account_not_found", "No account named \"\(name)\".")
    }

    /// A folder by id, or by path ("Parent/Child") inside `accountName` (default On My Mac).
    static func folder(_ ref: String, account accountName: String?) -> AnyObject {
        if let byID = NotesShared.classObject("ICFolder", as: ICFolderClass.self).folder(identifier: ref, context: moc) { return byID }
        let acct = account(named: accountName ?? "On My Mac")
        let hits = visibleFolders(of: acct).filter { folderPath($0).caseInsensitiveCompare(ref) == .orderedSame }
        if hits.isEmpty { fail("folder_not_found", "No folder \"\(ref)\" in \(kv(acct, "name") ?? "").") }
        if hits.count > 1 { fail("ambiguous_folder", "Several folders are called \"\(ref)\"; pass its id.") }
        return hits[0]
    }

    /// A note by id (UUID), x-coredata:// URI, or primary key.
    static func note(_ ref: String) -> AnyObject {
        let uri: URL?
        if ref.hasPrefix("x-coredata://") {
            uri = URL(string: ref)
        } else if !ref.isEmpty, ref.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains) {
            let storeID = moc.persistentStoreCoordinator?.persistentStores.first?.metadata[NSStoreUUIDKey] ?? ""
            uri = URL(string: "x-coredata://\(storeID)/ICNote/p\(ref)")
        } else {
            if let note = NotesShared.classObject("ICNote", as: ICNoteClass.self).note(identifier: ref.uppercased(), context: moc) { return note }
            fail("note_not_found", "No note with id \(ref)")
        }
        guard let uri, let oid = moc.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: uri),
              let note = try? moc.existingObject(with: oid), let noteClass = NSClassFromString("ICNote"), note.isKind(of: noteClass) else {
            fail("note_not_found", "No note \(ref)")
        }
        return note
    }

    /// Notes that are not deleted and not in Recently Deleted.
    static func visibleNotes(_ extra: NSPredicate? = nil) -> [AnyObject] {
        let notes = NotesShared.classObject("ICNote", as: ICNoteClass.self)
        let visible = notes.predicateForVisibleNotes(in: moc)
        let predicate = extra.map { NSCompoundPredicate(andPredicateWithSubpredicates: [visible, $0]) } ?? visible
        return objects(notes.notes(matching: predicate, context: moc))
    }

    /// A note by exact, unique title in one account (for [[Title]] links in Markdown).
    static func note(titled title: String, in account: AnyObject) -> AnyObject {
        let hits = visibleNotes(NSPredicate(format: "title ==[c] %@ AND account == %@", title, account as! NSObject))
        if hits.isEmpty { fail("note_not_found", "No note titled \"\(title)\" in \(kv(account, "name") ?? "").") }
        if hits.count > 1 { fail("ambiguous_note", "\(hits.count) notes are titled \"\(title)\"; link by id instead.") }
        return hits[0]
    }

    static func visibleFolders(of account: AnyObject) -> [AnyObject] {
        objects(view(account, as: ICAccount.self).visibleFolders())
    }

    // MARK: Writes

    /// The account must be in NNOTE_WRITABLE_ACCOUNTS (default "On My Mac").
    static func guardAccount(_ account: AnyObject) {
        let configured = ProcessInfo.processInfo.environment["NNOTE_WRITABLE_ACCOUNTS"]
        let allowed = Set((configured ?? "On My Mac").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let name = kv(account, "name") as? String ?? ""
        if !allowed.contains(name.lowercased()) {
            fail("account_not_writable", "Account \"\(name)\" is not writable. Writable accounts: \(configured ?? "On My Mac") (set NNOTE_WRITABLE_ACCOUNTS).")
        }
    }

    /// The note's account must be writable; the note must not be deleted or locked.
    static func guardWritable(_ note: AnyObject) {
        guardAccount(kv(note, "account") as AnyObject)
        if (kv(note, "markedForDeletion") as? Bool ?? false) || isTrash(kv(note, "folder") as AnyObject?) {
            fail("note_deleted", "Note is deleted or in Recently Deleted.")
        }
        if responds(note, "isPasswordProtected") && view(note, as: ICNote.self).isPasswordProtected() {
            fail("note_locked", "Note is locked with a password.")
        }
    }

    static func requireSelectors(_ object: AnyObject, _ selectors: [String]) {
        for sel in selectors where !responds(object, sel) {
            fail("unsupported_macos", "\(type(of: object)) lacks \(sel)")
        }
    }

    /// Saves, then tells a running Notes.app that another process saved, the way
    /// Notes' editor extension does; otherwise it may overwrite the change with its open copy.
    static func saveAndNotify() {
        context.saveContext()
        if moc.hasChanges {
            do { try moc.save() } catch { fail("save_failed", error.localizedDescription) }
        }
        if let coordinator = context.crossProcessChangeCoordinator() {
            view(coordinator, as: ICCrossProcessChangeCoordinator.self).postEditorExtensionDidSaveNotification()
        }
    }

    /// Runs `edit` as one edit of `note` the way Notes does it, then saves.
    static func commit(_ note: AnyObject, reason: String, _ edit: (ICTTMergeableString) -> Void) {
        requireSelectors(note, ["beginEditing", "endEditing", "didChangeNoteText", "saveNoteData", "updateChangeCountWithReason:"])
        let n = view(note, as: ICNote.self)
        n.beginEditing()
        edit(mergeable(note))
        n.endEditing()
        n.didChangeNoteText()
        n.saveNoteData()
        if responds(note, "regenerateTitle:snippet:") { n.regenerateTitle(true, snippet: true) }
        (note as! NSObject).setValue(Date(), forKey: "modificationDate")
        n.updateChangeCount(reason: reason)
        saveAndNotify()
    }
}

// MARK: - Summaries

func folderPath(_ folder: AnyObject?) -> String {
    var parts: [String] = []
    var f = folder
    while let current = f {
        parts.insert(kv(current, "title") as? String ?? "", at: 0)
        f = kv(current, "parent") as AnyObject?
    }
    return parts.joined(separator: "/")
}

func isTrash(_ folder: AnyObject?) -> Bool {
    guard let folder, responds(folder, "isTrashFolder") else { return false }
    return view(folder, as: ICFolder.self).isTrashFolder()
}

func isPinned(_ note: AnyObject) -> Bool {
    responds(note, "isPinned") && view(note, as: ICNote.self).isPinned()
}

/// id, uri, title, account, folder, pinned, modified.
func noteSummary(_ note: AnyObject) -> [String: Any] {
    let folder = kv(note, "folder") as AnyObject?
    return [
        "id": kv(note, "identifier") ?? NSNull(),
        "uri": (note as! NSManagedObject).objectID.uriRepresentation().absoluteString,
        "title": kv(note, "title") ?? "",
        "account": kvPath(note, "account.name") ?? NSNull(),
        "folder": folder.map { folderPath($0) } ?? NSNull(),
        "pinned": isPinned(note),
        "modified": (kv(note, "modificationDate") as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
    ]
}
