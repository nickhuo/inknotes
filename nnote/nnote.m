// nnote: read and edit Apple Notes natively through Notes' private NotesShared
// framework. Built for agents: every command prints JSON; writes are dry runs
// unless --apply is passed; writes are limited to the accounts listed in
// NNOTE_WRITABLE_ACCOUNTS (default "On My Mac").
//
// Reverse-engineered on macOS 27.2 (26B5112a). Needs Full Disk Access.
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <dlfcn.h>
#import <objc/message.h>
#import "svg.h"

#define MSG0(T) ((T (*)(id, SEL))objc_msgSend)
#define MSG(T, ...) ((T (*)(id, SEL, __VA_ARGS__))objc_msgSend)

static NSString *const kVersion = @"0.2.1";

// Text attribute keys, as stored by Notes (found by surveying every note).
static NSString *const kStyleKey = @"TTStyle";             // ICTTParagraphStyle
static NSString *const kAttachmentKey = @"NSAttachment";    // ICTTAttachment
static NSString *const kLinkKey = @"NSLink";                // NSURL
static NSString *const kHintsKey = @"TTHints";              // font traits: 1 bold, 2 italic
static NSString *const kUnderlineKey = @"TTUnderline";      // 1
static NSString *const kStrikeKey = @"TTStrikethrough";     // 1
static NSString *const kEmphasisKey = @"TTEmphasis";        // highlight color, 1-5

static NSString *const kUTIHashtag = @"com.apple.notes.inlinetextattachment.hashtag";
static NSString *const kUTILink = @"com.apple.notes.inlinetextattachment.link";
static NSString *const kUTITable = @"com.apple.notes.table";
static NSString *const kUTIURL = @"public.url";

enum { kStyleTitle = 0, kStyleHeading = 1, kStyleSubheading = 2, kStyleBody = 3, kStyleMono = 4,
       kStyleBullet = 100, kStyleDash = 101, kStyleNumbered = 102, kStyleChecklist = 103 };
// -[ICNoteContext initWithOptions:]: 0x40 opens every store read-only.
static const NSUInteger kContextReadOnly = 0x40;

static NSDictionary<NSString *, NSNumber *> *styleNames(void) {
  return @{@"title": @0, @"heading": @1, @"subheading": @2, @"body": @3, @"monospaced": @4,
           @"bullet": @100, @"dash": @101, @"numbered": @102, @"checklist": @103};
}

static NSString *styleName(long s) {
  for (NSString *k in styleNames()) if (styleNames()[k].longValue == s) return k;
  return [NSString stringWithFormat:@"style%ld", s];
}

// TTEmphasis values, confirmed in Notes.app's highlight menu (macOS 27.2).
static NSArray<NSString *> *highlightNames(void) { return @[@"purple", @"pink", @"orange", @"mint", @"blue"]; }

static id highlightName(NSNumber *v) {
  NSInteger i = v.integerValue;
  return i >= 1 && i <= 5 ? highlightNames()[i - 1] : v;
}

// "pink" or "2" -> 2; "none" or "0" -> 0; anything else -> -1.
static NSInteger highlightValue(NSString *s) {
  s = s.lowercaseString;
  NSUInteger i = [highlightNames() indexOfObject:s];
  if (i != NSNotFound) return (NSInteger)i + 1;
  if ([s isEqualToString:@"none"]) return 0;
  NSInteger n = s.integerValue;
  return [s isEqualToString:[@(n) stringValue]] && n >= 0 && n <= 5 ? n : -1;
}

#pragma mark - Output

static void emit(id obj) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:obj
                                              options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                                error:NULL];
  fwrite(d.bytes, 1, d.length, stdout);
  fputc('\n', stdout);
}

__attribute__((noreturn)) static void fail(NSString *code, NSString *message) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"error": code, @"message": message ?: @""} options:0 error:NULL];
  fwrite(d.bytes, 1, d.length, stderr);
  fputc('\n', stderr);
  exit(1);
}

#pragma mark - Context

static id gCtx;
static NSManagedObjectContext *gMOC;

static void openContext(BOOL writable) {
  if (!dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_NOW))
    fail(@"framework_unavailable", @(dlerror()));
  Class Ctx = NSClassFromString(@"ICNoteContext");
  for (NSString *sel in @[@"startSharedContextWithOptions:", @"sharedContext"])
    if (![Ctx respondsToSelector:NSSelectorFromString(sel)])
      fail(@"unsupported_macos", [NSString stringWithFormat:@"ICNoteContext lacks %@", sel]);
  MSG(void, NSUInteger)(Ctx, @selector(startSharedContextWithOptions:), writable ? 0 : kContextReadOnly);
  gCtx = MSG0(id)(Ctx, @selector(sharedContext));
  gMOC = MSG0(id)(gCtx, @selector(managedObjectContext));
  if (!gMOC) fail(@"no_access", @"Could not open the Notes database. Does this process have Full Disk Access?");
  if (!writable)
    for (NSPersistentStore *s in gMOC.persistentStoreCoordinator.persistentStores)
      if (!s.isReadOnly) fail(@"store_not_read_only", @"Refusing to read through a writable store.");
}

static NSArray *fetch(NSString *entity, NSPredicate *pred) {
  NSFetchRequest *r = [NSFetchRequest fetchRequestWithEntityName:entity];
  r.predicate = pred;
  NSError *err = nil;
  NSArray *out = [gMOC executeFetchRequest:r error:&err];
  if (!out) fail(@"fetch_failed", err.localizedDescription);
  return out;
}

#pragma mark - Accounts, folders, notes

static NSString *isoDate(NSDate *d) {
  if (!d) return (id)NSNull.null;
  return [[NSISO8601DateFormatter new] stringFromDate:d];
}

static NSArray *allAccounts(void) {
  return MSG(id, id)(NSClassFromString(@"ICAccount"), @selector(allActiveAccountsInContext:), gMOC) ?: @[];
}

static id accountNamed(NSString *name) {
  for (id a in allAccounts()) if ([[a valueForKey:@"name"] caseInsensitiveCompare:name] == NSOrderedSame) return a;
  fail(@"account_not_found", [NSString stringWithFormat:@"No account named \"%@\".", name]);
}

static NSString *folderPath(id folder) {
  NSMutableArray *parts = [NSMutableArray array];
  for (id f = folder; f; f = [f valueForKey:@"parent"]) [parts insertObject:[f valueForKey:@"title"] ?: @"" atIndex:0];
  return [parts componentsJoinedByString:@"/"];
}

static BOOL isTrash(id folder) {
  return [folder respondsToSelector:@selector(isTrashFolder)] && MSG0(BOOL)(folder, @selector(isTrashFolder));
}

// A folder by id, or by path ("Parent/Child") inside `accountName`.
static id resolveFolder(NSString *ref, NSString *accountName) {
  id byID = MSG(id, id, id)(NSClassFromString(@"ICFolder"), @selector(folderWithIdentifier:context:), ref, gMOC);
  if (byID) return byID;
  id account = accountNamed(accountName ?: @"On My Mac");
  NSMutableArray *hits = [NSMutableArray array];
  for (id f in MSG0(id)(account, @selector(visibleFolders)))
    if ([folderPath(f) caseInsensitiveCompare:ref] == NSOrderedSame) [hits addObject:f];
  if (!hits.count) fail(@"folder_not_found", [NSString stringWithFormat:@"No folder \"%@\" in %@.", ref, [account valueForKey:@"name"]]);
  if (hits.count > 1) fail(@"ambiguous_folder", [NSString stringWithFormat:@"Several folders are called \"%@\"; pass its id.", ref]);
  return hits[0];
}

