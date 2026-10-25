#import "NNSVG.h"
#import <AppKit/AppKit.h>

#pragma mark - Geometry

typedef struct { CGFloat a, b, c, d, tx, ty; } Mat;  // x' = a*x + c*y + tx; y' = b*x + d*y + ty
static Mat matIdentity(void) { return (Mat){1, 0, 0, 1, 0, 0}; }
static Mat matMul(Mat m, Mat n) {  // apply n, then m
  return (Mat){m.a * n.a + m.c * n.b, m.b * n.a + m.d * n.b, m.a * n.c + m.c * n.d,
               m.b * n.c + m.d * n.d, m.a * n.tx + m.c * n.ty + m.tx, m.b * n.tx + m.d * n.ty + m.ty};
}
static CGPoint matApply(Mat m, CGPoint p) { return CGPointMake(m.a * p.x + m.c * p.y + m.tx, m.b * p.x + m.d * p.y + m.ty); }
static CGFloat matScale(Mat m) { return sqrt(fabs(m.a * m.d - m.b * m.c)); }

static NSArray<NSNumber *> *numbers(NSString *s) {
  NSMutableArray *out = [NSMutableArray array];
  NSScanner *sc = [NSScanner scannerWithString:s ?: @""];
  sc.charactersToBeSkipped = [NSCharacterSet characterSetWithCharactersInString:@" ,\t\n\r"];
  double v;
  while (!sc.isAtEnd) {
    if ([sc scanDouble:&v]) [out addObject:@(v)];
    else sc.scanLocation += 1;
  }
  return out;
}

static Mat parseTransform(NSString *t) {
  Mat m = matIdentity();
  if (!t.length) return m;
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(matrix|translate|scale|rotate)\\s*\\(([^)]*)\\)" options:0 error:NULL];
  for (NSTextCheckingResult *r in [re matchesInString:t options:0 range:NSMakeRange(0, t.length)]) {
    NSString *fn = [t substringWithRange:[r rangeAtIndex:1]];
    NSArray<NSNumber *> *v = numbers([t substringWithRange:[r rangeAtIndex:2]]);
    Mat n = matIdentity();
    if ([fn isEqualToString:@"matrix"] && v.count == 6) n = (Mat){v[0].doubleValue, v[1].doubleValue, v[2].doubleValue, v[3].doubleValue, v[4].doubleValue, v[5].doubleValue};
    else if ([fn isEqualToString:@"translate"] && v.count) n.tx = v[0].doubleValue, n.ty = v.count > 1 ? v[1].doubleValue : 0;
    else if ([fn isEqualToString:@"scale"] && v.count) n.a = v[0].doubleValue, n.d = v.count > 1 ? v[1].doubleValue : v[0].doubleValue;
    else if ([fn isEqualToString:@"rotate"] && v.count) {
      CGFloat r0 = v[0].doubleValue * M_PI / 180, cx = v.count > 2 ? v[1].doubleValue : 0, cy = v.count > 2 ? v[2].doubleValue : 0;
      Mat rot = {cos(r0), sin(r0), -sin(r0), cos(r0), 0, 0};
      n = matMul(matMul((Mat){1, 0, 0, 1, cx, cy}, rot), (Mat){1, 0, 0, 1, -cx, -cy});
    }
    m = matMul(m, n);
  }
  return m;
}

#pragma mark - Colors

