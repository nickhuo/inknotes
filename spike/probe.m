// Read-only probe: open Notes' store through NotesShared with the read-only
// option and print one note's paragraphs with their paragraph styles.
// Usage: probe <x-coredata://…/ICNote/pN>
// Needs Full Disk Access for the process running it. Writes nothing.
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <dlfcn.h>
#import <objc/message.h>

// -[ICNoteContext initWithOptions:] passes (options & 0x40) to
// setIsReadOnlyPersistentStore: (from disassembly on macOS 27.2).
static const NSUInteger kICNoteContextReadOnly = 0x40;

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: probe <note x-coredata URI>\n"); return 2; }
    if (!dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_NOW)) {
      fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1;
    }
    Class Ctx = NSClassFromString(@"ICNoteContext");
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(Ctx, @selector(startSharedContextWithOptions:), kICNoteContextReadOnly);
    id ctx = ((id (*)(id, SEL))objc_msgSend)(Ctx, @selector(sharedContext));
    NSManagedObjectContext *moc = ((id (*)(id, SEL))objc_msgSend)(ctx, @selector(managedObjectContext));
    if (!moc) { fprintf(stderr, "no managed object context\n"); return 1; }

    // Refuse to go on unless every store really is read-only.
    BOOL allReadOnly = YES;
    for (NSPersistentStore *s in moc.persistentStoreCoordinator.persistentStores) {
      printf("store: %s readOnly=%d\n", s.URL.lastPathComponent.UTF8String, s.isReadOnly);
      allReadOnly &= s.isReadOnly;
    }
    if (!allReadOnly) { fprintf(stderr, "ABORT: a store is writable\n"); return 1; }

    NSURL *uri = [NSURL URLWithString:@(argv[1])];
    __block int rc = 0;
    [moc performBlockAndWait:^{
      NSManagedObjectID *oid = [moc.persistentStoreCoordinator managedObjectIDForURIRepresentation:uri];
      NSError *err = nil;
      id note = oid ? [moc existingObjectWithID:oid error:&err] : nil;
      if (!note) { fprintf(stderr, "note not found: %s\n", err.description.UTF8String); rc = 1; return; }
      printf("title: %s\n", [[note valueForKey:@"title"] UTF8String]);
      printf("account: %s\n", [[note valueForKeyPath:@"account.name"] description].UTF8String);

      NSAttributedString *as = ((id (*)(id, SEL))objc_msgSend)(note, @selector(attributedString));
      [as.string enumerateSubstringsInRange:NSMakeRange(0, as.length)
                                    options:NSStringEnumerationByParagraphs
                                 usingBlock:^(NSString *text, NSRange r, NSRange er, BOOL *stop) {
        NSDictionary *attrs = r.length ? [as attributesAtIndex:r.location effectiveRange:NULL] : @{};
        printf("¶ %-12s", text.UTF8String);
        for (NSString *key in attrs) {
          id v = attrs[key];
          if ([NSStringFromClass([v class]) containsString:@"ParagraphStyle"] && [v respondsToSelector:@selector(style)]) {
            long style = ((long (*)(id, SEL))objc_msgSend)(v, @selector(style));
            id todo = ((id (*)(id, SEL))objc_msgSend)(v, @selector(todo));
            printf("  [%s] style=%ld", key.UTF8String, style);
            if (todo) printf(" todo.done=%d todo.uuid=%s",
                             ((BOOL (*)(id, SEL))objc_msgSend)(todo, @selector(done)),
                             [[todo valueForKey:@"uuid"] description].UTF8String);
          }
        }
        printf("\n");
      }];
    }];
    return rc;
  }
}