static id resolveNote(NSString *ref) {
  NSURL *uri = nil;
  if ([ref hasPrefix:@"x-coredata://"]) {
    uri = [NSURL URLWithString:ref];
  } else if (ref.length && [ref rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound) {
    NSString *storeID = gMOC.persistentStoreCoordinator.persistentStores.firstObject.metadata[NSStoreUUIDKey];
    uri = [NSURL URLWithString:[NSString stringWithFormat:@"x-coredata://%@/ICNote/p%@", storeID, ref]];
  } else {
    id note = MSG(id, id, id)(NSClassFromString(@"ICNote"), @selector(noteWithIdentifier:context:), ref.uppercaseString, gMOC);
    if (note) return note;
    fail(@"note_not_found", [NSString stringWithFormat:@"No note with id %@", ref]);
  }
  NSManagedObjectID *oid = [gMOC.persistentStoreCoordinator managedObjectIDForURIRepresentation:uri];
  id note = oid ? [gMOC existingObjectWithID:oid error:NULL] : nil;
  if (!note || ![note isKindOfClass:NSClassFromString(@"ICNote")])
    fail(@"note_not_found", [NSString stringWithFormat:@"No note %@", ref]);
  return note;
}

static NSArray *visibleNotes(NSPredicate *extra) {
  NSPredicate *visible = MSG(id, id)(NSClassFromString(@"ICNote"), @selector(predicateForVisibleNotesInContext:), gMOC);
  NSPredicate *p = extra ? [NSCompoundPredicate andPredicateWithSubpredicates:@[visible, extra]] : visible;
  return MSG(id, id, id)(NSClassFromString(@"ICNote"), @selector(notesMatchingPredicate:context:), p, gMOC);
}

// A note by exact title in one account (for [[Title]] links in Markdown).
static id noteTitled(NSString *title, id account) {
  NSArray *hits = visibleNotes([NSPredicate predicateWithFormat:@"title ==[c] %@ AND account == %@", title, account]);
  if (!hits.count) fail(@"note_not_found", [NSString stringWithFormat:@"No note titled \"%@\" in %@.", title, [account valueForKey:@"name"]]);
  if (hits.count > 1) fail(@"ambiguous_note", [NSString stringWithFormat:@"%lu notes are titled \"%@\"; link by id instead.", (unsigned long)hits.count, title]);
  return hits[0];
}

static BOOL isPinned(id note) { return [note respondsToSelector:@selector(isPinned)] && MSG0(BOOL)(note, @selector(isPinned)); }

static NSDictionary *noteSummary(id note) {
  return @{
    @"id": [note valueForKey:@"identifier"] ?: NSNull.null,
    @"uri": [[note objectID] URIRepresentation].absoluteString,
    @"title": [note valueForKey:@"title"] ?: @"",
    @"account": [note valueForKeyPath:@"account.name"] ?: NSNull.null,
    @"folder": [note valueForKey:@"folder"] ? folderPath([note valueForKey:@"folder"]) : NSNull.null,
    @"pinned": @(isPinned(note)),
    @"modified": isoDate([note valueForKey:@"modificationDate"]),
  };
}

static id mergeable(id note) { return MSG0(id)(note, @selector(mergeableString)); }
static NSAttributedString *bodyText(id note) { return MSG0(id)(mergeable(note), @selector(attributedString)); }

#pragma mark - Paragraphs

typedef struct { NSRange range, enclosing; } Para;

static NSArray<NSValue *> *paragraphRanges(NSAttributedString *as) {
  NSMutableArray *out = [NSMutableArray array];
  [as.string enumerateSubstringsInRange:NSMakeRange(0, as.length)
                                options:NSStringEnumerationByParagraphs | NSStringEnumerationSubstringNotRequired
                             usingBlock:^(NSString *s, NSRange r, NSRange er, BOOL *stop) {
    Para p = {r, er};
    [out addObject:[NSValue valueWithBytes:&p objCType:@encode(Para)]];
  }];
  return out;
}

static Para paraAt(NSArray<NSValue *> *ps, NSUInteger i) { Para p; [ps[i] getValue:&p]; return p; }

static id styleAt(NSAttributedString *as, NSRange r) {
  if (!as.length) return nil;
  return [as attribute:kStyleKey atIndex:MIN(r.location, as.length - 1) effectiveRange:NULL];
}

static NSString *typeForUTI(NSString *uti, id att) {
  if ([uti isEqualToString:kUTIHashtag]) return @"tag";
  if ([uti isEqualToString:kUTILink]) return @"link";
  if ([uti isEqualToString:kUTITable]) return @"table";
  if ([uti isEqualToString:kUTIURL]) return @"url";
  if ([uti hasPrefix:@"com.apple.paper"] || [uti hasPrefix:@"com.apple.drawing"]) return @"drawing";
  if ([uti hasPrefix:@"com.apple.notes.inlinetextattachment."]) return [uti substringFromIndex:37];
  return @"file";
}

static NSDictionary *attachmentInfo(id tt) {
  NSString *uti = MSG0(id)(tt, @selector(attachmentUTI)) ?: @"";
  NSString *ident = MSG0(id)(tt, @selector(attachmentIdentifier)) ?: @"";
  NSMutableDictionary *info = [@{@"id": ident, @"uti": uti, @"type": typeForUTI(uti, nil)} mutableCopy];
  if ([uti hasPrefix:@"com.apple.notes.inlinetextattachment."]) {
    id inl = MSG(id, id)(tt, @selector(inlineAttachmentInContext:), gMOC);
    if (inl) {
      info[@"text"] = [inl valueForKey:@"displayText"] ?: @"";
      if ([uti isEqualToString:kUTILink]) info[@"target"] = [inl valueForKey:@"tokenContentIdentifier"] ?: @"";
    }
    return info;
  }
  id att = MSG(id, id)(tt, @selector(attachmentInContext:), gMOC);
  if (!att) return info;
  if ([uti isEqualToString:kUTITable]) {
    id table = MSG0(id)(MSG0(id)(att, @selector(tableModel)), @selector(table));
    if (table && [table respondsToSelector:@selector(rowCount)] && [table respondsToSelector:@selector(columnCount)]) {
      NSUInteger rows = MSG0(NSUInteger)(table, @selector(rowCount)), cols = MSG0(NSUInteger)(table, @selector(columnCount));
      NSMutableArray *grid = [NSMutableArray array];
      for (NSUInteger r = 0; r < rows; r++) {
        NSMutableArray *row = [NSMutableArray array];
        for (NSUInteger c = 0; c < cols; c++) {
          id cell = MSG(id, NSUInteger, NSUInteger)(table, @selector(stringForColumnIndex:rowIndex:), c, r);
          [row addObject:[cell isKindOfClass:NSAttributedString.class] ? [cell string] : ([cell description] ?: @"")];
        }
        [grid addObject:row];
      }
      info[@"rows"] = grid;
    }
  } else {
    NSString *title = [att respondsToSelector:@selector(title)] ? MSG0(id)(att, @selector(title)) : nil;
    if (title.length) info[@"title"] = title;
    NSString *url = [att respondsToSelector:@selector(urlString)] ? MSG0(id)(att, @selector(urlString)) : nil;
    if (!url.length && [att respondsToSelector:@selector(URL)]) url = [MSG0(id)(att, @selector(URL)) absoluteString];
    if (url.length) info[@"url"] = url;
  }
  return info;
}

// Character formatting in a range, as spans of identical formatting.
static NSArray *formatSpans(NSAttributedString *as, NSRange range) {
  NSMutableArray *out = [NSMutableArray array];
  [as enumerateAttributesInRange:range options:0 usingBlock:^(NSDictionary *a, NSRange r, BOOL *stop) {
    if (a[kAttachmentKey]) return;
    NSMutableDictionary *f = [NSMutableDictionary dictionary];
    NSInteger hints = [a[kHintsKey] integerValue];
    if (hints & 1) f[@"bold"] = @YES;
    if (hints & 2) f[@"italic"] = @YES;
    if ([a[kUnderlineKey] integerValue]) f[@"underline"] = @YES;
    if ([a[kStrikeKey] integerValue]) f[@"strike"] = @YES;
    if ([a[kEmphasisKey] integerValue]) f[@"highlight"] = highlightName(a[kEmphasisKey]);
    if (a[kLinkKey]) f[@"link"] = [a[kLinkKey] description];
    if (!f.count) return;
    f[@"text"] = [as.string substringWithRange:r];
    [out addObject:f];
  }];
  return out;
}

static NSArray *paragraphsJSON(NSAttributedString *as) {
  NSArray *ps = paragraphRanges(as);
  NSMutableArray *out = [NSMutableArray array];
  for (NSUInteger i = 0; i < ps.count; i++) {
    Para p = paraAt(ps, i);
    NSMutableString *text = [NSMutableString string];
    NSMutableArray *atts = [NSMutableArray array];
    [as enumerateAttribute:kAttachmentKey inRange:p.range options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
      if (v) {
        NSDictionary *info = attachmentInfo(v);
        [atts addObject:info];
        [text appendString:info[@"text"] ?: [NSString stringWithFormat:@"[%@]", info[@"type"]]];
      } else {
        [text appendString:[as.string substringWithRange:r]];
      }
    }];
    id style = styleAt(as, p.range);
    long s = style ? MSG0(long)(style, @selector(style)) : kStyleBody;
    NSMutableDictionary *para = [@{@"index": @(i), @"text": text, @"style": styleName(s)} mutableCopy];
    id puuid = style ? MSG0(id)(style, @selector(uuid)) : nil;
    if (puuid) para[@"paragraph_id"] = [puuid UUIDString];
    if (style && MSG0(NSUInteger)(style, @selector(indent))) para[@"indent"] = @(MSG0(NSUInteger)(style, @selector(indent)));
    if (style && [style respondsToSelector:@selector(blockQuoteLevel)] && MSG0(NSInteger)(style, @selector(blockQuoteLevel)))
      para[@"quote"] = @(MSG0(NSInteger)(style, @selector(blockQuoteLevel)));
    id todo = style ? MSG0(id)(style, @selector(todo)) : nil;
    if (todo) para[@"todo"] = @{@"uuid": [MSG0(id)(todo, @selector(uuid)) UUIDString] ?: @"",
                               @"done": @(MSG0(BOOL)(todo, @selector(done)))};
    if (atts.count) para[@"attachments"] = atts;
    NSArray *spans = formatSpans(as, p.range);
    if (spans.count) para[@"formats"] = spans;
    [out addObject:para];
  }
  return out;
}

static NSDictionary *noteJSON(id note) {
  NSMutableDictionary *d = [noteSummary(note) mutableCopy];
  d[@"paragraphs"] = paragraphsJSON(bodyText(note));
  return d;
}

static NSUInteger findParagraph(NSArray *parasJSON, NSString *text, NSString *indexArg) {
  if (indexArg) {
    NSInteger i = indexArg.integerValue;
    if (i < 0 || (NSUInteger)i >= parasJSON.count) fail(@"bad_index", @"Paragraph index out of range.");
    return (NSUInteger)i;
  }
  if (!text) fail(@"usage", @"Name the paragraph by its text, or pass --index N.");
  NSMutableArray *hits = [NSMutableArray array];
  for (NSDictionary *p in parasJSON) if ([p[@"text"] isEqualToString:text]) [hits addObject:p[@"index"]];
  if (!hits.count) fail(@"paragraph_not_found", [NSString stringWithFormat:@"No paragraph with text \"%@\".", text]);
  if (hits.count > 1) fail(@"ambiguous_paragraph", [NSString stringWithFormat:@"%lu paragraphs read \"%@\"; pass --index (one of %@).",
                                                    (unsigned long)hits.count, text, [hits componentsJoinedByString:@", "]]);
  return [hits[0] unsignedIntegerValue];
}

#pragma mark - Markdown export

static NSString *inlineMarkdown(NSAttributedString *as, NSRange range) {
  NSMutableString *out = [NSMutableString string];
  [as enumerateAttributesInRange:range options:0 usingBlock:^(NSDictionary *a, NSRange r, BOOL *stop) {
    if (a[kAttachmentKey]) {
      NSDictionary *i = attachmentInfo(a[kAttachmentKey]);
      NSString *t = i[@"type"];
      if ([t isEqualToString:@"tag"]) [out appendString:i[@"text"] ?: @""];
      else if ([t isEqualToString:@"link"]) [out appendFormat:@"[%@](%@)", i[@"text"] ?: @"", i[@"target"] ?: @""];
      else if ([t isEqualToString:@"url"]) [out appendFormat:@"<%@>", i[@"url"] ?: @""];
      else if ([t isEqualToString:@"table"]) {
        NSArray *rows = i[@"rows"];
        for (NSUInteger k = 0; k < rows.count; k++) {
          [out appendFormat:@"%@| %@ |", k ? @"\n" : @"", [rows[k] componentsJoinedByString:@" | "]];
          if (k == 0) {
            NSMutableArray *sep = [NSMutableArray array];
            for (NSUInteger c = 0; c < [rows[0] count]; c++) [sep addObject:@"---"];
            [out appendFormat:@"\n| %@ |", [sep componentsJoinedByString:@" | "]];
          }
        }
      } else [out appendFormat:@"![%@](attachment:%@)", i[@"title"] ?: t, i[@"id"]];
      return;
    }
    NSString *s = [as.string substringWithRange:r];
    NSString *trimmed = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!trimmed.length) { [out appendString:s]; return; }
    NSInteger hints = [a[kHintsKey] integerValue];
    NSMutableString *open = [NSMutableString string], *close = [NSMutableString string];
    void (^wrap)(NSString *) = ^(NSString *m) { [open appendString:m]; [close insertString:m atIndex:0]; };
    if (hints & 1) wrap(@"**");
    if (hints & 2) wrap(@"*");
    if ([a[kStrikeKey] integerValue]) wrap(@"~~");
    NSInteger emphasis = [a[kEmphasisKey] integerValue];
    if (emphasis) {
      [open appendString:emphasis == 1 ? @"==" : [NSString stringWithFormat:@"=={%@}", highlightName(a[kEmphasisKey])]];
      [close insertString:@"==" atIndex:0];
    }
    NSString *body = [NSString stringWithFormat:@"%@%@%@", open, s, close];
    if (a[kLinkKey]) body = [NSString stringWithFormat:@"[%@](%@)", body, [a[kLinkKey] description]];
    [out appendString:body];
  }];
  return out;
}