static NSColor *parseColor(NSString *s) {
  s = [[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString];
  if (!s.length || [s isEqualToString:@"none"] || [s isEqualToString:@"transparent"]) return nil;
  if ([s hasPrefix:@"#"]) {
    NSString *h = [s substringFromIndex:1];
    if (h.length == 3) h = [NSString stringWithFormat:@"%C%C%C%C%C%C", [h characterAtIndex:0], [h characterAtIndex:0],
                            [h characterAtIndex:1], [h characterAtIndex:1], [h characterAtIndex:2], [h characterAtIndex:2]];
    unsigned v = 0;
    if (h.length != 6 || ![[NSScanner scannerWithString:h] scanHexInt:&v]) return NSColor.blackColor;
    return [NSColor colorWithSRGBRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1];
  }
  if ([s hasPrefix:@"rgb"]) {
    NSArray<NSNumber *> *v = numbers([s substringFromIndex:[s rangeOfString:@"("].location + 1]);
    if (v.count >= 3) return [NSColor colorWithSRGBRed:v[0].doubleValue / 255 green:v[1].doubleValue / 255 blue:v[2].doubleValue / 255 alpha:1];
  }
  NSDictionary *named = @{@"black": @"#000000", @"white": @"#ffffff", @"red": @"#ff0000", @"green": @"#008000",
                          @"blue": @"#0000ff", @"yellow": @"#ffff00", @"orange": @"#ffa500", @"purple": @"#800080",
                          @"gray": @"#808080", @"grey": @"#808080", @"pink": @"#ffc0cb", @"brown": @"#a52a2a",
                          @"navy": @"#000080", @"teal": @"#008080", @"currentcolor": @"#000000"};
  return named[s] ? parseColor(named[s]) : NSColor.blackColor;
}

#pragma mark - Paths

// Collects subpaths of sampled points in SVG user space.
@interface NNPathBuilder : NSObject
@property NSMutableArray<NSMutableArray<NSValue *> *> *subpaths;
@end
@implementation NNPathBuilder {
  CGPoint _cur, _start, _lastCtrl;
  unichar _lastCmd;
}
- (instancetype)init { if ((self = [super init])) _subpaths = [NSMutableArray array]; return self; }
- (void)moveTo:(CGPoint)p { [_subpaths addObject:[NSMutableArray arrayWithObject:[NSValue valueWithPoint:p]]]; _cur = _start = p; }
- (void)lineTo:(CGPoint)p {
  if (!_subpaths.count) [self moveTo:_cur];
  [_subpaths.lastObject addObject:[NSValue valueWithPoint:p]];
  _cur = p;
}
- (void)cubic:(CGPoint)c1 c2:(CGPoint)c2 to:(CGPoint)p {
  CGPoint p0 = _cur;
  CGFloat len = hypot(c1.x - p0.x, c1.y - p0.y) + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(p.x - c2.x, p.y - c2.y);
  int n = MAX(4, MIN(64, (int)(len / 2)));
  for (int i = 1; i <= n; i++) {
    CGFloat t = (CGFloat)i / n, u = 1 - t;
    [self lineTo:CGPointMake(u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p.x,
                             u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p.y)];
  }
}
- (void)quad:(CGPoint)c to:(CGPoint)p {
  CGPoint p0 = _cur;
  [self cubic:CGPointMake(p0.x + 2.0 / 3 * (c.x - p0.x), p0.y + 2.0 / 3 * (c.y - p0.y))
           c2:CGPointMake(p.x + 2.0 / 3 * (c.x - p.x), p.y + 2.0 / 3 * (c.y - p.y)) to:p];
}
// SVG elliptical arc, endpoint parameterization (SVG 1.1 appendix F.6.5).
- (void)arcRx:(CGFloat)rx ry:(CGFloat)ry rot:(CGFloat)phiDeg large:(BOOL)fa sweep:(BOOL)fs to:(CGPoint)p {
  CGPoint p0 = _cur;
  if (rx == 0 || ry == 0) { [self lineTo:p]; return; }
  rx = fabs(rx), ry = fabs(ry);
  CGFloat phi = phiDeg * M_PI / 180, cp = cos(phi), sp = sin(phi);
  CGFloat dx = (p0.x - p.x) / 2, dy = (p0.y - p.y) / 2;
  CGFloat x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy;
  CGFloat lam = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry);
  if (lam > 1) rx *= sqrt(lam), ry *= sqrt(lam);
  CGFloat num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1, den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
  CGFloat k = (fa == fs ? -1 : 1) * sqrt(MAX(0, num / den));
  CGFloat cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx;
  CGFloat cx = cp * cx1 - sp * cy1 + (p0.x + p.x) / 2, cy = sp * cx1 + cp * cy1 + (p0.y + p.y) / 2;
  CGFloat th1 = atan2((y1 - cy1) / ry, (x1 - cx1) / rx);
  CGFloat dth = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - th1;
  if (!fs && dth > 0) dth -= 2 * M_PI;
  if (fs && dth < 0) dth += 2 * M_PI;
  int n = MAX(8, MIN(96, (int)(fabs(dth) * MAX(rx, ry) / 2)));
  for (int i = 1; i <= n; i++) {
    CGFloat t = th1 + dth * i / n;
    [self lineTo:CGPointMake(cx + rx * cos(t) * cp - ry * sin(t) * sp, cy + rx * cos(t) * sp + ry * sin(t) * cp)];
  }
}
- (void)close { if (_subpaths.count) { [self lineTo:_start]; } }

