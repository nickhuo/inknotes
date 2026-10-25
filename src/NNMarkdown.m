#import "NNMarkdown.h"
#import "NNDocument.h"
#import "NNObjects.h"
#import "NNStore.h"

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

NSString *noteMarkdown(id note) {
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

#pragma mark - Markdown import

// Blocks: {kind: para, style, indent, quote, done, text} | {kind: table, rows}
//       | {kind: file|url|drawing, value} | {kind: divider}
NSArray<NSDictionary *> *parseMarkdown(NSString *md) {
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
NSAttributedString *parseInline(NSString *s, id note, id account, NSMutableArray *refs) {
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
NSArray *planBlocks(NSArray *blocks, id account) {
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
NSAttributedString *renderBlocks(NSArray *blocks, id note, id account) {
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

NSString *readInput(NSString *src) {
  if (!src) return nil;
  NSData *data = [src isEqualToString:@"-"] ? [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile]
                                            : [NSData dataWithContentsOfFile:src.stringByExpandingTildeInPath];
  if (!data) fail(@"file_not_found", [NSString stringWithFormat:@"Cannot read %@.", src]);
  if (![src isEqualToString:@"-"]) {
    NSString *dir = [src.stringByExpandingTildeInPath.stringByStandardizingPath stringByDeletingLastPathComponent];
    if (!dir.isAbsolutePath) dir = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:dir];
    setRelativePathBase(dir);
  }
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}
