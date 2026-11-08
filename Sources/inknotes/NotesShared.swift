// Notes' private NotesShared framework, as typed Swift.
//
// The framework ships no headers, so each method inknotes uses is declared here
// as an @objc protocol requirement with its exact selector, and objects are
// viewed through these protocols with `view(_:as:)`. The compiler then emits
// correctly typed message sends. Class methods are declared on "...Class"
// protocols and called on the class object.
//
// Selectors were found on macOS 27.2 (26B5112a). Callers check optional
// methods with `responds(_:_:)` and fail with `unsupported_macos` when one
// is missing.

import CoreData
import Foundation

enum NotesShared {
    static let frameworkPath = "/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared"
    static let uiFrameworkPath = "/System/Library/PrivateFrameworks/NotesUI.framework/NotesUI"

    /// Loads NotesShared; returns the loader's error, or nil.
    static func load() -> String? {
        dlopen(frameworkPath, RTLD_NOW) == nil ? String(cString: dlerror()) : nil
    }

    /// The class object `name`, viewed through its class-method protocol.
    static func classObject<T>(_ name: String, as type: T.Type) -> T {
        guard let cls = NSClassFromString(name) else { fail("unsupported_macos", "Class \(name) is missing on this macOS.") }
        return unsafeBitCast(cls as AnyObject, to: type)
    }

    /// A new instance of `name` from plain alloc/init.
    static func make(_ name: String) -> NSObject {
        guard let cls = NSClassFromString(name) as? NSObject.Type else { fail("unsupported_macos", "Class \(name) is missing on this macOS.") }
        return cls.init()
    }
}

/// Views an Objective-C object through one of the protocols below.
func view<T>(_ object: AnyObject, as type: T.Type) -> T { unsafeBitCast(object, to: type) }

/// Whether an object, or a class object for class methods, implements `selector`.
func responds(_ object: AnyObject, _ selector: String) -> Bool {
    let sel = NSSelectorFromString(selector)
    if let cls = object as? AnyClass { return class_getClassMethod(cls, sel) != nil }
    return (object as? NSObject)?.responds(to: sel) ?? false
}

/// Key-value access on Core Data objects (title, folder, account, ...).
func kv(_ object: AnyObject?, _ key: String) -> Any? { (object as? NSObject)?.value(forKey: key) }
func kvPath(_ object: AnyObject?, _ path: String) -> Any? { (object as? NSObject)?.value(forKeyPath: path) }

/// The objects of an NSArray, NSSet or NSOrderedSet.
func objects(_ collection: Any?) -> [AnyObject] {
    switch collection {
    case let a as NSArray: return a.map { $0 as AnyObject }
    case let s as NSOrderedSet: return s.array.map { $0 as AnyObject }
    case let s as NSSet: return s.allObjects.map { $0 as AnyObject }
    default: return []
    }
}

// MARK: - Store

@objc protocol ICNoteContextClass {
    @objc(useContainerNamed:) func useContainer(named name: String)
    @objc(startSharedContextWithOptions:) func startSharedContext(options: Int)
    @objc(sharedContext) func sharedContext() -> AnyObject?
}

@objc protocol ICNoteContext {
    @objc(managedObjectContext) func managedObjectContext() -> NSManagedObjectContext?
    @objc(save) func saveContext()
    @objc(crossProcessChangeCoordinator) func crossProcessChangeCoordinator() -> AnyObject?
}

@objc protocol ICCrossProcessChangeCoordinator {
    @objc(postEditorExtensionDidSaveNotification) func postEditorExtensionDidSaveNotification()
}

@objc protocol ICAccountClass {
    @objc(allActiveAccountsInContext:) func allActiveAccounts(in context: NSManagedObjectContext) -> NSArray?
    @objc(localAccountInContext:) func localAccount(in context: NSManagedObjectContext) -> AnyObject?
    @objc(newLocalAccountInContext:) func newLocalAccount(in context: NSManagedObjectContext) -> AnyObject?
}

@objc protocol ICAccount {
    @objc(visibleFolders) func visibleFolders() -> AnyObject?
}

@objc protocol ICFolderClass {
    @objc(folderWithIdentifier:context:) func folder(identifier: String, context: NSManagedObjectContext) -> AnyObject?
    @objc(newFolderInParentFolder:) func newFolder(inParent parent: AnyObject) -> AnyObject?
    @objc(newFolderInAccount:) func newFolder(inAccount account: AnyObject) -> AnyObject?
}

@objc protocol ICFolder {
    @objc(isTrashFolder) func isTrashFolder() -> Bool
    @objc(visibleNotesCount) func visibleNotesCount() -> Int
    @objc(setTitle:) func setTitle(_ title: String)
    @objc(updateChangeCountWithReason:) func updateChangeCount(reason: String)
}

@objc protocol ICNoteClass {
    @objc(noteWithIdentifier:context:) func note(identifier: String, context: NSManagedObjectContext) -> AnyObject?
    @objc(predicateForVisibleNotesInContext:) func predicateForVisibleNotes(in context: NSManagedObjectContext) -> NSPredicate
    @objc(notesMatchingPredicate:context:) func notes(matching predicate: NSPredicate, context: NSManagedObjectContext) -> NSArray?
    @objc(newEmptyNoteInFolder:) func newEmptyNote(in folder: AnyObject) -> AnyObject?
}

