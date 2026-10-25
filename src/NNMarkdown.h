// Markdown in and out of notes.
//
// Import is two steps so writes can be dry runs: parseMarkdown turns text into
// blocks, planBlocks validates them (links resolve, files exist) without
// writing, and renderBlocks builds the note text, creating tags, links and
// attachments. The syntax is listed in README.md.
#import "NNCore.h"

NSString *noteMarkdown(id note);

// Blocks: {kind: para, style, indent, quote, done, text} | {kind: table, rows}
//       | {kind: file | url | drawing, value} | {kind: divider}
NSArray<NSDictionary *> *parseMarkdown(NSString *markdown);
NSArray *planBlocks(NSArray *blocks, id account);
NSAttributedString *renderBlocks(NSArray *blocks, id note, id account);

// Inline Markdown. With `note` nil, links and tags are only validated
// (against `account`, when given) and collected in `refs`.
NSAttributedString *parseInline(NSString *text, id note, id account, NSMutableArray *refs);

// Reads a file, or stdin for "-"; relative paths in it then resolve against
// the file's folder. Returns nil when `source` is nil.
NSString *readInput(NSString *source);