- (void)parseD:(NSString *)d {
  NSScanner *sc = [NSScanner scannerWithString:d];
  NSCharacterSet *cmds = [NSCharacterSet characterSetWithCharactersInString:@"MmLlHhVvCcSsQqTtAaZz"];
  sc.charactersToBeSkipped = [NSCharacterSet characterSetWithCharactersInString:@" ,\t\n\r"];
  unichar cmd = 'M';
  double v[7];
  while (!sc.isAtEnd) {
    NSString *c = nil;
    if ([sc scanCharactersFromSet:cmds intoString:&c]) {
      for (NSUInteger i = 0; i < c.length; i++) {  // several letters in a row: only Z/z make sense
        cmd = [c characterAtIndex:i];
        if (cmd == 'Z' || cmd == 'z') { [self close]; _lastCmd = cmd; }
      }
      if (cmd == 'Z' || cmd == 'z') continue;
    }
    int need = strchr("MmLlTt", cmd) ? 2 : strchr("HhVv", cmd) ? 1 : strchr("CcSsQq", cmd) ? (strchr("Cc", cmd) ? 6 : 4) : 7;
    int got = 0;
    for (; got < need; got++) if (![sc scanDouble:&v[got]]) break;
    if (got < need) { if (!sc.isAtEnd) sc.scanLocation += 1; continue; }
    BOOL rel = islower(cmd);
    CGFloat ox = rel ? _cur.x : 0, oy = rel ? _cur.y : 0;
    CGPoint refl = (strchr("CcSsQqTt", _lastCmd)) ? CGPointMake(2 * _cur.x - _lastCtrl.x, 2 * _cur.y - _lastCtrl.y) : _cur;
    switch (cmd) {
      case 'M': case 'm': [self moveTo:CGPointMake(ox + v[0], oy + v[1])]; cmd = rel ? 'l' : 'L'; break;
      case 'L': case 'l': [self lineTo:CGPointMake(ox + v[0], oy + v[1])]; break;
      case 'H': case 'h': [self lineTo:CGPointMake(ox + v[0], _cur.y)]; break;
      case 'V': case 'v': [self lineTo:CGPointMake(_cur.x, oy + v[0])]; break;
      case 'C': case 'c': _lastCtrl = CGPointMake(ox + v[2], oy + v[3]);
        [self cubic:CGPointMake(ox + v[0], oy + v[1]) c2:_lastCtrl to:CGPointMake(ox + v[4], oy + v[5])]; break;
      case 'S': case 's': _lastCtrl = CGPointMake(ox + v[0], oy + v[1]);
        [self cubic:(strchr("CcSs", _lastCmd) ? refl : _cur) c2:_lastCtrl to:CGPointMake(ox + v[2], oy + v[3])]; break;
      case 'Q': case 'q': _lastCtrl = CGPointMake(ox + v[0], oy + v[1]);
        [self quad:_lastCtrl to:CGPointMake(ox + v[2], oy + v[3])]; break;
      case 'T': case 't': _lastCtrl = strchr("QqTt", _lastCmd) ? refl : _cur;
        [self quad:_lastCtrl to:CGPointMake(ox + v[0], oy + v[1])]; break;
      case 'A': case 'a':
        [self arcRx:v[0] ry:v[1] rot:v[2] large:v[3] != 0 sweep:v[4] != 0 to:CGPointMake(ox + v[5], oy + v[6])]; break;
    }
    _lastCmd = cmd;
  }
}
@end

#pragma mark - Document

@interface NNSVGReader : NSObject <NSXMLParserDelegate>
@property NSMutableArray *shapes;  // {points: [[NSValue]], color: NSColor, width: CGFloat}
@property CGRect viewBox;
@property BOOL hasViewBox;
@end

