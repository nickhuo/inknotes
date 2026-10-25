// Smoke test: mark one checklist item done through NotesShared.
// Usage: toggle <note x-coredata URI> <item text> [--apply]
// Without --apply it only reports what it would change.
// Guards: the note must be in "On My Mac", in folder "NotesShared Smoke Test",
// and the item must be an unchecked checklist paragraph (style 103).
// Needs Full Disk Access for the process running it.
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <dlfcn.h>
#import <objc/message.h>

#define MSG0(T) ((T (*)(id, SEL))objc_msgSend)
#define MSG(T, ...) ((T (*)(id, SEL, __VA_ARGS__))objc_msgSend)

static NSString *const kAccount = @"On My Mac";
static NSString *const kFolder = @"NotesShared Smoke Test";
static const long kStyleChecklist = 103;

// Finds the paragraph whose text equals `item`; returns its range including the newline.
static NSRange paragraphRange(NSAttributedString *as, NSString *item) {
  __block NSRange found = NSMakeRange(NSNotFound, 0);
  [as.string enumerateSubstringsInRange:NSMakeRange(0, as.length)
                                options:NSStringEnumerationByParagraphs
                             usingBlock:^(NSString *text, NSRange r, NSRange er, BOOL *stop) {
    if ([text isEqualToString:item]) { found = er; *stop = YES; }
  }];
  return found;
}

static void dumpChecklist(NSAttributedString *as) {
  [as.string enumerateSubstringsInRange:NSMakeRange(0, as.length)
                                options:NSStringEnumerationByParagraphs
                             usingBlock:^(NSString *text, NSRange r, NSRange er, BOOL *stop) {
    if (!r.length) return;
    id ps = [as attribute:@"TTStyle" atIndex:r.location effectiveRange:NULL];
    id todo = ps ? MSG0(id)(ps, @selector(todo)) : nil;
    if (todo) printf("  %s %s\n", MSG0(BOOL)(todo, @selector(done)) ? "[x]" : "[ ]", text.UTF8String);
  }];
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: toggle <note URI> <item text> [--apply]\n"); return 2; }
    BOOL apply = argc > 3 && strcmp(argv[3], "--apply") == 0;
    NSString *item = @(argv[2]);
    if (!dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_NOW)) {
      fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1;
    }
    Class Ctx = NSClassFromString(@"ICNoteContext");
    // Read-only (0x40) for a dry run; the normal writable context otherwise.
    MSG(void, NSUInteger)(Ctx, @selector(startSharedContextWithOptions:), apply ? 0 : 0x40);
    id ctx = MSG0(id)(Ctx, @selector(sharedContext));
    NSManagedObjectContext *moc = MSG0(id)(ctx, @selector(managedObjectContext));

    __block int rc = 0;
    [moc performBlockAndWait:^{
      NSManagedObjectID *oid = [moc.persistentStoreCoordinator
          managedObjectIDForURIRepresentation:[NSURL URLWithString:@(argv[1])]];
      NSError *err = nil;
      id note = oid ? [moc existingObjectWithID:oid error:&err] : nil;
      if (!note) { fprintf(stderr, "ABORT: note not found\n"); rc = 1; return; }

      NSString *account = [note valueForKeyPath:@"account.name"];
      NSString *folder = [note valueForKeyPath:@"folder.title"];
      printf("note: %s | account: %s | folder: %s\n",
             [[note valueForKey:@"title"] UTF8String], account.UTF8String, folder.UTF8String);
      if (![account isEqualToString:kAccount] || ![folder isEqualToString:kFolder]) {
        fprintf(stderr, "ABORT: note is outside %s / %s\n", kAccount.UTF8String, kFolder.UTF8String);
        rc = 1; return;
      }

      id ms = MSG0(id)(note, @selector(mergeableString));
      NSAttributedString *as = MSG0(id)(ms, @selector(attributedString));
      printf("before:\n"); dumpChecklist(as);

      NSRange pr = paragraphRange(as, item);
      if (pr.location == NSNotFound) { fprintf(stderr, "ABORT: no paragraph \"%s\"\n", item.UTF8String); rc = 1; return; }
      NSDictionary *attrs = [as attributesAtIndex:pr.location effectiveRange:NULL];
      id ps = attrs[@"TTStyle"];
      id todo = ps ? MSG0(id)(ps, @selector(todo)) : nil;
      if (!ps || MSG0(long)(ps, @selector(style)) != kStyleChecklist || !todo || MSG0(BOOL)(todo, @selector(done))) {
        fprintf(stderr, "ABORT: \"%s\" is not an unchecked checklist item\n", item.UTF8String); rc = 1; return;
      }

      // Same to-do identity, now done.
      id uuid = MSG0(id)(todo, @selector(uuid));
      id doneTodo = MSG(id, id, BOOL)([NSClassFromString(@"ICTTTodo") alloc],
                                      @selector(initWithIdentifier:done:), uuid, YES);
      id newStyle = [ps mutableCopy];
      MSG(void, id)(newStyle, @selector(setTodo:), doneTodo);
      NSMutableDictionary *newAttrs = [attrs mutableCopy];
      newAttrs[@"TTStyle"] = newStyle;
      printf("change: \"%s\" range {%lu,%lu} todo %s -> done\n",
             item.UTF8String, (unsigned long)pr.location, (unsigned long)pr.length, [uuid description].UTF8String);

      id coordinator = MSG0(id)(ctx, @selector(crossProcessChangeCoordinator));
      printf("cross-process coordinator: %s\n", coordinator ? "present" : "missing");
      if (!apply) { printf("dry run: nothing written (pass --apply)\n"); return; }

      MSG0(void)(note, @selector(beginEditing));
      MSG(void, id, NSRange)(ms, @selector(setAttributes:range:), newAttrs, pr);
      MSG0(void)(note, @selector(endEditing));
      MSG0(void)(note, @selector(didChangeNoteText));
      MSG0(void)(note, @selector(saveNoteData));
      // What a user edit does: bump the modification date and the change count.
      [note setValue:[NSDate date] forKey:@"modificationDate"];
      MSG(void, id)(note, @selector(updateChangeCountWithReason:), @"NotesShared smoke test toggle");
      MSG0(void)(ctx, @selector(save));
      if (moc.hasChanges && ![moc save:&err]) {
        fprintf(stderr, "save failed: %s\n", err.description.UTF8String); rc = 1; return;
      }
      // Tell running Notes processes that another process saved, the way
      // Notes' editor extension does (ICEditorExtensionDidSaveNotification).
      if (coordinator) {
        MSG0(void)(coordinator, @selector(postEditorExtensionDidSaveNotification));
        printf("posted ICEditorExtensionDidSaveNotification\n");
      }
      printf("modificationDate: %s\n", [[note valueForKey:@"modificationDate"] description].UTF8String);
      printf("after (in process):\n");
      dumpChecklist(MSG0(id)(MSG0(id)(note, @selector(mergeableString)), @selector(attributedString)));
    }];
    return rc;
  }
}
