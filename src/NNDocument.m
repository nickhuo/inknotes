#import "NNDocument.h"
#import "NNStore.h"

id mergeable(id note) { return MSG0(id)(note, @selector(mergeableString)); }
NSAttributedString *bodyText(id note) { return MSG0(id)(mergeable(note), @selector(attributedString)); }

#pragma mark - Paragraphs

NSArray<NSValue *> *paragraphRanges(NSAttributedString *as) {
  NSMutableArray *out = [NSMutableArray array];
  [as.string enumerateSubstringsInRange:NSMakeRange(0, as.length)
                                options:NSStringEnumerationByParagraphs | NSStringEnumerationSubstringNotRequired
                             usingBlock:^(NSString *s, NSRange r, NSRange er, BOOL *stop) {
    Para p = {r, er};
    [out addObject:[NSValue valueWithBytes:&p objCType:@encode(Para)]];
  }];
  return out;
}

Para paraAt(NSArray<NSValue *> *ps, NSUInteger i) { Para p; [ps[i] getValue:&p]; return p; }

id styleAt(NSAttributedString *as, NSRange r) {
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

NSDictionary *attachmentInfo(id tt) {
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

NSArray *paragraphsJSON(NSAttributedString *as) {
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

NSDictionary *noteJSON(id note) {
  NSMutableDictionary *d = [noteSummary(note) mutableCopy];
  d[@"paragraphs"] = paragraphsJSON(bodyText(note));
  return d;
}

NSUInteger findParagraph(NSArray *parasJSON, NSString *text, NSString *indexArg) {
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

#pragma mark - Writes: building text

id newTodo(BOOL done) {
  return MSG(id, id, BOOL)([NSClassFromString(@"ICTTTodo") alloc], @selector(initWithIdentifier:done:), [NSUUID UUID], done);
}

id newStyle(long style, NSUInteger indent, NSInteger quote, BOOL done) {
  id s = [[NSClassFromString(@"ICTTMutableParagraphStyle") alloc] init];
  MSG(void, long)(s, @selector(setStyle:), style);
  MSG(void, id)(s, @selector(setUuid:), [NSUUID UUID]);
  if (indent) MSG(void, NSUInteger)(s, @selector(setIndent:), indent);
  if (quote && [s respondsToSelector:@selector(setBlockQuoteLevel:)]) MSG(void, NSInteger)(s, @selector(setBlockQuoteLevel:), quote);
  MSG(void, id)(s, @selector(setTodo:), style == kStyleChecklist ? newTodo(done) : nil);
  return s;
}

void insertParagraphs(id note, NSInteger afterIndex, NSAttributedString *content) {
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
NSAttributedString *paragraph(NSAttributedString *content, id style, BOOL newline) {
  NSMutableAttributedString *line = [content mutableCopy];
  if (newline) [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
  [line addAttribute:kStyleKey value:style range:NSMakeRange(0, line.length)];
  return line;
}