@implementation NNSVGReader {
  NSMutableArray<NSDictionary *> *_stack;  // inherited {matrix, stroke, fill, width}
}
- (instancetype)init {
  if ((self = [super init])) {
    _shapes = [NSMutableArray array];
    _stack = [NSMutableArray arrayWithObject:@{@"m": [NSValue valueWithBytes:&(Mat){1, 0, 0, 1, 0, 0} objCType:@encode(Mat)],
                                                @"stroke": @"none", @"fill": @"black", @"width": @1}];
  }
  return self;
}

static NSDictionary *styleAttrs(NSDictionary *attrs) {
  NSMutableDictionary *s = [NSMutableDictionary dictionary];
  for (NSString *k in @[@"stroke", @"fill", @"stroke-width"]) if (attrs[k]) s[k] = attrs[k];
  for (NSString *decl in [attrs[@"style"] componentsSeparatedByString:@";"]) {
    NSArray *kv = [decl componentsSeparatedByString:@":"];
    if (kv.count == 2) s[[kv[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]] =
                       [kv[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  }
  return s;
}

- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary *)a {
  NSDictionary *parent = _stack.lastObject;
  Mat m; [parent[@"m"] getValue:&m];
  m = matMul(m, parseTransform(a[@"transform"]));
  NSDictionary *st = styleAttrs(a);
  NSDictionary *ctx = @{@"m": [NSValue valueWithBytes:&m objCType:@encode(Mat)],
                        @"stroke": st[@"stroke"] ?: parent[@"stroke"], @"fill": st[@"fill"] ?: parent[@"fill"],
                        @"width": st[@"stroke-width"] ? @([st[@"stroke-width"] doubleValue]) : parent[@"width"]};
  [_stack addObject:ctx];

  if ([name isEqualToString:@"svg"]) {
    NSArray<NSNumber *> *vb = numbers(a[@"viewBox"]);
    if (vb.count == 4) { _viewBox = CGRectMake(vb[0].doubleValue, vb[1].doubleValue, vb[2].doubleValue, vb[3].doubleValue); _hasViewBox = YES; }
    else if (a[@"width"] && a[@"height"]) { _viewBox = CGRectMake(0, 0, [a[@"width"] doubleValue], [a[@"height"] doubleValue]); _hasViewBox = YES; }
    return;
  }
  NNPathBuilder *b = [NNPathBuilder new];
  double (^num)(NSString *) = ^double(NSString *k) { return [a[k] doubleValue]; };
  if ([name isEqualToString:@"path"]) [b parseD:a[@"d"] ?: @""];
  else if ([name isEqualToString:@"line"]) { [b moveTo:CGPointMake(num(@"x1"), num(@"y1"))]; [b lineTo:CGPointMake(num(@"x2"), num(@"y2"))]; }
  else if ([name isEqualToString:@"polyline"] || [name isEqualToString:@"polygon"]) {
    NSArray<NSNumber *> *v = numbers(a[@"points"]);
    for (NSUInteger i = 0; i + 1 < v.count; i += 2) {
      CGPoint pt = CGPointMake(v[i].doubleValue, v[i + 1].doubleValue);
      if (i == 0) [b moveTo:pt]; else [b lineTo:pt];
    }
    if ([name isEqualToString:@"polygon"]) [b close];
  } else if ([name isEqualToString:@"rect"]) {
    CGFloat x = num(@"x"), y = num(@"y"), w = num(@"width"), h = num(@"height");
    [b moveTo:CGPointMake(x, y)]; [b lineTo:CGPointMake(x + w, y)]; [b lineTo:CGPointMake(x + w, y + h)];
    [b lineTo:CGPointMake(x, y + h)]; [b close];
  } else if ([name isEqualToString:@"circle"] || [name isEqualToString:@"ellipse"]) {
    CGFloat cx = num(@"cx"), cy = num(@"cy");
    CGFloat rx = [name isEqualToString:@"circle"] ? num(@"r") : num(@"rx"), ry = [name isEqualToString:@"circle"] ? num(@"r") : num(@"ry");
    [b moveTo:CGPointMake(cx + rx, cy)];
    [b arcRx:rx ry:ry rot:0 large:NO sweep:YES to:CGPointMake(cx - rx, cy)];
    [b arcRx:rx ry:ry rot:0 large:NO sweep:YES to:CGPointMake(cx + rx, cy)];
  } else {
    return;
  }
  NSColor *color = parseColor(ctx[@"stroke"]) ?: parseColor(ctx[@"fill"]);
  if (!color) return;
  BOOL stroked = parseColor(ctx[@"stroke"]) != nil;
  CGFloat width = (stroked ? [ctx[@"width"] doubleValue] : 1) * matScale(m);
  for (NSArray<NSValue *> *sub in b.subpaths) {
    if (sub.count < 2) continue;
    NSMutableArray *pts = [NSMutableArray arrayWithCapacity:sub.count];
    for (NSValue *v in sub) [pts addObject:[NSValue valueWithPoint:matApply(m, v.pointValue)]];
    [_shapes addObject:@{@"points": pts, @"color": color, @"width": @(MAX(width, 0.5))}];
  }
}

- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
  if (_stack.count > 1) [_stack removeLastObject];
}
@end

PKDrawing *NNDrawingFromSVG(NSString *path, CGFloat width, NSString *colorOverride, NSString *ink, NSDictionary **stats, NSError **error) {
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (!data) { if (error) *error = [NSError errorWithDomain:@"nnote" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Cannot read the SVG file."}]; return nil; }
  NNSVGReader *r = [NNSVGReader new];
  NSXMLParser *xp = [[NSXMLParser alloc] initWithData:data];
  xp.delegate = r;
  if (![xp parse] || !r.shapes.count) {
    if (error) *error = [NSError errorWithDomain:@"nnote" code:2 userInfo:@{NSLocalizedDescriptionKey:
      r.shapes.count ? @"The SVG could not be parsed." : @"The SVG has no drawable shapes."}];
    return nil;
  }
  // Fit the drawing to `width` points, keeping its aspect ratio; origin at 0,0.
  CGRect box = r.viewBox;
  if (!r.hasViewBox) {
    CGFloat minX = CGFLOAT_MAX, minY = CGFLOAT_MAX, maxX = -CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
    for (NSDictionary *s in r.shapes) for (NSValue *v in s[@"points"]) {
      CGPoint p = v.pointValue;
      minX = MIN(minX, p.x), minY = MIN(minY, p.y), maxX = MAX(maxX, p.x), maxY = MAX(maxY, p.y);
    }
    box = CGRectMake(minX, minY, MAX(maxX - minX, 1), MAX(maxY - minY, 1));
  }
  CGFloat scale = width / MAX(box.size.width, 1);
  PKInkType type = [ink isEqualToString:@"pencil"] ? PKInkTypePencil : [ink isEqualToString:@"marker"] ? PKInkTypeMarker : PKInkTypePen;
  NSColor *override = colorOverride.length ? parseColor(colorOverride) : nil;
  NSMutableArray<PKStroke *> *strokes = [NSMutableArray array];
  NSUInteger points = 0;
  for (NSDictionary *s in r.shapes) {
    CGFloat w = [s[@"width"] doubleValue] * scale;
    NSMutableArray<PKStrokePoint *> *cps = [NSMutableArray array];
    NSTimeInterval t = 0;
    for (NSValue *v in s[@"points"]) {
      CGPoint p = v.pointValue;
      p = CGPointMake((p.x - box.origin.x) * scale, (p.y - box.origin.y) * scale);
      [cps addObject:[[PKStrokePoint alloc] initWithLocation:p timeOffset:t size:CGSizeMake(w, w)
                                                      opacity:1 force:1 azimuth:0 altitude:M_PI_2]];
      t += 0.01;
    }
    points += cps.count;
    PKStrokePath *sp = [[PKStrokePath alloc] initWithControlPoints:cps creationDate:[NSDate date]];
    PKInk *pkInk = [[PKInk alloc] initWithInkType:type color:override ?: s[@"color"]];
    [strokes addObject:[[PKStroke alloc] initWithInk:pkInk strokePath:sp transform:CGAffineTransformIdentity mask:nil]];
  }
  if (stats) *stats = @{@"strokes": @(strokes.count), @"points": @(points),
                        @"size": @[@(round(box.size.width * scale)), @(round(box.size.height * scale))]};
  return [[PKDrawing alloc] initWithStrokes:strokes];
}