static NSString *noteMarkdown(id note) {
  NSAttributedString *as = bodyText(note);
  NSArray *ps = paragraphRanges(as);
  NSMutableString *md = [NSMutableString string];
  BOOL inCode = NO;
  NSInteger numbered = 0;
  for (NSUInteger i = 0; i < ps.count; i++) {
    Para p = paraAt(ps, i);
    id style = styleAt(as, p.range);
    long s = style ? MSG0(long)(style, @selector(style)) : kStyleBody;
    NSUInteger indent = style ? MSG0(NSUInteger)(style, @selector(indent)) : 0;
    if (s == kStyleMono && !inCode) { [md appendString:@"```\n"]; inCode = YES; }
    if (s != kStyleMono && inCode) { [md appendString:@"```\n"]; inCode = NO; }
    numbered = s == kStyleNumbered ? numbered + 1 : 0;
    NSString *text = s == kStyleMono ? [as.string substringWithRange:p.range] : inlineMarkdown(as, p.range);
    NSString *pad = [@"" stringByPaddingToLength:indent * 2 withString:@" " startingAtIndex:0];
    NSInteger quote = style && [style respondsToSelector:@selector(blockQuoteLevel)] ? MSG0(NSInteger)(style, @selector(blockQuoteLevel)) : 0;
    NSString *q = [@"" stringByPaddingToLength:quote * 2 withString:@"> " startingAtIndex:0];
    switch (s) {
      case kStyleTitle: [md appendFormat:@"# %@\n", text]; break;
      case kStyleHeading: [md appendFormat:@"## %@\n", text]; break;
      case kStyleSubheading: [md appendFormat:@"### %@\n", text]; break;
      case kStyleBullet: case kStyleDash: [md appendFormat:@"%@%@- %@\n", q, pad, text]; break;
      case kStyleNumbered: [md appendFormat:@"%@%@%ld. %@\n", q, pad, (long)numbered, text]; break;
      case kStyleChecklist: {
        BOOL done = MSG0(BOOL)(MSG0(id)(style, @selector(todo)), @selector(done));
        [md appendFormat:@"%@%@- [%@] %@\n", q, pad, done ? @"x" : @" ", text]; break;
      }
      default: [md appendFormat:@"%@%@\n", q, text];
    }
  }
  if (inCode) [md appendString:@"```\n"];
  return md;
}

#pragma mark - Writes: guards and saving

static NSSet *writableAccounts(void) {
  NSString *allowed = NSProcessInfo.processInfo.environment[@"NNOTE_WRITABLE_ACCOUNTS"] ?: @"On My Mac";
  NSMutableSet *set = [NSMutableSet set];
  for (NSString *a in [allowed componentsSeparatedByString:@","])
    [set addObject:[[a stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString]];
  return set;
}

static void guardAccount(id account) {
  NSString *name = [account valueForKey:@"name"];
  if (![writableAccounts() containsObject:name.lowercaseString])
    fail(@"account_not_writable", [NSString stringWithFormat:@"Account \"%@\" is not writable. Writable accounts: %@ (set NNOTE_WRITABLE_ACCOUNTS).",
                                   name, NSProcessInfo.processInfo.environment[@"NNOTE_WRITABLE_ACCOUNTS"] ?: @"On My Mac"]);
}

static void guardWritable(id note) {
  guardAccount([note valueForKey:@"account"]);
  if ([[note valueForKey:@"markedForDeletion"] boolValue] || isTrash([note valueForKey:@"folder"]))
    fail(@"note_deleted", @"Note is deleted or in Recently Deleted.");
  if ([note respondsToSelector:@selector(isPasswordProtected)] && MSG0(BOOL)(note, @selector(isPasswordProtected)))
    fail(@"note_locked", @"Note is locked with a password.");
}

static void requireSelectors(id obj, NSArray *sels) {
  for (NSString *s in sels)
    if (![obj respondsToSelector:NSSelectorFromString(s)])
      fail(@"unsupported_macos", [NSString stringWithFormat:@"%@ lacks %@", NSStringFromClass([obj class]), s]);
}

static void saveAndNotify(void) {
  MSG0(void)(gCtx, @selector(save));
  NSError *err = nil;
  if (gMOC.hasChanges && ![gMOC save:&err]) fail(@"save_failed", err.localizedDescription);
  // Tell a running Notes.app that another process saved, the way Notes' editor
  // extension does; otherwise it may overwrite this change with its open copy.
  id coordinator = MSG0(id)(gCtx, @selector(crossProcessChangeCoordinator));
  if (coordinator) MSG0(void)(coordinator, @selector(postEditorExtensionDidSaveNotification));
}

// Runs `edit` inside Notes' editing calls, then saves the way a user edit does.
static void commit(id note, NSString *reason, void (^edit)(id ms)) {
  requireSelectors(note, @[@"beginEditing", @"endEditing", @"didChangeNoteText", @"saveNoteData", @"updateChangeCountWithReason:"]);
  id ms = mergeable(note);
  MSG0(void)(note, @selector(beginEditing));
  edit(ms);
  MSG0(void)(note, @selector(endEditing));
  MSG0(void)(note, @selector(didChangeNoteText));
  MSG0(void)(note, @selector(saveNoteData));
  if ([note respondsToSelector:@selector(regenerateTitle:snippet:)])
    MSG(BOOL, BOOL, BOOL)(note, @selector(regenerateTitle:snippet:), YES, YES);
  [note setValue:[NSDate date] forKey:@"modificationDate"];
  MSG(void, id)(note, @selector(updateChangeCountWithReason:), reason);
  saveAndNotify();
}

#pragma mark - Writes: building text

static id newTodo(BOOL done) {
  return MSG(id, id, BOOL)([NSClassFromString(@"ICTTTodo") alloc], @selector(initWithIdentifier:done:), [NSUUID UUID], done);
}

static id newStyle(long style, NSUInteger indent, NSInteger quote, BOOL done) {
  id s = [[NSClassFromString(@"ICTTMutableParagraphStyle") alloc] init];
  MSG(void, long)(s, @selector(setStyle:), style);
  MSG(void, id)(s, @selector(setUuid:), [NSUUID UUID]);
  if (indent) MSG(void, NSUInteger)(s, @selector(setIndent:), indent);
  if (quote && [s respondsToSelector:@selector(setBlockQuoteLevel:)]) MSG(void, NSInteger)(s, @selector(setBlockQuoteLevel:), quote);
  MSG(void, id)(s, @selector(setTodo:), style == kStyleChecklist ? newTodo(done) : nil);
  return s;
}

static NSAttributedString *objectChar(NSString *identifier, NSString *uti) {
  id a = [[NSClassFromString(@"ICTTAttachment") alloc] init];
  MSG(void, id)(a, @selector(setAttachmentIdentifier:), identifier);
  MSG(void, id)(a, @selector(setAttachmentUTI:), uti);
  return [[NSAttributedString alloc] initWithString:@"￼" attributes:@{kAttachmentKey: a}];
}

static BOOL textHasAttachment(id note, NSString *identifier) {
  __block BOOL found = NO;
  NSAttributedString *as = bodyText(note);
  [as enumerateAttribute:kAttachmentKey inRange:NSMakeRange(0, as.length) options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
    if (v && [MSG0(id)(v, @selector(attachmentIdentifier)) isEqualToString:identifier]) found = *stop = YES;
  }];
  return found;
}

// Inserts `content` (whole paragraphs, each ending in "\n" except possibly the
// last) after paragraph `afterIndex`, or at the end of the note when it is -1.
static void insertParagraphs(id note, NSInteger afterIndex, NSAttributedString *content) {
  NSAttributedString *as = bodyText(note);
  NSArray *ps = paragraphRanges(as);
  NSUInteger at = as.length;
  if (afterIndex >= 0) at = NSMaxRange(paraAt(ps, (NSUInteger)afterIndex).enclosing);
  NSMutableAttributedString *ins = [NSMutableAttributedString new];
  BOOL prevEndsLine = at == 0 || [[as.string substringWithRange:NSMakeRange(at - 1, 1)] isEqualToString:@"\n"];
  if (!prevEndsLine) {
    id prevStyle = styleAt(as, NSMakeRange(at - 1, 0));
    [ins appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:prevStyle ? @{kStyleKey: prevStyle} : @{}]];
  }
  NSMutableAttributedString *body = [content mutableCopy];
  // Text follows the insertion point: the inserted block must end with a newline.
  if (at < as.length && ![body.string hasSuffix:@"\n"] && body.length) {
    id lastStyle = [body attribute:kStyleKey atIndex:body.length - 1 effectiveRange:NULL];
    [body appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:lastStyle ? @{kStyleKey: lastStyle} : @{}]];
  }
  [ins appendAttributedString:body];
  MSG(void, id, NSUInteger)(mergeable(note), @selector(insertAttributedString:atIndex:), ins, at);
}

