// Native Notes objects. Each make* function creates the object in `note`
// with Notes' own constructor and returns the one attachment character to
// insert into the text. Call them inside commit(); they fail with a JSON
// error (unsupported_macos, file_not_found, bad_url, bad_svg, ...).
#import "NNCore.h"

NSAttributedString *makeTag(id note, NSString *tag);
// A link to `target`, or to its paragraph `paragraphID` (shown as "Note → paragraph").
NSAttributedString *makeNoteLink(id note, id target, NSUUID *paragraphID, NSString *paragraphName);
NSAttributedString *makeDivider(id note);
NSAttributedString *makeTable(id note, NSArray<NSArray<NSString *> *> *rows);
NSAttributedString *makeFile(id note, NSString *path);
NSAttributedString *makeURLCard(id note, NSString *url);
// opts: width (points, default 400), ink (pen, pencil, marker), color (#rrggbb).
NSAttributedString *makeDrawing(id note, NSString *svgPath, NSDictionary *opts, NSDictionary **stats);

NSAttributedString *objectChar(NSString *identifier, NSString *uti);
BOOL textHasAttachment(id note, NSString *identifier);

// Relative file paths (images, SVGs) resolve against this folder.
void setRelativePathBase(NSString *dir);
NSString *resolvePath(NSString *path);
