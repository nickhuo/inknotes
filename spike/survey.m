// Read-only survey of every note: which text attribute keys and value classes
// are used (to find highlights, bold, URL links...), and which paragraph styles.
// Prints counts and one example note pk per key, never note text.
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <dlfcn.h>
#import <objc/message.h>

#define MSG0(T) ((T (*)(id, SEL))objc_msgSend)

int main(void) {
  @autoreleasepool {
    dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_NOW);
    Class Ctx = NSClassFromString(@"ICNoteContext");
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(Ctx, @selector(startSharedContextWithOptions:), 0x40);
    NSManagedObjectContext *moc = MSG0(id)(MSG0(id)(Ctx, @selector(sharedContext)), @selector(managedObjectContext));
    for (NSPersistentStore *s in moc.persistentStoreCoordinator.persistentStores)
      if (!s.isReadOnly) { fprintf(stderr, "ABORT: writable store\n"); return 1; }
    [moc performBlockAndWait:^{
      NSPredicate *visible = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"ICNote"), @selector(predicateForVisibleNotesInContext:), moc);
      NSArray *notes = ((id (*)(id, SEL, id, id))objc_msgSend)(NSClassFromString(@"ICNote"), @selector(notesMatchingPredicate:context:), visible, moc);
      NSCountedSet *keys = [NSCountedSet set], *styles = [NSCountedSet set];
      NSMutableDictionary *example = [NSMutableDictionary dictionary];
      for (id note in notes) {
        @autoreleasepool {
          NSString *pk = [[note objectID].URIRepresentation lastPathComponent];
          NSAttributedString *as = MSG0(id)(MSG0(id)(note, @selector(mergeableString)), @selector(attributedString));
          [as enumerateAttributesInRange:NSMakeRange(0, as.length) options:0 usingBlock:^(NSDictionary *attrs, NSRange r, BOOL *stop) {
            for (NSString *k in attrs) {
              id v = attrs[k];
              NSString *desc = [NSString stringWithFormat:@"%@ : %@", k, NSStringFromClass([v class])];
              if ([k isEqualToString:@"TTStyle"]) {
                [styles addObject:@(MSG0(long)(v, @selector(style)))];
              } else if ([v isKindOfClass:NSNumber.class] && ![k isEqualToString:@"TTTimestamp"]) {
                desc = [desc stringByAppendingFormat:@" = %@", v];
              }
              [keys addObject:desc];
              if (!example[desc]) example[desc] = pk;
            }
          }];
        }
      }
      printf("notes: %lu\nattribute keys:\n", (unsigned long)notes.count);
      for (NSString *k in [keys.allObjects sortedArrayUsingSelector:@selector(compare:)])
        printf("  %6lu  %-60s e.g. %s\n", (unsigned long)[keys countForObject:k], k.UTF8String, [example[k] UTF8String]);
      printf("paragraph styles:\n");
      for (NSNumber *s in [styles.allObjects sortedArrayUsingSelector:@selector(compare:)])
        printf("  style %ld: %lu runs\n", s.longValue, (unsigned long)[styles countForObject:s]);
    }];
  }
}