// One paragraph: `content` styled with `style`, plus its newline.
static NSAttributedString *paragraph(NSAttributedString *content, id style, BOOL newline) {
  NSMutableAttributedString *line = [content mutableCopy];
  if (newline) [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
  [line addAttribute:kStyleKey value:style range:NSMakeRange(0, line.length)];
  return line;
}

#pragma mark - Writes: creating attachments

static NSString *newID(void) { return [NSUUID UUID].UUIDString; }

// Relative paths in Markdown resolve against the Markdown file's folder.
static NSString *gBaseDir;
static NSString *resolvePath(NSString *p) {
  p = p.stringByExpandingTildeInPath;
  if (p.isAbsolutePath || !gBaseDir) return p;
  return [gBaseDir stringByAppendingPathComponent:p];
}

static NSAttributedString *makeTag(id note, NSString *tag) {
  SEL make = @selector(newHashtagAttachmentWithIdentifier:hashtagText:creatingHashtagIfNecessary:note:parentAttachment:);
  Class Inline = NSClassFromString(@"ICInlineAttachment");
  if (![Inline respondsToSelector:make]) fail(@"unsupported_macos", @"Cannot create tags on this macOS.");
  NSString *ident = newID();
  if (!MSG(id, id, id, BOOL, id, id)(Inline, make, ident, tag, YES, note, nil)) fail(@"tag_failed", @"Notes did not create the tag.");
  return objectChar(ident, kUTIHashtag);
}

// A link to `target`, or to one of its paragraphs when `paragraphID` is set.
static NSAttributedString *makeNoteLink(id note, id target, NSUUID *paragraphID, NSString *paragraphName) {
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

static NSAttributedString *makeDivider(id note) {
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

static NSAttributedString *makeTable(id note, NSArray<NSArray<NSString *> *> *rows) {
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

static NSAttributedString *makeFile(id note, NSString *path) {
  NSURL *url = [NSURL fileURLWithPath:resolvePath(path)];
  if (![NSFileManager.defaultManager isReadableFileAtPath:url.path]) fail(@"file_not_found", [NSString stringWithFormat:@"Cannot read %@.", path]);
  requireSelectors(note, @[@"addAttachmentWithFileURL:"]);
  return objectForAttachment(MSG(id, id)(note, @selector(addAttachmentWithFileURL:), url), @"attachment");
}

static NSAttributedString *makeURLCard(id note, NSString *urlString) {
  NSURL *url = [NSURL URLWithString:urlString];
  if (!url.scheme.length) fail(@"bad_url", [NSString stringWithFormat:@"Not a URL: %@", urlString]);
  requireSelectors(note, @[@"addAttachmentWithUTI:withURL:"]);
  return objectForAttachment(MSG(id, id, id)(note, @selector(addAttachmentWithUTI:withURL:), kUTIURL, url), @"link card");
}

static NSAttributedString *makeDrawing(id note, NSString *svgPath, NSDictionary *opts, NSDictionary **stats) {
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

#pragma mark - Markdown import

// Blocks: {kind: para, style, indent, quote, done, text} | {kind: table, rows}
//       | {kind: file|url|drawing, value} | {kind: divider}
static NSArray<NSDictionary *> *parseMarkdown(NSString *md) {
  NSMutableArray *blocks = [NSMutableArray array];
  NSArray<NSString *> *lines = [[md stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] componentsSeparatedByString:@"\n"];
  // Indent unit: the smallest leading indentation used by a list item.
  NSUInteger unit = 0;
  NSRegularExpression *listRe = [NSRegularExpression regularExpressionWithPattern:@"^( *)([-*+]|\\d+[.)]) " options:0 error:NULL];
  for (NSString *l in lines) {
    NSTextCheckingResult *m = [listRe firstMatchInString:l options:0 range:NSMakeRange(0, l.length)];
    NSUInteger sp = m ? [m rangeAtIndex:1].length : 0;
    if (sp && (!unit || sp < unit)) unit = sp;
  }
  if (!unit) unit = 2;
  NSRegularExpression *sepRe = [NSRegularExpression regularExpressionWithPattern:@"^\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)*\\|?$" options:0 error:NULL];
  NSRegularExpression *imgRe = [NSRegularExpression regularExpressionWithPattern:@"^!\\[[^\\]]*\\]\\(([^)]+)\\)$" options:0 error:NULL];
  NSRegularExpression *urlRe = [NSRegularExpression regularExpressionWithPattern:@"^<?(https?://[^\\s>]+)>?$" options:0 error:NULL];
  BOOL inCode = NO, lastBlank = NO;
  for (NSUInteger i = 0; i < lines.count; i++) {
    NSString *raw = [lines[i] stringByReplacingOccurrencesOfString:@"\t" withString:@"    "];
    NSString *t = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([t hasPrefix:@"```"]) { inCode = !inCode; continue; }
    if (inCode) { [blocks addObject:@{@"kind": @"para", @"style": @(kStyleMono), @"text": raw, @"raw": @YES}]; continue; }
    if (!t.length) {
      if (!lastBlank && blocks.count) [blocks addObject:@{@"kind": @"para", @"style": @(kStyleBody), @"text": @""}];
      lastBlank = YES;
      continue;
    }
    lastBlank = NO;
    if ([t hasPrefix:@"|"]) {
      NSMutableArray *rows = [NSMutableArray array];
      for (; i < lines.count && [[lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] hasPrefix:@"|"]; i++) {
        NSString *row = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([sepRe firstMatchInString:row options:0 range:NSMakeRange(0, row.length)]) continue;
        if ([row hasPrefix:@"|"]) row = [row substringFromIndex:1];
        if ([row hasSuffix:@"|"]) row = [row substringToIndex:row.length - 1];
        NSMutableArray *cells = [NSMutableArray array];
        for (NSString *c in [row componentsSeparatedByString:@"|"])
          [cells addObject:[c stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
        [rows addObject:cells];
      }
      i--;
      [blocks addObject:@{@"kind": @"table", @"rows": rows}];
      continue;
    }
    if ([t isEqualToString:@"---"] || [t isEqualToString:@"***"]) { [blocks addObject:@{@"kind": @"divider"}]; continue; }
    NSTextCheckingResult *m = [imgRe firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
    if (m) {
      NSString *src = [t substringWithRange:[m rangeAtIndex:1]];
      [blocks addObject:@{@"kind": [src.pathExtension.lowercaseString isEqualToString:@"svg"] ? @"drawing" : @"file", @"value": src}];
      continue;
    }
    m = [urlRe firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
    if (m) { [blocks addObject:@{@"kind": @"url", @"value": [t substringWithRange:[m rangeAtIndex:1]]}]; continue; }

    NSInteger quote = 0;
    while ([t hasPrefix:@">"]) { quote++; t = [[t substringFromIndex:1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; }
    NSUInteger lead = raw.length - [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length;
    lead = [raw rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet.invertedSet].location;
    if (lead == NSNotFound) lead = 0;
    NSUInteger indent = lead / unit;
    long style = kStyleBody;
    BOOL done = NO;
    NSString *text = t;
    if ([t hasPrefix:@"# "]) style = kStyleTitle, text = [t substringFromIndex:2];
    else if ([t hasPrefix:@"## "]) style = kStyleHeading, text = [t substringFromIndex:3];
    else if ([t hasPrefix:@"### "] || [t hasPrefix:@"#### "]) style = kStyleSubheading, text = [t substringFromIndex:[t rangeOfString:@" "].location + 1];
    else if ([t hasPrefix:@"- [ ] "] || [t hasPrefix:@"* [ ] "] || [t hasPrefix:@"- [x] "] || [t hasPrefix:@"- [X] "] || [t hasPrefix:@"* [x] "])
      style = kStyleChecklist, done = [t characterAtIndex:3] != ' ', text = [t substringFromIndex:6];
    else if ([t hasPrefix:@"- "] || [t hasPrefix:@"* "] || [t hasPrefix:@"+ "]) style = kStyleBullet, text = [t substringFromIndex:2];
    else {
      NSTextCheckingResult *n = [[NSRegularExpression regularExpressionWithPattern:@"^\\d+[.)] " options:0 error:NULL]
                                  firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
      if (n) style = kStyleNumbered, text = [t substringFromIndex:n.range.length];
    }
    if (style < kStyleBullet) indent = 0;
    [blocks addObject:@{@"kind": @"para", @"style": @(style), @"indent": @(indent), @"quote": @(quote), @"done": @(done), @"text": text}];
  }
  while (blocks.count && [blocks.lastObject[@"kind"] isEqualToString:@"para"] && ![blocks.lastObject[@"text"] length]) [blocks removeLastObject];
  return blocks;
}

// Inline Markdown: **bold**, *italic*, ~~strike~~, ==highlight==, [text](url),
// [[Note title]] / [[Note title#Paragraph]] note links, and #tags.
// Note links and tags need a note and account to resolve; without them
// (`note` nil) they are only validated.
static NSAttributedString *parseInline(NSString *s, id note, id account, NSMutableArray *refs) {
  NSMutableAttributedString *out = [NSMutableAttributedString new];
  NSMutableDictionary *cur = [NSMutableDictionary dictionary];
  NSCharacterSet *tagChars = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-/"];
  NSUInteger i = 0, n = s.length;
  NSMutableString *buf = [NSMutableString string];
  void (^flush)(void) = ^{
    if (buf.length) { [out appendAttributedString:[[NSAttributedString alloc] initWithString:buf attributes:cur]]; [buf setString:@""]; }
  };
  BOOL (^closes)(NSString *, NSUInteger) = ^BOOL(NSString *mark, NSUInteger from) {
    return [s rangeOfString:mark options:0 range:NSMakeRange(from, n - from)].location != NSNotFound;
  };
  void (^toggle)(NSString *, id) = ^(NSString *key, id value) {
    flush();
    if (cur[key]) [cur removeObjectForKey:key]; else cur[key] = value;
  };
  while (i < n) {
    unichar c = [s characterAtIndex:i];
    NSString *rest = [s substringFromIndex:i];
    if (c == '\\' && i + 1 < n) { [buf appendFormat:@"%C", [s characterAtIndex:i + 1]]; i += 2; continue; }
    if ([rest hasPrefix:@"[["]) {
      NSRange end = [s rangeOfString:@"]]" options:0 range:NSMakeRange(i + 2, n - i - 2)];
      if (end.location != NSNotFound) {
        NSString *inner = [s substringWithRange:NSMakeRange(i + 2, end.location - i - 2)];
        NSArray *parts = [inner componentsSeparatedByString:@"#"];
        [refs addObject:@{@"link": parts[0], @"paragraph": parts.count > 1 ? parts[1] : NSNull.null}];
        flush();
        if (note) {
          id target = noteTitled(parts[0], account);
          NSUUID *pid = nil;
          NSString *pname = nil;
          if (parts.count > 1) {
            NSArray *paras = paragraphsJSON(bodyText(target));
            NSDictionary *p = paras[findParagraph(paras, parts[1], nil)];
            pid = [[NSUUID alloc] initWithUUIDString:p[@"paragraph_id"]];
            pname = p[@"text"];
          }
          [out appendAttributedString:makeNoteLink(note, target, pid, pname)];
        } else if (account) {
          noteTitled(parts[0], account);
        }
        i = end.location + 2;
        continue;
      }
    }
    if (c == '[') {
      NSRange close = [s rangeOfString:@"](" options:0 range:NSMakeRange(i, n - i)];
      NSRange paren = close.location != NSNotFound ? [s rangeOfString:@")" options:0 range:NSMakeRange(close.location, n - close.location)] : close;
      if (close.location != NSNotFound && paren.location != NSNotFound) {
        NSString *label = [s substringWithRange:NSMakeRange(i + 1, close.location - i - 1)];
        NSString *href = [s substringWithRange:NSMakeRange(close.location + 2, paren.location - close.location - 2)];
        flush();
        NSURL *u = [NSURL URLWithString:href];
        BOOL noteLink = [href hasPrefix:@"applenotes:"];
        if (noteLink) {
          // applenotes:note/<id> or applenotes://showNote?identifier=<id>&paragraphID=<uuid>
          NSURLComponents *uc = [NSURLComponents componentsWithString:href];
          NSString *nid = nil, *pidStr = nil;
          for (NSURLQueryItem *q in uc.queryItems) {
            if ([q.name isEqualToString:@"identifier"]) nid = q.value;
            if ([q.name isEqualToString:@"paragraphID"]) pidStr = q.value;
          }
          if (!nid) nid = [[href componentsSeparatedByString:@"note/"].lastObject componentsSeparatedByString:@"?"].firstObject;
          [refs addObject:@{@"link": nid ?: href, @"paragraph": pidStr ?: NSNull.null}];
          if (note) {
            id target = resolveNote(nid);
            NSString *pname = nil;
            if (pidStr) for (NSDictionary *p in paragraphsJSON(bodyText(target))) if ([p[@"paragraph_id"] isEqualToString:pidStr.uppercaseString]) pname = p[@"text"];
            [out appendAttributedString:makeNoteLink(note, target, pidStr ? [[NSUUID alloc] initWithUUIDString:pidStr] : nil, pname)];
          } else if (account) {
            resolveNote(nid);
          }
        } else {
          NSMutableDictionary *a = [cur mutableCopy];
          if (u) a[kLinkKey] = u;
          [out appendAttributedString:[[NSAttributedString alloc] initWithString:label attributes:a]];
        }
        i = paren.location + 1;
        continue;
      }
    }
    if ([rest hasPrefix:@"**"] && (cur[@"b"] || closes(@"**", i + 2))) { toggle(@"b", @YES); i += 2; continue; }
    if ([rest hasPrefix:@"~~"] && (cur[kStrikeKey] || closes(@"~~", i + 2))) { toggle(kStrikeKey, @1); i += 2; continue; }
    if ([rest hasPrefix:@"=="] && (cur[kEmphasisKey] || closes(@"==", i + 2))) {
      // ==text== is purple; =={pink}text== picks another highlight color.
      NSInteger color = 1;
      NSUInteger skip = 2;
      if (!cur[kEmphasisKey] && [rest hasPrefix:@"=={"]) {
        NSRange brace = [rest rangeOfString:@"}"];
        NSInteger v = brace.location != NSNotFound ? highlightValue([rest substringWithRange:NSMakeRange(3, brace.location - 3)]) : -1;
        if (v > 0) color = v, skip = brace.location + 1;
      }
      toggle(kEmphasisKey, @(color));
      i += skip;
      continue;
    }
    if ((c == '*' || c == '_') && (cur[@"i"] || (i + 1 < n && ![[NSCharacterSet whitespaceCharacterSet] characterIsMember:[s characterAtIndex:i + 1]] &&
                                               closes([NSString stringWithCharacters:&c length:1], i + 1) &&
                                               (c == '*' || i == 0 || ![[NSCharacterSet alphanumericCharacterSet] characterIsMember:[s characterAtIndex:i - 1]])))) {
      toggle(@"i", @YES); i += 1; continue;
    }
    if (c == '#' && (i == 0 || [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[s characterAtIndex:i - 1]]) &&
        i + 1 < n && [tagChars characterIsMember:[s characterAtIndex:i + 1]]) {
      NSUInteger j = i + 1;
      while (j < n && [tagChars characterIsMember:[s characterAtIndex:j]]) j++;
      NSString *tag = [s substringWithRange:NSMakeRange(i + 1, j - i - 1)];
      [refs addObject:@{@"tag": tag}];
      flush();
      if (note) [out appendAttributedString:makeTag(note, tag)];
      else [out appendAttributedString:[[NSAttributedString alloc] initWithString:[@"#" stringByAppendingString:tag]]];
      i = j;
      continue;
    }
    [buf appendFormat:@"%C", c];
    i++;
  }
  flush();
  // Bold and italic are one attribute in Notes: a bit mask of font traits.
  [out enumerateAttributesInRange:NSMakeRange(0, out.length) options:0 usingBlock:^(NSDictionary *a, NSRange r, BOOL *stop) {
    NSInteger hints = (a[@"b"] ? 1 : 0) | (a[@"i"] ? 2 : 0);
    [out removeAttribute:@"b" range:r];
    [out removeAttribute:@"i" range:r];
    if (hints) [out addAttribute:kHintsKey value:@(hints) range:r];
  }];
  return out;
}

// Validates blocks and resolves links without writing; returns a summary.
static NSArray *planBlocks(NSArray *blocks, id account) {
  NSMutableArray *plan = [NSMutableArray array];
  for (NSDictionary *b in blocks) {
    NSMutableDictionary *p = [@{@"kind": b[@"kind"]} mutableCopy];
    if ([b[@"kind"] isEqualToString:@"para"]) {
      NSMutableArray *refs = [NSMutableArray array];
      NSAttributedString *txt = [b[@"raw"] boolValue] ? [[NSAttributedString alloc] initWithString:b[@"text"]] : parseInline(b[@"text"], nil, account, refs);
      p[@"style"] = styleName([b[@"style"] longValue]);
      p[@"text"] = txt.string;
      if ([b[@"style"] longValue] == kStyleChecklist) p[@"done"] = b[@"done"];
      if ([b[@"indent"] integerValue]) p[@"indent"] = b[@"indent"];
      if ([b[@"quote"] integerValue]) p[@"quote"] = b[@"quote"];
      if (refs.count) p[@"refs"] = refs;
    } else if ([b[@"kind"] isEqualToString:@"table"]) {
      p[@"rows"] = b[@"rows"];
    } else if (b[@"value"]) {
      p[@"value"] = b[@"value"];
      if (![b[@"kind"] isEqualToString:@"url"] && ![NSFileManager.defaultManager isReadableFileAtPath:resolvePath(b[@"value"])])
        fail(@"file_not_found", [NSString stringWithFormat:@"Cannot read %@.", b[@"value"]]);
    }
    [plan addObject:p];
  }
  return plan;
}

// Builds the text for `blocks`, creating tags, links and attachments in `note`.
static NSAttributedString *renderBlocks(NSArray *blocks, id note, id account) {
  NSMutableAttributedString *out = [NSMutableAttributedString new];
  for (NSUInteger k = 0; k < blocks.count; k++) {
    NSDictionary *b = blocks[k];
    NSString *kind = b[@"kind"];
    NSAttributedString *content;
    id style;
    if ([kind isEqualToString:@"para"]) {
      content = [b[@"raw"] boolValue] ? [[NSAttributedString alloc] initWithString:b[@"text"]] : parseInline(b[@"text"], note, account, [NSMutableArray array]);
      style = newStyle([b[@"style"] longValue], [b[@"indent"] unsignedIntegerValue], [b[@"quote"] integerValue], [b[@"done"] boolValue]);
    } else {
      style = newStyle(kStyleBody, 0, 0, NO);
      if ([kind isEqualToString:@"table"]) content = makeTable(note, b[@"rows"]);
      else if ([kind isEqualToString:@"file"]) content = makeFile(note, b[@"value"]);
      else if ([kind isEqualToString:@"url"]) content = makeURLCard(note, b[@"value"]);
      else if ([kind isEqualToString:@"drawing"]) content = makeDrawing(note, b[@"value"], @{}, NULL);
      else content = makeDivider(note);
    }
    [out appendAttributedString:paragraph(content, style, k + 1 < blocks.count)];
  }
  return out;
}

static NSString *readInput(NSString *src) {
  if (!src) return nil;
  NSData *data = [src isEqualToString:@"-"] ? [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile]
                                            : [NSData dataWithContentsOfFile:src.stringByExpandingTildeInPath];
  if (!data) fail(@"file_not_found", [NSString stringWithFormat:@"Cannot read %@.", src]);
  if (![src isEqualToString:@"-"]) gBaseDir = [src.stringByExpandingTildeInPath.stringByStandardizingPath stringByDeletingLastPathComponent];
  if (gBaseDir && !gBaseDir.isAbsolutePath) gBaseDir = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:gBaseDir];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

#pragma mark - Arguments

typedef struct { NSString *cmd; NSMutableArray<NSString *> *pos; NSMutableDictionary<NSString *, NSString *> *opt; BOOL apply; } Args;

static Args parse(int argc, char **argv) {
  Args a = {nil, [NSMutableArray array], [NSMutableDictionary dictionary], NO};
  NSSet *flags = [NSSet setWithArray:@[@"undo", @"bold", @"italic", @"underline", @"strike", @"plain"]];
  for (int i = 1; i < argc; i++) {
    NSString *s = @(argv[i]);
    if ([s isEqualToString:@"--apply"]) a.apply = YES;
    else if ([s hasPrefix:@"--"] && [flags containsObject:[s substringFromIndex:2]]) a.opt[[s substringFromIndex:2]] = @"1";
    else if ([s hasPrefix:@"--"] && i + 1 < argc) a.opt[[s substringFromIndex:2]] = @(argv[++i]);
    else if ([s hasPrefix:@"--"]) fail(@"usage", [NSString stringWithFormat:@"%@ needs a value.", s]);
    else if (!a.cmd) a.cmd = s;
    else [a.pos addObject:s];
  }
  return a;
}

static NSString *need(Args a, NSUInteger i, NSString *what) {
  if (a.pos.count <= i) fail(@"usage", [NSString stringWithFormat:@"Missing %@. Run `nnote help`.", what]);
  return a.pos[i];
}

static NSInteger afterParagraph(Args a, id note) {
  if (!a.opt[@"after"] && !a.opt[@"index"]) return -1;
  return (NSInteger)findParagraph(paragraphsJSON(bodyText(note)), a.opt[@"after"], a.opt[@"index"]);
}

// The dry-run / apply split every write command follows.
static void writeNote(Args a, id note, NSDictionary *plan, NSString *reason, void (^edit)(void)) {
  guardWritable(note);
  if (!a.apply) { emit(@{@"dry_run": @YES, @"plan": plan}); return; }
  commit(note, reason, ^(id ms) { edit(); });
  emit(@{@"changed": @YES, @"plan": plan, @"note": noteJSON(note)});
}

#pragma mark - Read commands

static void cmdFind(Args a) {
  NSMutableArray *preds = [NSMutableArray array];
  NSString *q = a.pos.count ? a.pos[0] : nil;
  if (q.length) [preds addObject:[NSPredicate predicateWithFormat:@"title CONTAINS[cd] %@", q]];
  if (a.opt[@"account"]) [preds addObject:[NSPredicate predicateWithFormat:@"account.name ==[c] %@", a.opt[@"account"]]];
  NSArray *notes = visibleNotes(preds.count ? [NSCompoundPredicate andPredicateWithSubpredicates:preds] : nil);
  if (a.opt[@"folder"]) {
    NSString *f = a.opt[@"folder"];
    notes = [notes filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id n, NSDictionary *b) {
      id folder = [n valueForKey:@"folder"];
      return [folderPath(folder) caseInsensitiveCompare:f] == NSOrderedSame || [[folder valueForKey:@"identifier"] isEqualToString:f];
    }]];
  }
  if (a.opt[@"tag"]) {
    NSString *std = [[a.opt[@"tag"] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"#"]] uppercaseString];
    NSArray *atts = fetch(@"ICInlineAttachment", [NSPredicate predicateWithFormat:@"typeUTI == %@ AND tokenContentIdentifier ==[c] %@ AND markedForDeletion == NO", kUTIHashtag, std]);
    NSSet *tagged = [NSSet setWithArray:[atts valueForKey:@"note"]];
    notes = [notes filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id n, NSDictionary *b) { return [tagged containsObject:n]; }]];
  }
  if (a.opt[@"pinned"]) notes = [notes filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id n, NSDictionary *b) { return isPinned(n); }]];
  notes = [notes sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"modificationDate" ascending:NO]]];
  NSInteger limit = a.opt[@"limit"] ? a.opt[@"limit"].integerValue : 20;
  NSMutableArray *out = [NSMutableArray array];
  for (id n in notes) { if ((NSInteger)out.count >= limit) break; [out addObject:noteSummary(n)]; }
  emit(@{@"notes": out, @"count": @(out.count), @"total": @(notes.count)});
}

static void cmdBacklinks(Args a) {
  id note = resolveNote(need(a, 0, @"note"));
  NSString *ident = [note valueForKey:@"identifier"];
  NSArray *links = fetch(@"ICInlineAttachment", [NSPredicate predicateWithFormat:@"typeUTI == %@ AND tokenContentIdentifier CONTAINS[c] %@ AND markedForDeletion == NO", kUTILink, ident]);
  NSMutableArray *out = [NSMutableArray array];
  for (id link in links) {
    id src = [link valueForKey:@"note"];
    if (!src || [[src valueForKey:@"markedForDeletion"] boolValue] || isTrash([src valueForKey:@"folder"])) continue;
    NSString *token = [link valueForKey:@"tokenContentIdentifier"];
    NSMutableDictionary *entry = [@{@"from": noteSummary(src), @"text": [link valueForKey:@"displayText"] ?: @"", @"target": token ?: @""} mutableCopy];
    NSURLComponents *uc = [NSURLComponents componentsWithString:token];
    for (NSURLQueryItem *q in uc.queryItems) if ([q.name isEqualToString:@"paragraphID"]) {
      entry[@"paragraph_id"] = q.value;
      for (NSDictionary *p in paragraphsJSON(bodyText(note)))
        if ([p[@"paragraph_id"] isEqualToString:q.value.uppercaseString]) entry[@"paragraph"] = @{@"index": p[@"index"], @"text": p[@"text"]};
    }
    // Where the link sits in the source note.
    NSArray *paras = paragraphsJSON(bodyText(src));
    for (NSDictionary *p in paras) for (NSDictionary *att in p[@"attachments"])
      if ([att[@"id"] isEqualToString:[link valueForKey:@"identifier"]]) entry[@"from_paragraph"] = @{@"index": p[@"index"], @"text": p[@"text"]};
    [out addObject:entry];
  }
  emit(@{@"note": noteSummary(note), @"backlinks": out, @"count": @(out.count)});
}

static void cmdFolders(Args a) {
  NSMutableArray *out = [NSMutableArray array];
  for (id account in allAccounts()) {
    if (a.opt[@"account"] && [[account valueForKey:@"name"] caseInsensitiveCompare:a.opt[@"account"]] != NSOrderedSame) continue;
    for (id f in MSG0(id)(account, @selector(visibleFolders))) {
      [out addObject:@{@"id": [f valueForKey:@"identifier"] ?: @"", @"title": [f valueForKey:@"title"] ?: @"",
                       @"path": folderPath(f), @"account": [account valueForKey:@"name"],
                       @"parent": [f valueForKeyPath:@"parent.identifier"] ?: NSNull.null,
                       @"notes": @(MSG0(NSUInteger)(f, @selector(visibleNotesCount)))}];
    }
  }
  [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"account" ascending:YES], [NSSortDescriptor sortDescriptorWithKey:@"path" ascending:YES]]];
  emit(@{@"folders": out, @"count": @(out.count)});
}

static void cmdTags(Args a) {
  NSArray *atts = fetch(@"ICInlineAttachment", [NSPredicate predicateWithFormat:@"typeUTI == %@ AND markedForDeletion == NO", kUTIHashtag]);
  NSMutableDictionary *byTag = [NSMutableDictionary dictionary];
  for (id att in atts) {
    id note = [att valueForKey:@"note"];
    if (!note || [[note valueForKey:@"markedForDeletion"] boolValue] || isTrash([note valueForKey:@"folder"])) continue;
    NSString *account = [note valueForKeyPath:@"account.name"];
    if (a.opt[@"account"] && [account caseInsensitiveCompare:a.opt[@"account"]] != NSOrderedSame) continue;
    NSString *key = [NSString stringWithFormat:@"%@|%@", account, [att valueForKey:@"tokenContentIdentifier"]];
    NSMutableDictionary *e = byTag[key] ?: (byTag[key] = [@{@"tag": [att valueForKey:@"displayText"] ?: @"", @"account": account, @"notes": [NSMutableSet set]} mutableCopy]);
    [e[@"notes"] addObject:[note valueForKey:@"identifier"]];
  }
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *e in byTag.allValues) [out addObject:@{@"tag": e[@"tag"], @"account": e[@"account"], @"notes": @([e[@"notes"] count])}];
  [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"notes" ascending:NO], [NSSortDescriptor sortDescriptorWithKey:@"tag" ascending:YES]]];
  emit(@{@"tags": out, @"count": @(out.count)});
}

