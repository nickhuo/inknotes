// Read-only: show how attachments (tags, links, tables) are stored in one note.
// Usage: dump <note Z_PK>
// Prints each attribute run that holds an attachment, with its attribute keys
// and value classes, then the note's inline attachment objects.
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <dlfcn.h>
#import <objc/message.h>

#define MSG0(T) ((T (*)(id, SEL))objc_msgSend)

static NSString *describe(id v) {
  NSMutableString *s = [NSMutableString stringWithString:NSStringFromClass([v class])];
  for (NSString *k in @[@"attachmentIdentifier", @"attachmentUTI", @"identifier", @"typeUTI",
                        @"tokenContentIdentifier", @"altText", @"displayText", @"style"]) {
    if ([v respondsToSelector:NSSelectorFromString(k)]) {
      id x = [v valueForKey:k];
      if (x) [s appendFormat:@" %@=%@", k, x];
    }
  }
  return s;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: dump <note Z_PK>\n"); return 2; }
    dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_NOW);
    Class Ctx = NSClassFromString(@"ICNoteContext");
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(Ctx, @selector(startSharedContextWithOptions:), 0x40);
    id ctx = MSG0(id)(Ctx, @selector(sharedContext));
    NSManagedObjectContext *moc = MSG0(id)(ctx, @selector(managedObjectContext));
    for (NSPersistentStore *s in moc.persistentStoreCoordinator.persistentStores)
      if (!s.isReadOnly) { fprintf(stderr, "ABORT: writable store\n"); return 1; }

    [moc performBlockAndWait:^{
      NSPersistentStore *store = moc.persistentStoreCoordinator.persistentStores.firstObject;
      NSString *uri = [NSString stringWithFormat:@"x-coredata://%@/ICNote/p%s",
                       store.metadata[NSStoreUUIDKey], argv[1]];
      NSManagedObjectID *oid = [moc.persistentStoreCoordinator managedObjectIDForURIRepresentation:[NSURL URLWithString:uri]];
      id note = oid ? [moc existingObjectWithID:oid error:NULL] : nil;
      if (!note) { fprintf(stderr, "note not found\n"); return; }
      printf("note pk=%s account=%s\n", argv[1], [[note valueForKeyPath:@"account.name"] description].UTF8String);

      NSAttributedString *as = MSG0(id)(MSG0(id)(note, @selector(mergeableString)), @selector(attributedString));
      [as enumerateAttributesInRange:NSMakeRange(0, as.length) options:0
                          usingBlock:^(NSDictionary *attrs, NSRange r, BOOL *stop) {
        NSString *text = [as.string substringWithRange:r];
        if (![text containsString:@"￼"]) return;
        NSUInteger lo = r.location >= 8 ? r.location - 8 : 0;
        NSString *ctxText = [[as.string substringWithRange:NSMakeRange(lo, MIN(r.location + r.length + 8, as.length) - lo)]
                             stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"];
        printf("run {%lu,%lu} around: %s\n", (unsigned long)r.location, (unsigned long)r.length,
               [ctxText stringByReplacingOccurrencesOfString:@"￼" withString:@"◆"].UTF8String);
        for (NSString *k in attrs) printf("   %s: %s\n", k.UTF8String, describe(attrs[k]).UTF8String);
      }];
      printf("inline attachments:\n");
      for (id a in MSG0(id)(note, @selector(visibleInlineAttachments))) printf("   %s\n", describe(a).UTF8String);
      printf("attachments:\n");
      for (id a in [note valueForKey:@"attachments"]) printf("   %s\n", describe(a).UTF8String);
    }];
  }
}
