// Shared by every module: message sends to private classes, the names Notes
// uses for text attributes and attachment types, and JSON output.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

// Typed objc_msgSend, for calling private methods found at runtime.
#define MSG0(T) ((T (*)(id, SEL))objc_msgSend)
#define MSG(T, ...) ((T (*)(id, SEL, __VA_ARGS__))objc_msgSend)

// Text attribute keys, as stored by Notes (found by surveying every note).
static NSString *const kStyleKey = @"TTStyle";             // ICTTParagraphStyle
static NSString *const kAttachmentKey = @"NSAttachment";    // ICTTAttachment
static NSString *const kLinkKey = @"NSLink";                // NSURL
static NSString *const kHintsKey = @"TTHints";              // font traits: 1 bold, 2 italic
static NSString *const kUnderlineKey = @"TTUnderline";      // 1
static NSString *const kStrikeKey = @"TTStrikethrough";     // 1
static NSString *const kEmphasisKey = @"TTEmphasis";        // highlight color, 1-5

static NSString *const kUTIHashtag = @"com.apple.notes.inlinetextattachment.hashtag";
static NSString *const kUTILink = @"com.apple.notes.inlinetextattachment.link";
static NSString *const kUTITable = @"com.apple.notes.table";
static NSString *const kUTIURL = @"public.url";

// ICTTParagraphStyle.style values.
enum { kStyleTitle = 0, kStyleHeading = 1, kStyleSubheading = 2, kStyleBody = 3, kStyleMono = 4,
       kStyleBullet = 100, kStyleDash = 101, kStyleNumbered = 102, kStyleChecklist = 103 };

// "title" -> 0 ... "checklist" -> 103, and back ("styleN" for unknown values).
NSDictionary<NSString *, NSNumber *> *styleNames(void);
NSString *styleName(long style);

// TTEmphasis values, confirmed in Notes.app's highlight menu (macOS 27.2):
// 1 purple, 2 pink, 3 orange, 4 mint, 5 blue.
NSArray<NSString *> *highlightNames(void);
id highlightName(NSNumber *value);           // the color name, or the number if unknown
NSInteger highlightValue(NSString *nameOrNumber);  // "pink"/"2" -> 2; "none"/"0" -> 0; otherwise -1

// Prints `obj` as JSON to stdout.
void emit(id obj);
// Prints {"error": code, "message": message} to stderr and exits with status 1.
__attribute__((noreturn)) void fail(NSString *code, NSString *message);