#pragma mark - Write commands

static void cmdCheck(Args a) {
  id note = resolveNote(need(a, 0, @"note"));
  NSArray *paras = paragraphsJSON(bodyText(note));
  NSUInteger idx = findParagraph(paras, a.pos.count > 1 ? a.pos[1] : nil, a.opt[@"index"]);
  BOOL done = !a.opt[@"undo"];
  NSDictionary *p = paras[idx];
  if (!p[@"todo"]) fail(@"not_a_todo", [NSString stringWithFormat:@"Paragraph %lu is not a checklist item.", (unsigned long)idx]);
  NSDictionary *plan = @{@"action": done ? @"check" : @"uncheck", @"paragraph": p, @"note": noteSummary(note)};
  guardWritable(note);
  if ([p[@"todo"][@"done"] boolValue] == done) { emit(@{@"changed": @NO, @"reason": @"already in that state", @"plan": plan}); return; }
  writeNote(a, note, plan, @"nnote check", ^{
    NSAttributedString *as = bodyText(note);
    Para pr = paraAt(paragraphRanges(as), idx);
    id style = styleAt(as, pr.range);
    id updated = MSG(id, id, BOOL)([NSClassFromString(@"ICTTTodo") alloc], @selector(initWithIdentifier:done:),
                                   MSG0(id)(MSG0(id)(style, @selector(todo)), @selector(uuid)), done);
    id newS = [style mutableCopy];
    MSG(void, id)(newS, @selector(setTodo:), updated);
    [as enumerateAttributesInRange:pr.enclosing options:0 usingBlock:^(NSDictionary *at, NSRange r, BOOL *stop) {
      NSMutableDictionary *m = [at mutableCopy];
      m[kStyleKey] = newS;
      MSG(void, id, NSRange)(mergeable(note), @selector(setAttributes:range:), m, r);
    }];
  });
}

