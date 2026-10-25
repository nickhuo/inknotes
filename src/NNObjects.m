#import "NNObjects.h"
#import "NNDocument.h"
#import "NNStore.h"
#import "NNSVG.h"

NSAttributedString *objectChar(NSString *identifier, NSString *uti) {
  id a = [[NSClassFromString(@"ICTTAttachment") alloc] init];
  MSG(void, id)(a, @selector(setAttachmentIdentifier:), identifier);
  MSG(void, id)(a, @selector(setAttachmentUTI:), uti);
  return [[NSAttributedString alloc] initWithString:@"￼" attributes:@{kAttachmentKey: a}];
}

BOOL textHasAttachment(id note, NSString *identifier) {
  __block BOOL found = NO;
  NSAttributedString *as = bodyText(note);
  [as enumerateAttribute:kAttachmentKey inRange:NSMakeRange(0, as.length) options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
    if (v && [MSG0(id)(v, @selector(attachmentIdentifier)) isEqualToString:identifier]) found = *stop = YES;
  }];
  return found;
}

// Inserts `content` (whole paragraphs, each ending in "\n" except possibly the
// last) after paragraph `afterIndex`, or at the end of the note when it is -1.

#pragma mark - Writes: creating attachments

static NSString *newID(void) { return [NSUUID UUID].UUIDString; }

// Relative paths in Markdown resolve against the Markdown file's folder.
static NSString *gBaseDir;
void setRelativePathBase(NSString *dir) { gBaseDir = dir; }
NSString *resolvePath(NSString *p) {
  p = p.stringByExpandingTildeInPath;
  if (p.isAbsolutePath || !gBaseDir) return p;
  return [gBaseDir stringByAppendingPathComponent:p];
}

NSAttributedString *makeTag(id note, NSString *tag) {
  SEL make = @selector(newHashtagAttachmentWithIdentifier:hashtagText:creatingHashtagIfNecessary:note:parentAttachment:);
  Class Inline = NSClassFromString(@"ICInlineAttachment");
  if (![Inline respondsToSelector:make]) fail(@"unsupported_macos", @"Cannot create tags on this macOS.");
  NSString *ident = newID();
  if (!MSG(id, id, id, BOOL, id, id)(Inline, make, ident, tag, YES, note, nil)) fail(@"tag_failed", @"Notes did not create the tag.");
  return objectChar(ident, kUTIHashtag);
}

// A link to `target`, or to one of its paragraphs when `paragraphID` is set.
NSAttributedString *makeNoteLink(id note, id target, NSUUID *paragraphID, NSString *paragraphName) {
  Class Inline = NSClassFromString(@"ICInlineAttachment");
  NSString *ident = newID();
  id att;
  if (paragraphID) {
    SEL make = @selector(newParagraphLinkAttachmentWithIdentifier:toNote:paragraphName:paragraphID:fromNote:parentAttachment:);
    if (![Inline respondsToSelector:make]) fail(@"unsupported_macos", @"Cannot create paragraph links on this macOS.");
    att = MSG(id, id, id, id, id, id, id)(Inline, make, ident, target, paragraphName, paragraphID, note, nil);
  } else {
    SEL make = @selector(newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:);
    if (![Inline respondsToSelector:make]) fail(@"unsupported_macos", @"Cannot create note links on this macOS.");
    att = MSG(id, id, id, id, id)(Inline, make, ident, target, note, nil);
  }
  if (!att) fail(@"link_failed", @"Notes did not create the link.");
  return objectChar(ident, kUTILink);
}

NSAttributedString *makeDivider(id note) {
  SEL make = @selector(newDividerLineAttachmentWithIdentifier:note:parentAttachment:);
  Class Inline = NSClassFromString(@"ICInlineAttachment");
  if (![Inline respondsToSelector:make]) fail(@"unsupported_macos", @"Cannot create divider lines on this macOS.");
  NSString *ident = newID();
  id att = MSG(id, id, id, id)(Inline, make, ident, note, nil);
  return objectChar(ident, [att valueForKey:@"typeUTI"] ?: @"com.apple.notes.inlinetextattachment.dividerline");
}

static NSAttributedString *objectForAttachment(id att, NSString *what) {
  NSString *ident = [att valueForKey:@"identifier"];
  if (!ident) fail(@"attachment_failed", [NSString stringWithFormat:@"Notes did not create the %@.", what]);
  return objectChar(ident, [att valueForKey:@"typeUTI"]);
}

NSAttributedString *makeTable(id note, NSArray<NSArray<NSString *> *> *rows) {
  if (![note respondsToSelector:@selector(addTableAttachmentWithText:)]) fail(@"unsupported_macos", @"Cannot create tables on this macOS.");
  // The table builder uses an NSMutableAttributedString category from NotesUI.
  dlopen("/System/Library/PrivateFrameworks/NotesUI.framework/NotesUI", RTLD_NOW);
  if (![NSMutableAttributedString instancesRespondToSelector:@selector(ic_convertParagraphStyleToBodyInRange:)])
    fail(@"unsupported_macos", @"NotesUI's table helpers are unavailable on this macOS.");
  NSMutableArray *lines = [NSMutableArray array];
  for (NSArray *r in rows) [lines addObject:[r componentsJoinedByString:@"\t"]];
  id att = MSG(id, id)(note, @selector(addTableAttachmentWithText:), [[NSAttributedString alloc] initWithString:[lines componentsJoinedByString:@"\n"]]);
  return objectForAttachment(att, @"table");
}

NSAttributedString *makeFile(id note, NSString *path) {
  NSURL *url = [NSURL fileURLWithPath:resolvePath(path)];
  if (![NSFileManager.defaultManager isReadableFileAtPath:url.path]) fail(@"file_not_found", [NSString stringWithFormat:@"Cannot read %@.", path]);
  requireSelectors(note, @[@"addAttachmentWithFileURL:"]);
  return objectForAttachment(MSG(id, id)(note, @selector(addAttachmentWithFileURL:), url), @"attachment");
}

NSAttributedString *makeURLCard(id note, NSString *urlString) {
  NSURL *url = [NSURL URLWithString:urlString];
  if (!url.scheme.length) fail(@"bad_url", [NSString stringWithFormat:@"Not a URL: %@", urlString]);
  requireSelectors(note, @[@"addAttachmentWithUTI:withURL:"]);
  id att = MSG(id, id, id)(note, @selector(addAttachmentWithUTI:withURL:), kUTIURL, url);
  // addAttachmentWithUTI:withURL: does not record a web URL; Notes' own link cards keep it in urlString.
  if (att && ![att valueForKey:@"urlString"]) [att setValue:url.absoluteString forKey:@"urlString"];
  return objectForAttachment(att, @"link card");
}

NSAttributedString *makeDrawing(id note, NSString *svgPath, NSDictionary *opts, NSDictionary **stats) {
  Class Helper = NSClassFromString(@"ICPaperAttachmentCreationHelper");
  SEL make = @selector(createSystemPaperAttachmentWithPKDrawing:inNote:);
  if (![Helper respondsToSelector:make]) fail(@"unsupported_macos", @"Cannot create drawings on this macOS.");
  NSError *err = nil;
  PKDrawing *drawing = NNDrawingFromSVG(resolvePath(svgPath), opts[@"width"] ? [opts[@"width"] doubleValue] : 400,
                                        opts[@"color"], opts[@"ink"] ?: @"pen", stats, &err);
  if (!drawing) fail(@"bad_svg", err.localizedDescription);
  id att = MSG(id, id, id)(Helper, make, drawing, note);
  return objectForAttachment(att, @"drawing");
}
