// A note's text: reading it as paragraphs, and the primitives for editing it.
//
// Paragraph JSON: {index, text, style, paragraph_id, indent?, quote?, todo?,
// attachments?, formats?}. `text` shows tags and links by their displayed
// text and other attachments as "[type]". `paragraph_id` is the paragraph
// style's UUID, which paragraph links point to.
#import "NNCore.h"

typedef struct { NSRange range, enclosing; } Para;  // without / with the trailing newline

id mergeable(id note);                       // the note's ICTTMergeableAttributedString
NSAttributedString *bodyText(id note);
NSArray<NSValue *> *paragraphRanges(NSAttributedString *text);
Para paraAt(NSArray<NSValue *> *ranges, NSUInteger index);
id styleAt(NSAttributedString *text, NSRange range);  // the ICTTParagraphStyle there

NSDictionary *attachmentInfo(id ttAttachment);  // {id, uti, type, text?, target?, rows?, url?, title?}
NSArray *paragraphsJSON(NSAttributedString *text);
NSDictionary *noteJSON(id note);               // noteSummary plus paragraphs

// The paragraph at --index, or the one whose text equals `text`. Fails with
// paragraph_not_found, ambiguous_paragraph (listing the indexes) or bad_index.
NSUInteger findParagraph(NSArray *paragraphs, NSString *text, NSString *indexArg);

// Editing primitives, for use inside commit().
id newTodo(BOOL done);                                        // ICTTTodo with a new UUID
id newStyle(long style, NSUInteger indent, NSInteger quote, BOOL done);  // new paragraph identity
NSAttributedString *paragraph(NSAttributedString *content, id style, BOOL newline);
// Inserts whole paragraphs after paragraph `afterIndex`, or at the end when -1.
void insertParagraphs(id note, NSInteger afterIndex, NSAttributedString *paragraphs);