static void cmdSetStyle(Args a) {
  id note = resolveNote(need(a, 0, @"note"));
  NSString *styleArg = a.opt[@"style"] ?: (a.pos.count > 2 ? a.pos[2] : nil);
  NSNumber *style = styleNames()[styleArg.lowercaseString];
  if (!style) fail(@"bad_style", [NSString stringWithFormat:@"Style must be one of: %@.", [styleNames().allKeys componentsJoinedByString:@", "]]);
  NSArray *paras = paragraphsJSON(bodyText(note));
  NSUInteger idx = findParagraph(paras, a.pos.count > 1 ? a.pos[1] : nil, a.opt[@"index"]);
  NSDictionary *plan = @{@"action": @"set-style", @"style": styleArg.lowercaseString, @"paragraph": paras[idx], @"note": noteSummary(note)};
  writeNote(a, note, plan, @"nnote set-style", ^{
    NSAttributedString *as = bodyText(note);
    Para pr = paraAt(paragraphRanges(as), idx);
    id old = styleAt(as, pr.range);
    // Keep the paragraph's identity (its UUID), so paragraph links keep working.
    id s = old ? [old mutableCopy] : newStyle(style.longValue, 0, 0, NO);
    MSG(void, long)(s, @selector(setStyle:), style.longValue);
    if (style.longValue == kStyleChecklist) { if (!MSG0(id)(s, @selector(todo))) MSG(void, id)(s, @selector(setTodo:), newTodo(NO)); }
    else MSG(void, id)(s, @selector(setTodo:), nil);
    if (style.longValue < kStyleBullet) MSG(void, NSUInteger)(s, @selector(setIndent:), 0);
    if (a.opt[@"indent"]) MSG(void, NSUInteger)(s, @selector(setIndent:), (NSUInteger)a.opt[@"indent"].integerValue);
    [as enumerateAttributesInRange:pr.enclosing options:0 usingBlock:^(NSDictionary *at, NSRange r, BOOL *stop) {
      NSMutableDictionary *m = [at mutableCopy];
      m[kStyleKey] = s;
      MSG(void, id, NSRange)(mergeable(note), @selector(setAttributes:range:), m, r);
    }];
  });
}