@objc protocol ICNote {
    @objc(isPinned) func isPinned() -> Bool
    @objc(setIsPinned:) func setIsPinned(_ pinned: Bool)
    @objc(isPasswordProtected) func isPasswordProtected() -> Bool
    @objc(mergeableString) func mergeableString() -> AnyObject?
    // Plain-text representation; faster than loading the full NSAttributedString.
    // Available on 27.2; check with responds() before calling.
    @objc(noteAsPlainText) func noteAsPlainText() -> String?
    @objc(noteAsPlainTextWithoutTitle) func noteAsPlainTextWithoutTitle() -> String?
    @objc(beginEditing) func beginEditing()
    @objc(endEditing) func endEditing()
    @objc(didChangeNoteText) func didChangeNoteText()
    @objc(saveNoteData) func saveNoteData()
    @discardableResult @objc(regenerateTitle:snippet:) func regenerateTitle(_ title: Bool, snippet: Bool) -> Bool
    @objc(updateChangeCountWithReason:) func updateChangeCount(reason: String)
    @objc(addTableAttachmentWithText:) func addTableAttachment(text: NSAttributedString) -> AnyObject?
    @objc(addAttachmentWithFileURL:) func addAttachment(fileURL: URL) -> AnyObject?
    @objc(addAttachmentWithUTI:withURL:) func addAttachment(uti: String, url: URL) -> AnyObject?
}

// MARK: - Text

@objc protocol ICTTMergeableString {
    @objc(attributedString) func attributedString() -> NSAttributedString
    @objc(insertAttributedString:atIndex:) func insert(_ string: NSAttributedString, at index: Int)
    @objc(setAttributes:range:) func setAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange)
}

@objc protocol ICTTParagraphStyle {
    @objc(style) func style() -> Int
    @objc(uuid) func uuid() -> UUID?
    @objc(indent) func indent() -> Int
    @objc(todo) func todo() -> AnyObject?
    @objc(setStyle:) func setStyle(_ style: Int)
    @objc(setUuid:) func setUUID(_ uuid: UUID)
    @objc(setIndent:) func setIndent(_ indent: Int)
    @objc(setTodo:) func setTodo(_ todo: AnyObject?)
    // Present on macOS 27.2; check with responds() first.
    @objc(blockQuoteLevel) func blockQuoteLevel() -> Int
    @objc(setBlockQuoteLevel:) func setBlockQuoteLevel(_ level: Int)
}

@objc protocol ICTTTodo {
    @objc(uuid) func uuid() -> UUID?
    @objc(done) func done() -> Bool
    /// A copy with the same identity and a new done state.
    @objc(todoWithDone:) func todo(done: Bool) -> AnyObject
}

// MARK: - Attachments

@objc protocol ICTTAttachment {
    @objc(attachmentUTI) func attachmentUTI() -> String?
    @objc(attachmentIdentifier) func attachmentIdentifier() -> String?
    @objc(setAttachmentUTI:) func setAttachmentUTI(_ uti: String)
    @objc(setAttachmentIdentifier:) func setAttachmentIdentifier(_ identifier: String)
    @objc(inlineAttachmentInContext:) func inlineAttachment(in context: NSManagedObjectContext) -> AnyObject?
    @objc(attachmentInContext:) func attachment(in context: NSManagedObjectContext) -> AnyObject?
}

@objc protocol ICAttachment {
    @objc(tableModel) func tableModel() -> AnyObject?
    @objc(title) func title() -> String?
    @objc(urlString) func urlString() -> String?
    @objc(URL) func url() -> URL?
}

@objc protocol ICAttachmentTableModel {
    @objc(table) func table() -> AnyObject?
}

@objc protocol ICTable {
    @objc(rowCount) func rowCount() -> Int
    @objc(columnCount) func columnCount() -> Int
    @objc(stringForColumnIndex:rowIndex:) func string(column: Int, row: Int) -> AnyObject?
}

@objc protocol ICInlineAttachmentClass {
    @objc(newHashtagAttachmentWithIdentifier:hashtagText:creatingHashtagIfNecessary:note:parentAttachment:)
    func newHashtagAttachment(identifier: String, hashtagText: String, creatingHashtagIfNecessary: Bool, note: AnyObject, parentAttachment: AnyObject?) -> AnyObject?
    @objc(newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:)
    func newLinkAttachment(identifier: String, toNote: AnyObject, fromNote: AnyObject, parentAttachment: AnyObject?) -> AnyObject?
    @objc(newParagraphLinkAttachmentWithIdentifier:toNote:paragraphName:paragraphID:fromNote:parentAttachment:)
    func newParagraphLinkAttachment(identifier: String, toNote: AnyObject, paragraphName: String?, paragraphID: UUID, fromNote: AnyObject, parentAttachment: AnyObject?) -> AnyObject?
    @objc(newDividerLineAttachmentWithIdentifier:note:parentAttachment:)
    func newDividerLineAttachment(identifier: String, note: AnyObject, parentAttachment: AnyObject?) -> AnyObject?
}

