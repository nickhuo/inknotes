// SVG to PencilKit: turns the outlines in an SVG file into PKDrawing strokes.
#import <Foundation/Foundation.h>
#import <PencilKit/PencilKit.h>

// Supported: <path> (M L H V C S Q T A Z, absolute and relative), <line>,
// <polyline>, <polygon>, <rect>, <circle>, <ellipse>, nested <g>, and the
// transforms translate/scale/matrix. Each subpath becomes one stroke drawn with
// its stroke color (or fill color when it has no stroke) and stroke width.
// `width` scales the drawing to that many points wide. `colorOverride`
// ("#rrggbb", optional) replaces every color. `ink` is "pen", "pencil" or "marker".
PKDrawing *NNDrawingFromSVG(NSString *path, CGFloat width, NSString *colorOverride,
                            NSString *ink, NSDictionary **stats, NSError **error);
