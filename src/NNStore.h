// The Notes store, reached through Notes' private NotesShared framework.
//
// This is the seam to Notes. It has two adapters, chosen by the environment:
// the user's store, or (NNOTE_CONTAINER=<name>) a separate store at
// …/group.com.apple.notes/Containers/<name>/NoteStore.sqlite, which Notes'
// own UI tests use and the e2e tests use. A fresh container gets an
// On My Mac account when first opened for writing.
//
// Every function must run inside [gMOC performBlockAndWait:], after openContext.
// Failures exit through fail() with a JSON error.
#import <CoreData/CoreData.h>
#import "NNCore.h"

// The store's managed object context. Valid after openContext.
extern NSManagedObjectContext *gMOC;

// Opens the store. Read-only (writable NO) opens every persistent store with
// Notes' read-only option and fails if any store is writable anyway.
void openContext(BOOL writable);

NSArray *fetch(NSString *entity, NSPredicate *predicate);

// Lookups. Each fails with a not-found or ambiguity error instead of returning nil.
NSArray *allAccounts(void);
id accountNamed(NSString *name);
id resolveNote(NSString *ref);                       // id (UUID), x-coredata:// URI, or primary key
id resolveFolder(NSString *ref, NSString *accountName);  // id, or path "A/B" in the account (default On My Mac)
id noteTitled(NSString *title, id account);           // exact, unique title
NSArray *visibleNotes(NSPredicate *extra);            // not deleted, not in Recently Deleted

NSString *folderPath(id folder);
BOOL isTrash(id folder);
BOOL isPinned(id note);
NSDictionary *noteSummary(id note);  // id, uri, title, account, folder, pinned, modified

// Write guards: the account must be in NNOTE_WRITABLE_ACCOUNTS (default "On My Mac");
// the note must not be deleted or locked.
void guardAccount(id account);
void guardWritable(id note);
void requireSelectors(id object, NSArray<NSString *> *selectors);  // fails with unsupported_macos

// Runs `edit` as one edit of `note` the way Notes does it (beginEditing ...
// endEditing, title regeneration, modification date, change count), saves,
// and tells a running Notes.app to reload instead of overwriting the change.
void commit(id note, NSString *reason, void (^edit)(id mergeableString));
// Saves changes made outside commit (pins, folders) and notifies Notes.app.
void saveAndNotify(void);