static void cmdFormat(Args a) {
  id note = resolveNote(need(a, 0, @"note"));
  NSArray *paras = paragraphsJSON(bodyText(note));
  NSUInteger idx = findParagraph(paras, a.pos.count > 1 ? a.pos[1] : nil, a.opt[@"index"]);
  NSMutableDictionary *changes = [NSMutableDictionary dictionary];
  for (NSString *k in @[@"bold", @"italic", @"underline", @"strike", @"plain"]) if (a.opt[k]) changes[k] = @YES;
  if (a.opt[@"highlight"]) {
    NSInteger h = highlightValue(a.opt[@"highlight"]);
    if (h < 0) fail(@"bad_highlight", @"--highlight takes purple, pink, orange, mint or blue (or 1-5), or none to remove it.");
    changes[@"highlight"] = @(h);
  }
  if (a.opt[@"link"]) {
    if (!a.opt[@"link"].length || ![NSURL URLWithString:a.opt[@"link"]].scheme) fail(@"bad_url", @"--link needs a full URL.");
    changes[@"link"] = a.opt[@"link"];
  }
  if (!changes.count) fail(@"usage", @"Pass at least one of --bold --italic --underline --strike --highlight N --link URL --plain.");
  // The text to format: the whole paragraph, or the first occurrence of --text in it.
  NSAttributedString *as0 = bodyText(note);
  Para pr0 = paraAt(paragraphRanges(as0), idx);
  NSRange target = pr0.range;
  if (a.opt[@"text"]) {
    NSRange hit = [as0.string rangeOfString:a.opt[@"text"] options:0 range:pr0.range];
    if (hit.location == NSNotFound) fail(@"text_not_found", [NSString stringWithFormat:@"\"%@\" is not in paragraph %lu.", a.opt[@"text"], (unsigned long)idx]);
    target = hit;
  }
  if (!target.length) fail(@"bad_text", @"The paragraph is empty.");
  NSDictionary *plan = @{@"action": @"format", @"changes": changes, @"text": [as0.string substringWithRange:target],
                         @"paragraph": paras[idx], @"note": noteSummary(note)};
  writeNote(a, note, plan, @"nnote format", ^{
    NSAttributedString *as = bodyText(note);
    [as enumerateAttributesInRange:target options:0 usingBlock:^(NSDictionary *at, NSRange r, BOOL *stop) {
      if (at[kAttachmentKey]) return;
      NSMutableDictionary *m = [at mutableCopy];
      if (changes[@"plain"]) [m removeObjectsForKeys:@[kHintsKey, kUnderlineKey, kStrikeKey, kEmphasisKey, kLinkKey]];
      NSInteger hints = [m[kHintsKey] integerValue] | (changes[@"bold"] ? 1 : 0) | (changes[@"italic"] ? 2 : 0);
      if (hints) m[kHintsKey] = @(hints);
      if (changes[@"underline"]) m[kUnderlineKey] = @1;
      if (changes[@"strike"]) m[kStrikeKey] = @1;
      if (changes[@"highlight"]) { if ([changes[@"highlight"] integerValue]) m[kEmphasisKey] = changes[@"highlight"]; else [m removeObjectForKey:kEmphasisKey]; }
      if (changes[@"link"]) m[kLinkKey] = [NSURL URLWithString:changes[@"link"]];
      MSG(void, id, NSRange)(mergeable(note), @selector(setAttributes:range:), m, r);
    }];
  });
}

static void cmdAddTodo(Args a) {
  id note = resolveNote(need(a, 0, @"note"));
  NSString *text = need(a, 1, @"todo text");
  if ([text containsString:@"\n"]) fail(@"bad_text", @"Todo text must be one line.");
  NSArray *paras = paragraphsJSON(bodyText(note));
  NSInteger after = afterParagraph(a, note);
  if (after < 0) for (NSDictionary *p in paras) if (p[@"todo"]) after = [p[@"index"] integerValue];  // after the last to-do
  NSDictionary *plan = @{@"action": @"add-todo", @"text": text, @"after_paragraph": after >= 0 ? paras[after] : @"end of note", @"note": noteSummary(note)};
  writeNote(a, note, plan, @"nnote add-todo", ^{
    NSAttributedString *as = bodyText(note);
    id base = after >= 0 ? styleAt(as, paraAt(paragraphRanges(as), after).range) : nil;
    NSUInteger indent = base && MSG0(long)(base, @selector(style)) == kStyleChecklist ? MSG0(NSUInteger)(base, @selector(indent)) : 0;
    insertParagraphs(note, after, paragraph(parseInline(text, note, [note valueForKey:@"account"], [NSMutableArray array]),
                                            newStyle(kStyleChecklist, indent, 0, NO), NO));
  });
}

static void cmdAddTag(Args a) {
  id note = resolveNote(need(a, 0, @"note"));
  NSString *tag = [need(a, 1, @"tag") stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"# "]];
  if (!tag.length || [tag rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound)
    fail(@"bad_tag", @"A tag is one word without spaces.");
  NSInteger after = afterParagraph(a, note);
  writeNote(a, note, @{@"action": @"add-tag", @"tag": [@"#" stringByAppendingString:tag], @"note": noteSummary(note)}, @"nnote add-tag", ^{
    insertParagraphs(note, after, paragraph(makeTag(note, tag), newStyle(kStyleBody, 0, 0, NO), NO));
  });
}

static void cmdLink(Args a) {
  id note = resolveNote(need(a, 0, @"note"));
  id target = resolveNote(need(a, 1, @"target note"));
  if (note == target && !a.opt[@"paragraph"] && !a.opt[@"paragraph-index"]) fail(@"bad_target", @"A note cannot link to itself (link to one of its paragraphs instead).");
  NSDictionary *targetPara = nil;
  if (a.opt[@"paragraph"] || a.opt[@"paragraph-index"]) {
    NSArray *tp = paragraphsJSON(bodyText(target));
    targetPara = tp[findParagraph(tp, a.opt[@"paragraph"], a.opt[@"paragraph-index"])];
    if (!targetPara[@"paragraph_id"]) fail(@"bad_target", @"That paragraph has no identity to link to.");
  }
  NSInteger after = afterParagraph(a, note);
  NSDictionary *plan = @{@"action": targetPara ? @"link-paragraph" : @"link", @"note": noteSummary(note), @"target": noteSummary(target),
                         @"target_paragraph": targetPara ?: NSNull.null};
  writeNote(a, note, plan, @"nnote link", ^{
    NSAttributedString *link = makeNoteLink(note, target, targetPara ? [[NSUUID alloc] initWithUUIDString:targetPara[@"paragraph_id"]] : nil, targetPara[@"text"]);
    insertParagraphs(note, after, paragraph(link, newStyle(kStyleBody, 0, 0, NO), NO));
  });
}

