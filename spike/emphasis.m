// Read-only: ask Notes how it describes the highlight on each "Highlight color N"
// line of the smoke-test note, next to the stored TTEmphasis value.
// Usage: emphasis <note Z_PK>
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <dlfcn.h>
#import <objc/message.h>

#define MSG0(T) ((T (*)(id, SEL))objc_msgSend)

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) return 2;
    dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/NotesUI.framework/NotesUI", RTLD_NOW);  // the method is a NotesUI category
    Class Ctx = NSClassFromString(@"ICNoteContext");
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(Ctx, @selector(startSharedContextWithOptions:), 0x40);
    NSManagedObjectContext *moc = MSG0(id)(MSG0(id)(Ctx, @selector(sharedContext)), @selector(managedObjectContext));
    for (NSPersistentStore *s in moc.persistentStoreCoordinator.persistentStores) if (!s.isReadOnly) return 1;
    [moc performBlockAndWait:^{
      NSString *storeID = moc.persistentStoreCoordinator.persistentStores.firstObject.metadata[NSStoreUUIDKey];
      NSURL *uri = [NSURL URLWithString:[NSString stringWithFormat:@"x-coredata://%@/ICNote/p%s", storeID, argv[1]]];
      id note = [moc existingObjectWithID:[moc.persistentStoreCoordinator managedObjectIDForURIRepresentation:uri] error:NULL];
      NSAttributedString *as = MSG0(id)(MSG0(id)(note, @selector(mergeableString)), @selector(attributedString));
      for (int c = 1; c <= 5; c++) {
        NSRange r = [as.string rangeOfString:[NSString stringWithFormat:@"color %d", c]];
        if (r.location == NSNotFound) continue;
        id stored = [as attribute:@"TTEmphasis" atIndex:r.location effectiveRange:NULL];
        id desc = ((id (*)(id, SEL, NSRange))objc_msgSend)(note, @selector(emphasisStyleAccessibilityDescriptionForRange:), r);
        printf("line %d: TTEmphasis=%s  Notes says: %s\n", c, [stored description].UTF8String, [desc description].UTF8String);
      }
    }];
  }
}
