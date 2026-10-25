#import "NNStore.h"

#pragma mark - Context

// -[ICNoteContext initWithOptions:]: 0x40 opens every store read-only.
static const NSUInteger kContextReadOnly = 0x40;

static id gCtx;
NSManagedObjectContext *gMOC;

void openContext(BOOL writable) {
  if (!dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_NOW))
    fail(@"framework_unavailable", @(dlerror()));
  Class Ctx = NSClassFromString(@"ICNoteContext");
  for (NSString *sel in @[@"startSharedContextWithOptions:", @"sharedContext"])
    if (![Ctx respondsToSelector:NSSelectorFromString(sel)])
      fail(@"unsupported_macos", [NSString stringWithFormat:@"ICNoteContext lacks %@", sel]);
  // A separate store under the Notes group container (Notes' own UI-test mechanism):
  // …/group.com.apple.notes/Containers/<name>/NoteStore.sqlite.
  NSString *container = NSProcessInfo.processInfo.environment[@"NNOTE_CONTAINER"];
  if (container.length) MSG(void, id)(Ctx, @selector(useContainerNamed:), container);
  MSG(void, NSUInteger)(Ctx, @selector(startSharedContextWithOptions:), writable ? 0 : kContextReadOnly);
  gCtx = MSG0(id)(Ctx, @selector(sharedContext));
  gMOC = MSG0(id)(gCtx, @selector(managedObjectContext));
  if (!gMOC) fail(@"no_access", @"Could not open the Notes database. Does this process have Full Disk Access?");
  // A fresh container has no accounts; create its On My Mac account in that store.
  Class Account = NSClassFromString(@"ICAccount");
  if (container.length && writable && !MSG(id, id)(Account, @selector(localAccountInContext:), gMOC)) {
    [gMOC performBlockAndWait:^{
      if (!MSG(id, id)(Account, @selector(newLocalAccountInContext:), gMOC)) fail(@"account_failed", @"Could not create the test container's account.");
      NSError *err = nil;
      if (![gMOC save:&err]) fail(@"save_failed", err.localizedDescription);
    }];
  }
  if (!writable)
    for (NSPersistentStore *s in gMOC.persistentStoreCoordinator.persistentStores)
      if (!s.isReadOnly) fail(@"store_not_read_only", @"Refusing to read through a writable store.");
}

NSArray *fetch(NSString *entity, NSPredicate *pred) {
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

NSArray *allAccounts(void) {
  return MSG(id, id)(NSClassFromString(@"ICAccount"), @selector(allActiveAccountsInContext:), gMOC) ?: @[];
}

id accountNamed(NSString *name) {
  for (id a in allAccounts()) if ([[a valueForKey:@"name"] caseInsensitiveCompare:name] == NSOrderedSame) return a;
  fail(@"account_not_found", [NSString stringWithFormat:@"No account named \"%@\".", name]);
}

NSString *folderPath(id folder) {
  NSMutableArray *parts = [NSMutableArray array];
  for (id f = folder; f; f = [f valueForKey:@"parent"]) [parts insertObject:[f valueForKey:@"title"] ?: @"" atIndex:0];
  return [parts componentsJoinedByString:@"/"];
}

BOOL isTrash(id folder) {
  return [folder respondsToSelector:@selector(isTrashFolder)] && MSG0(BOOL)(folder, @selector(isTrashFolder));
}

// A folder by id, or by path ("Parent/Child") inside `accountName`.
id resolveFolder(NSString *ref, NSString *accountName) {
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

id resolveNote(NSString *ref) {
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

NSArray *visibleNotes(NSPredicate *extra) {
  NSPredicate *visible = MSG(id, id)(NSClassFromString(@"ICNote"), @selector(predicateForVisibleNotesInContext:), gMOC);
  NSPredicate *p = extra ? [NSCompoundPredicate andPredicateWithSubpredicates:@[visible, extra]] : visible;
  return MSG(id, id, id)(NSClassFromString(@"ICNote"), @selector(notesMatchingPredicate:context:), p, gMOC);
}

// A note by exact title in one account (for [[Title]] links in Markdown).
id noteTitled(NSString *title, id account) {
  NSArray *hits = visibleNotes([NSPredicate predicateWithFormat:@"title ==[c] %@ AND account == %@", title, account]);
  if (!hits.count) fail(@"note_not_found", [NSString stringWithFormat:@"No note titled \"%@\" in %@.", title, [account valueForKey:@"name"]]);
  if (hits.count > 1) fail(@"ambiguous_note", [NSString stringWithFormat:@"%lu notes are titled \"%@\"; link by id instead.", (unsigned long)hits.count, title]);
  return hits[0];
}

BOOL isPinned(id note) { return [note respondsToSelector:@selector(isPinned)] && MSG0(BOOL)(note, @selector(isPinned)); }

NSDictionary *noteSummary(id note) {
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

#pragma mark - Writes: guards and saving

static NSSet *writableAccounts(void) {
  NSString *allowed = NSProcessInfo.processInfo.environment[@"NNOTE_WRITABLE_ACCOUNTS"] ?: @"On My Mac";
  NSMutableSet *set = [NSMutableSet set];
  for (NSString *a in [allowed componentsSeparatedByString:@","])
    [set addObject:[[a stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString]];
  return set;
}

void guardAccount(id account) {
  NSString *name = [account valueForKey:@"name"];
  if (![writableAccounts() containsObject:name.lowercaseString])
    fail(@"account_not_writable", [NSString stringWithFormat:@"Account \"%@\" is not writable. Writable accounts: %@ (set NNOTE_WRITABLE_ACCOUNTS).",
                                   name, NSProcessInfo.processInfo.environment[@"NNOTE_WRITABLE_ACCOUNTS"] ?: @"On My Mac"]);
}

void guardWritable(id note) {
  guardAccount([note valueForKey:@"account"]);
  if ([[note valueForKey:@"markedForDeletion"] boolValue] || isTrash([note valueForKey:@"folder"]))
    fail(@"note_deleted", @"Note is deleted or in Recently Deleted.");
  if ([note respondsToSelector:@selector(isPasswordProtected)] && MSG0(BOOL)(note, @selector(isPasswordProtected)))
    fail(@"note_locked", @"Note is locked with a password.");
}

void requireSelectors(id obj, NSArray *sels) {
  for (NSString *s in sels)
    if (![obj respondsToSelector:NSSelectorFromString(s)])
      fail(@"unsupported_macos", [NSString stringWithFormat:@"%@ lacks %@", NSStringFromClass([obj class]), s]);
}

void saveAndNotify(void) {
  MSG0(void)(gCtx, @selector(save));
  NSError *err = nil;
  if (gMOC.hasChanges && ![gMOC save:&err]) fail(@"save_failed", err.localizedDescription);
  // Tell a running Notes.app that another process saved, the way Notes' editor
  // extension does; otherwise it may overwrite this change with its open copy.
  id coordinator = MSG0(id)(gCtx, @selector(crossProcessChangeCoordinator));
  if (coordinator) MSG0(void)(coordinator, @selector(postEditorExtensionDidSaveNotification));
}

// Runs `edit` inside Notes' editing calls, then saves the way a user edit does.
void commit(id note, NSString *reason, void (^edit)(id ms)) {
  requireSelectors(note, @[@"beginEditing", @"endEditing", @"didChangeNoteText", @"saveNoteData", @"updateChangeCountWithReason:"]);
  id ms = MSG0(id)(note, @selector(mergeableString));
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
