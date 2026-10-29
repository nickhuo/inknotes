// Native Notes objects. Each make function creates the object in `note` with
// Notes' own constructor and returns the one attachment character to insert
// into the text. Call them inside Store.commit; they fail with a JSON error
// (unsupported_macos, file_not_found, bad_url, bad_svg, ...).

import AppKit
import Foundation
import PencilKit

/// The attachment character (U+FFFC) for an attachment.
func objectChar(_ identifier: String, _ uti: String) -> NSAttributedString {
    let object = NotesShared.make("ICTTAttachment")
    let tt = view(object, as: ICTTAttachment.self)
    tt.setAttachmentIdentifier(identifier)
    tt.setAttachmentUTI(uti)
    return NSAttributedString(string: "\u{FFFC}", attributes: [Key.attachment: object])
}

func textHasAttachment(_ note: AnyObject, _ identifier: String) -> Bool {
    let text = bodyText(note)
    var found = false
    text.enumerateAttribute(Key.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
        if let value, view(value as AnyObject, as: ICTTAttachment.self).attachmentIdentifier() == identifier {
            found = true
            stop.pointee = true
        }
    }
    return found
}

// MARK: Relative paths in Markdown resolve against the Markdown file's folder.

private var relativePathBase: String?
func setRelativePathBase(_ dir: String) { relativePathBase = dir }

func resolvePath(_ path: String) -> String {
    let p = (path as NSString).expandingTildeInPath
    guard !(p as NSString).isAbsolutePath, let base = relativePathBase else { return p }
    return (base as NSString).appendingPathComponent(p)
}

// MARK: Objects

private func newID() -> String { UUID().uuidString }

private var inlineAttachments: ICInlineAttachmentClass {
    NotesShared.classObject("ICInlineAttachment", as: ICInlineAttachmentClass.self)
}

private func requireClassMethod(_ className: String, _ selector: String, _ message: String) {
    if let cls = NSClassFromString(className), responds(cls as AnyObject, selector) { return }
    fail("unsupported_macos", message)
}

func makeTag(_ note: AnyObject, _ tag: String) -> NSAttributedString {
    requireClassMethod("ICInlineAttachment", "newHashtagAttachmentWithIdentifier:hashtagText:creatingHashtagIfNecessary:note:parentAttachment:",
                       "Cannot create tags on this macOS.")
    let id = newID()
    if inlineAttachments.newHashtagAttachment(identifier: id, hashtagText: tag, creatingHashtagIfNecessary: true, note: note, parentAttachment: nil) == nil {
        fail("tag_failed", "Notes did not create the tag.")
    }
    return objectChar(id, UTI.hashtag)
}

/// A link to `target`, or to its paragraph `paragraphID` (shown as "Note → paragraph").
func makeNoteLink(_ note: AnyObject, _ target: AnyObject, paragraphID: UUID?, paragraphName: String?) -> NSAttributedString {
    let id = newID()
    let link: AnyObject?
    if let paragraphID {
        requireClassMethod("ICInlineAttachment", "newParagraphLinkAttachmentWithIdentifier:toNote:paragraphName:paragraphID:fromNote:parentAttachment:",
                           "Cannot create paragraph links on this macOS.")
        link = inlineAttachments.newParagraphLinkAttachment(identifier: id, toNote: target, paragraphName: paragraphName,
                                                            paragraphID: paragraphID, fromNote: note, parentAttachment: nil)
    } else {
        requireClassMethod("ICInlineAttachment", "newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:",
                           "Cannot create note links on this macOS.")
        link = inlineAttachments.newLinkAttachment(identifier: id, toNote: target, fromNote: note, parentAttachment: nil)
    }
    if link == nil { fail("link_failed", "Notes did not create the link.") }
    return objectChar(id, UTI.link)
}

func makeDivider(_ note: AnyObject) -> NSAttributedString {
    requireClassMethod("ICInlineAttachment", "newDividerLineAttachmentWithIdentifier:note:parentAttachment:",
                       "Cannot create divider lines on this macOS.")
    let id = newID()
    let divider = inlineAttachments.newDividerLineAttachment(identifier: id, note: note, parentAttachment: nil)
    return objectChar(id, kv(divider, "typeUTI") as? String ?? "com.apple.notes.inlinetextattachment.dividerline")
}

private func objectFor(_ attachment: AnyObject?, _ what: String) -> NSAttributedString {
    guard let attachment, let id = kv(attachment, "identifier") as? String else {
        fail("attachment_failed", "Notes did not create the \(what).")
    }
    return objectChar(id, kv(attachment, "typeUTI") as? String ?? "")
}

func makeTable(_ note: AnyObject, _ rows: [[String]]) -> NSAttributedString {
    Store.requireSelectors(note, ["addTableAttachmentWithText:"])
    // The table builder uses an NSMutableAttributedString category from NotesUI.
    dlopen(NotesShared.uiFrameworkPath, RTLD_NOW)
    if !NSMutableAttributedString.instancesRespond(to: NSSelectorFromString("ic_convertParagraphStyleToBodyInRange:")) {
        fail("unsupported_macos", "NotesUI's table helpers are unavailable on this macOS.")
    }
    let tsv = rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    return objectFor(view(note, as: ICNote.self).addTableAttachment(text: NSAttributedString(string: tsv)), "table")
}

func makeFile(_ note: AnyObject, _ path: String) -> NSAttributedString {
    let resolved = resolvePath(path)
    if !FileManager.default.isReadableFile(atPath: resolved) { fail("file_not_found", "Cannot read \(path).") }
    Store.requireSelectors(note, ["addAttachmentWithFileURL:"])
    return objectFor(view(note, as: ICNote.self).addAttachment(fileURL: URL(fileURLWithPath: resolved)), "attachment")
}

func makeURLCard(_ note: AnyObject, _ urlString: String) -> NSAttributedString {
    guard let url = URL(string: urlString), !(url.scheme ?? "").isEmpty else { fail("bad_url", "Not a URL: \(urlString)") }
    Store.requireSelectors(note, ["addAttachmentWithUTI:withURL:"])
    let attachment = view(note, as: ICNote.self).addAttachment(uti: UTI.url, url: url)
    // addAttachmentWithUTI:withURL: does not record a web URL; Notes' own link cards keep it in urlString.
    if let attachment, kv(attachment, "urlString") == nil { (attachment as! NSObject).setValue(url.absoluteString, forKey: "urlString") }
    return objectFor(attachment, "link card")
}

/// opts: width (points, default 400), ink (pen, pencil, marker), color (#rrggbb).
func makeDrawing(_ note: AnyObject, svg path: String, options: [String: String]) -> NSAttributedString {
    requireClassMethod("ICPaperAttachmentCreationHelper", "createSystemPaperAttachmentWithPKDrawing:inNote:", "Cannot create drawings on this macOS.")
    let result = drawingFromSVG(path: resolvePath(path), width: Double(options["width"] ?? "") ?? 400,
                                color: options["color"], ink: options["ink"] ?? "pen")
    guard case .success(let (drawing, _)) = result else {
        if case .failure(let error) = result { fail("bad_svg", error.message) }
        fail("bad_svg", "The SVG could not be converted.")
    }
    let helper = NotesShared.classObject("ICPaperAttachmentCreationHelper", as: ICPaperAttachmentCreationHelperClass.self)
    return objectFor(helper.createSystemPaperAttachment(drawing: drawing as AnyObject, note: note), "drawing")
}
