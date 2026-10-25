// nnote: read and edit Apple Notes natively through Notes' private NotesShared
// framework. This file is the command-line interface: arguments, commands, help.
#import "NNCore.h"
#import "NNStore.h"
#import "NNDocument.h"
#import "NNObjects.h"
#import "NNMarkdown.h"
#import "NNSVG.h"

static NSString *const kVersion = @"0.2.2";

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