static NSArray *readTSV(NSString *src) {
  NSString *tsv = [readInput(src) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
  if (!tsv.length) fail(@"bad_table", @"The table is empty.");
  NSMutableArray *rows = [NSMutableArray array];
  for (NSString *line in [tsv componentsSeparatedByString:@"\n"]) [rows addObject:[line componentsSeparatedByString:@"\t"]];
  return rows;
}

static void cmdAddTable(Args a) {
  id note = resolveNote(need(a, 0, @"note"));
  if (!a.opt[@"tsv"]) fail(@"usage", @"Pass --tsv <file>, or --tsv - to read stdin. Rows are lines, cells are tab-separated.");
  NSArray *rows = readTSV(a.opt[@"tsv"]);
  NSInteger after = afterParagraph(a, note);
  writeNote(a, note, @{@"action": @"add-table", @"rows": rows, @"note": noteSummary(note)}, @"nnote add-table", ^{
    insertParagraphs(note, after, paragraph(makeTable(note, rows), newStyle(kStyleBody, 0, 0, NO), NO));
  });
}

static void cmdAttach(Args a) {
  id note = resolveNote(need(a, 0, @"note"));
  NSString *path = need(a, 1, @"file");
  if (![NSFileManager.defaultManager isReadableFileAtPath:path.stringByExpandingTildeInPath]) fail(@"file_not_found", [NSString stringWithFormat:@"Cannot read %@.", path]);
  NSInteger after = afterParagraph(a, note);
  writeNote(a, note, @{@"action": @"attach", @"file": path, @"note": noteSummary(note)}, @"nnote attach", ^{
    insertParagraphs(note, after, paragraph(makeFile(note, path), newStyle(kStyleBody, 0, 0, NO), NO));
  });
}

static void cmdAddURL(Args a) {
  id note = resolveNote(need(a, 0, @"note"));
  NSString *url = need(a, 1, @"URL");
  if (![NSURL URLWithString:url].scheme.length) fail(@"bad_url", [NSString stringWithFormat:@"Not a URL: %@", url]);
  NSInteger after = afterParagraph(a, note);
  writeNote(a, note, @{@"action": @"add-url", @"url": url, @"note": noteSummary(note)}, @"nnote add-url", ^{
    insertParagraphs(note, after, paragraph(makeURLCard(note, url), newStyle(kStyleBody, 0, 0, NO), NO));
  });
}

static void cmdDraw(Args a) {
  id note = resolveNote(need(a, 0, @"note"));
  NSString *svg = a.opt[@"svg"];
  if (!svg) fail(@"usage", @"Pass --svg <file>.");
  NSDictionary *opts = @{@"width": a.opt[@"width"] ?: @"400", @"ink": a.opt[@"ink"] ?: @"pen", @"color": a.opt[@"color"] ?: @""};
  NSDictionary *stats = nil;
  NSError *err = nil;
  if (!NNDrawingFromSVG(svg.stringByExpandingTildeInPath, [opts[@"width"] doubleValue], opts[@"color"], opts[@"ink"], &stats, &err))
    fail(@"bad_svg", err.localizedDescription);
  NSInteger after = afterParagraph(a, note);
  NSDictionary *plan = @{@"action": @"draw", @"svg": svg, @"drawing": stats, @"options": opts, @"note": noteSummary(note)};
  writeNote(a, note, plan, @"nnote draw", ^{
    NSAttributedString *obj = makeDrawing(note, svg, opts, NULL);
    NSString *ident = MSG0(id)([obj attribute:kAttachmentKey atIndex:0 effectiveRange:NULL], @selector(attachmentIdentifier));
    // The paper helper may place the attachment in the text itself.
    if (!textHasAttachment(note, ident)) insertParagraphs(note, after, paragraph(obj, newStyle(kStyleBody, 0, 0, NO), NO));
  });
}

static void cmdPin(Args a) {
  id note = resolveNote(need(a, 0, @"note"));
  BOOL pin = !a.opt[@"undo"];
  guardWritable(note);
  NSDictionary *plan = @{@"action": pin ? @"pin" : @"unpin", @"note": noteSummary(note)};
  if (isPinned(note) == pin) { emit(@{@"changed": @NO, @"reason": @"already in that state", @"plan": plan}); return; }
  if (!a.apply) { emit(@{@"dry_run": @YES, @"plan": plan}); return; }
  requireSelectors(note, @[@"setIsPinned:"]);
  MSG(void, BOOL)(note, @selector(setIsPinned:), pin);
  MSG(void, id)(note, @selector(updateChangeCountWithReason:), pin ? @"nnote pin" : @"nnote unpin");
  saveAndNotify();
  emit(@{@"changed": @YES, @"plan": plan, @"note": noteSummary(note)});
}

static void cmdCreateFolder(Args a) {
  NSString *title = need(a, 0, @"folder name");
  if ([title containsString:@"/"]) fail(@"bad_name", @"Folder names cannot contain \"/\"; use --parent for subfolders.");
  id parent = a.opt[@"parent"] ? resolveFolder(a.opt[@"parent"], a.opt[@"account"]) : nil;
  id account = parent ? [parent valueForKey:@"account"] : accountNamed(a.opt[@"account"] ?: @"On My Mac");
  guardAccount(account);
  if (parent && isTrash(parent)) fail(@"bad_parent", @"Cannot create a folder in Recently Deleted.");
  for (id f in MSG0(id)(account, @selector(visibleFolders)))
    if ([f valueForKey:@"parent"] == parent && [[f valueForKey:@"title"] caseInsensitiveCompare:title] == NSOrderedSame)
      fail(@"folder_exists", [NSString stringWithFormat:@"\"%@\" already exists there (id %@).", title, [f valueForKey:@"identifier"]]);
  NSDictionary *plan = @{@"action": @"create-folder", @"title": title, @"account": [account valueForKey:@"name"],
                         @"parent": parent ? folderPath(parent) : NSNull.null};
  if (!a.apply) { emit(@{@"dry_run": @YES, @"plan": plan}); return; }
  Class Folder = NSClassFromString(@"ICFolder");
  id folder = parent ? MSG(id, id)(Folder, @selector(newFolderInParentFolder:), parent) : MSG(id, id)(Folder, @selector(newFolderInAccount:), account);
  if (!folder) fail(@"folder_failed", @"Notes did not create the folder.");
  MSG(void, id)(folder, @selector(setTitle:), title);
  if ([folder respondsToSelector:@selector(updateChangeCountWithReason:)]) MSG(void, id)(folder, @selector(updateChangeCountWithReason:), @"nnote create-folder");
  saveAndNotify();
  emit(@{@"changed": @YES, @"plan": plan, @"folder": @{@"id": [folder valueForKey:@"identifier"], @"path": folderPath(folder)}});
}

static void cmdCreate(Args a) {
  id folder = resolveFolder(a.opt[@"folder"] ?: @"Notes", a.opt[@"account"]);
  id account = [folder valueForKey:@"account"];
  guardAccount(account);
  if (isTrash(folder)) fail(@"bad_folder", @"Cannot create a note in Recently Deleted.");
  NSString *md = readInput(a.opt[@"markdown"]) ?: @"";
  NSString *title = a.opt[@"title"] ?: (a.pos.count ? a.pos[0] : nil);
  if (title) md = [NSString stringWithFormat:@"# %@\n%@", title, md];
  NSArray *blocks = parseMarkdown(md);
  if (!blocks.count) fail(@"usage", @"Give the note a title or --markdown content.");
  NSDictionary *plan = @{@"action": @"create", @"folder": folderPath(folder), @"account": [account valueForKey:@"name"], @"blocks": planBlocks(blocks, account)};
  if (!a.apply) { emit(@{@"dry_run": @YES, @"plan": plan}); return; }
  id note = MSG(id, id)(NSClassFromString(@"ICNote"), @selector(newEmptyNoteInFolder:), folder);
  if (!note) fail(@"create_failed", @"Notes did not create the note.");
  commit(note, @"nnote create", ^(id ms) { insertParagraphs(note, -1, renderBlocks(blocks, note, account)); });
  emit(@{@"changed": @YES, @"plan": plan, @"note": noteJSON(note)});
}

static void cmdAppend(Args a) {
  id note = resolveNote(need(a, 0, @"note"));
  NSString *md = readInput(a.opt[@"markdown"]);
  if (!md) fail(@"usage", @"Pass --markdown <file>, or --markdown - to read stdin.");
  NSArray *blocks = parseMarkdown(md);
  if (!blocks.count) fail(@"usage", @"The Markdown is empty.");
  id account = [note valueForKey:@"account"];
  NSInteger after = afterParagraph(a, note);
  NSDictionary *plan = @{@"action": @"append", @"blocks": planBlocks(blocks, account), @"note": noteSummary(note)};
  writeNote(a, note, plan, @"nnote append", ^{ insertParagraphs(note, after, renderBlocks(blocks, note, account)); });
}

static const char *kHelp =
  "nnote: read and edit Apple Notes natively.\n"
  "Every command prints JSON. Write commands are dry runs unless --apply is given.\n"
  "Writes only touch notes in NNOTE_WRITABLE_ACCOUNTS (comma-separated, default \"On My Mac\").\n"
  "<note> is a note id (UUID), an x-coredata:// URI, or a numeric primary key. <item> is a paragraph's text.\n"
  "Placement: --after <item> or --index N puts new content after that paragraph; otherwise at the end.\n\n"
  "Read\n"
  "  find [text] [--folder PATH|ID] [--account A] [--tag T] [--pinned 1] [--limit N]\n"
  "  read <note> [--format json|markdown]\n"
  "  backlinks <note>                       notes that link to this note or its paragraphs\n"
  "  folders [--account A]                  folders and subfolders with paths and note counts\n"
  "  tags [--account A]                     tags with the number of notes using each\n\n"
  "Write\n"
  "  create [title] [--folder PATH|ID] [--account A] [--markdown FILE|-]   new note from Markdown\n"
  "  append <note> --markdown FILE|-        add Markdown content\n"
  "  create-folder <name> [--parent PATH|ID] [--account A]\n"
  "  pin <note> [--undo]\n"
  "  set-style <note> <item> <title|heading|subheading|body|monospaced|bullet|dash|numbered|checklist> [--index N] [--indent N]\n"
  "  format <note> <item> [--index N] [--text SUBSTRING] [--bold] [--italic] [--underline] [--strike]\n"
  "         [--highlight purple|pink|orange|mint|blue|none] [--link URL] [--plain]\n"
  "  check <note> <item> [--index N] [--undo]\n"
  "  add-todo <note> <text>\n"
  "  add-tag <note> <tag>\n"
  "  link <note> <target note> [--paragraph <target item> | --paragraph-index N]\n"
  "  add-table <note> --tsv FILE|-\n"
  "  add-url <note> <url>                   a link card\n"
  "  attach <note> <file>                   an image, PDF or other file\n"
  "  draw <note> --svg FILE [--width PT] [--ink pen|pencil|marker] [--color #rrggbb]   a native, editable drawing\n\n"
  "Markdown: # ## ### headings, paragraphs, - lists, 1. lists, - [ ] / - [x] to-dos, > quotes, ``` code,\n"
  "**bold** *italic* ~~strike~~ ==highlight== =={pink}highlight== [text](url), #tags, [[Note title]] and [[Note title#Paragraph]] links,\n"
  "| tables |, --- dividers, ![](file) attachments, ![](drawing.svg) drawings, and a URL alone on a line as a link card.\n\n"
  "Needs Full Disk Access for the process that runs it. Built against macOS 27.2.\n";

int main(int argc, char **argv) {
  @autoreleasepool {
    Args a = parse(argc, argv);
    if (!a.cmd || [a.cmd isEqualToString:@"help"] || [a.cmd isEqualToString:@"--help"]) { fputs(kHelp, stdout); return 0; }
    if ([a.cmd isEqualToString:@"version"]) { emit(@{@"version": kVersion}); return 0; }
    NSDictionary<NSString *, NSValue *> *reads = @{@"find": [NSValue valueWithPointer:cmdFind], @"backlinks": [NSValue valueWithPointer:cmdBacklinks],
                                                   @"folders": [NSValue valueWithPointer:cmdFolders], @"tags": [NSValue valueWithPointer:cmdTags]};
    NSDictionary<NSString *, NSValue *> *writes = @{
      @"check": [NSValue valueWithPointer:cmdCheck], @"set-style": [NSValue valueWithPointer:cmdSetStyle],
      @"format": [NSValue valueWithPointer:cmdFormat], @"add-todo": [NSValue valueWithPointer:cmdAddTodo],
      @"add-tag": [NSValue valueWithPointer:cmdAddTag], @"link": [NSValue valueWithPointer:cmdLink],
      @"add-table": [NSValue valueWithPointer:cmdAddTable], @"attach": [NSValue valueWithPointer:cmdAttach],
      @"add-url": [NSValue valueWithPointer:cmdAddURL], @"draw": [NSValue valueWithPointer:cmdDraw],
      @"pin": [NSValue valueWithPointer:cmdPin], @"create-folder": [NSValue valueWithPointer:cmdCreateFolder],
      @"create": [NSValue valueWithPointer:cmdCreate], @"append": [NSValue valueWithPointer:cmdAppend]};
    BOOL isRead = reads[a.cmd] || [a.cmd isEqualToString:@"read"];
    if (!isRead && !writes[a.cmd]) fail(@"usage", [NSString stringWithFormat:@"Unknown command \"%@\". Run `nnote help`.", a.cmd]);
    // Reads and dry runs open the store read-only.
    openContext(!isRead && a.apply);
    [gMOC performBlockAndWait:^{
      if ([a.cmd isEqualToString:@"read"]) {
        id note = resolveNote(need(a, 0, @"note"));
        if ([a.opt[@"format"] isEqualToString:@"markdown"]) { NSString *md = noteMarkdown(note); fwrite(md.UTF8String, 1, strlen(md.UTF8String), stdout); }
        else emit(noteJSON(note));
        return;
      }
      void (*fn)(Args) = (reads[a.cmd] ?: writes[a.cmd]).pointerValue;
      fn(a);
    }];
    return 0;
  }
}
