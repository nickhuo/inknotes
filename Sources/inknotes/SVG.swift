// SVG to PencilKit: turns the outlines in an SVG file into PKDrawing strokes.
//
// Supported: <path> (M L H V C S Q T A Z, absolute and relative), <line>,
// <polyline>, <polygon>, <rect>, <circle>, <ellipse>, nested <g>, and the
// transforms translate/scale/rotate/matrix. Each subpath becomes one stroke
// drawn with its stroke color (or fill color when it has no stroke) and
// stroke width. The drawing is scaled to `width` points wide.

import AppKit
import CoreText
import Foundation
import PencilKit

struct SVGError: Error { let message: String }

/// The drawing plus {strokes, points, size}.
func drawingFromSVG(path: String, width: Double, color colorOverride: String?, ink: String) -> Result<(PKDrawing, [String: Any]), SVGError> {
    guard let data = FileManager.default.contents(atPath: path) else { return .failure(SVGError(message: "Cannot read the SVG file.")) }
    let reader = SVGReader()
    let parser = XMLParser(data: data)
    parser.delegate = reader
    if !parser.parse() || reader.shapes.isEmpty {
        return .failure(SVGError(message: reader.shapes.isEmpty ? "The SVG has no drawable shapes." : "The SVG could not be parsed."))
    }
    // Fit the drawing to `width` points, keeping its aspect ratio; origin at 0,0.
    var box = reader.viewBox
    if box == nil {
        let points = reader.shapes.flatMap(\.points)
        let xs = points.map(\.x), ys = points.map(\.y)
        box = CGRect(x: xs.min()!, y: ys.min()!, width: max(xs.max()! - xs.min()!, 1), height: max(ys.max()! - ys.min()!, 1))
    }
    let bounds = box!
    let scale = width / max(bounds.width, 1)
    let inkType: PKInk.InkType = ink == "pencil" ? .pencil : ink == "marker" ? .marker : .pen
    let override = (colorOverride ?? "").isEmpty ? nil : parseColor(colorOverride!)
    var strokes: [PKStroke] = []
    var pointCount = 0
    var maxDeviation = 0.0
    var widthRatios: [Double] = []
    for shape in reader.shapes {
        // Glyph outlines get at least 0.8 pt so small labels stay legible.
        let w = shape.isText ? max(shape.width * scale, 0.8) : shape.width * scale
        let size = pointSize(forWidth: w, ink: inkType)
        let polyline = shape.points.map { CGPoint(x: ($0.x - bounds.minX) * scale, y: ($0.y - bounds.minY) * scale) }
        // PencilKit smooths control points into a spline; dense points keep it on straight edges and corners.
        let controlPoints = densified(polyline, step: 2).enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: size, height: size),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        pointCount += controlPoints.count
        let strokePath = PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        maxDeviation = max(maxDeviation, deviation(of: strokePath, from: polyline))
        let stroke = PKStroke(ink: PKInk(inkType, color: override ?? shape.color), path: strokePath)
        // Glyph contours sit too close together (a letter's inside and outside) to measure one alone.
        if !shape.isText, let drawn = drawnWidth(of: stroke, expected: w) { widthRatios.append(drawn / w) }
        strokes.append(stroke)
    }
    func decimal(_ v: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", v)) }
    let stats: [String: Any] = ["strokes": strokes.count, "points": pointCount,
                                "size": [(bounds.width * scale).rounded(), (bounds.height * scale).rounded()],
                                "max_deviation": decimal(maxDeviation),
                                "text": reader.textCount, "glyphs": reader.glyphCount,
                                "width_ratio": [decimal(widthRatios.min() ?? 0), decimal(widthRatios.max() ?? 0)]]
    return .success((PKDrawing(strokes: strokes), stats))
}

/// The PKStrokePoint size that makes `ink` draw a line `width` points wide. A point's size is not
/// the drawn width. Measured by rendering lines on macOS 27.2:
/// - pen (and monoline): drawn width = 2 × (size − 2), the same in every direction
/// - pencil: textured and not linear for thin lines; interpolated from the table below
/// - marker: a chisel nib, about half as wide across horizontal lines as across vertical ones;
///   the table is the average of the two
private func pointSize(forWidth width: Double, ink: PKInk.InkType) -> Double {
    let sizes: [Double] = [1, 2, 2.5, 3, 4, 5, 6, 8, 10, 15, 20, 30, 40]
    let drawn: [Double]
    switch ink {
    case .pencil: drawn = [0.79, 3.33, 3.65, 4.52, 6.29, 8.13, 9.5, 12.36, 18.36, 27.15, 36.27, 46.84, 65.61]
    case .marker: drawn = [0.68, 1.34, 1.68, 2.0, 2.68, 3.36, 4.06, 5.53, 7.07, 11.15, 15.71, 26.34, 35.1]
    default: return width / 2 + 2
    }
    if width <= drawn[0] { return max(sizes[0] * width / drawn[0], 0.5) }
    for i in 1..<drawn.count where width <= drawn[i] {
        let t = (width - drawn[i - 1]) / (drawn[i] - drawn[i - 1])
        return sizes[i - 1] + t * (sizes[i] - sizes[i - 1])
    }
    let n = drawn.count - 1
    return sizes[n] + (width - drawn[n]) * (sizes[n] - sizes[n - 1]) / (drawn[n] - drawn[n - 1])
}

/// The width, in points, PencilKit actually renders `stroke` at. The stroke is rendered on its
/// own at 8x; at five places along its path the ink coverage is summed across it, within
/// reach of where the line should be (so other parts of the same shape don't count), and the
/// median is returned. Nil for strokes too short to measure.
private func drawnWidth(of stroke: PKStroke, expected: Double) -> Double? {
    let path = stroke.path.interpolatedPoints(by: .distance(1)).map(\.location)
    guard path.count > 12 else { return nil }
    let pixelsPerPoint = 8.0
    let reach = expected + 2
    var widths: [Double] = []
    for fraction in [0.2, 0.35, 0.5, 0.65, 0.8] {
        let i = Int(Double(path.count - 1) * fraction)
        let a = path[max(i - 3, 0)], b = path[min(i + 3, path.count - 1)], center = path[i]
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0 else { continue }
        let normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
        let area = CGRect(x: center.x - reach, y: center.y - reach, width: 2 * reach, height: 2 * reach)
        let image = PKDrawing(strokes: [stroke]).image(from: area, scale: pixelsPerPoint)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        var coverage = 0.0
        for step in stride(from: -reach, through: reach, by: 1 / pixelsPerPoint) {
            let x = Int(((center.x + normal.x * step) - area.minX) * pixelsPerPoint)
            let y = Int(((center.y + normal.y * step) - area.minY) * pixelsPerPoint)
            guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { continue }
            coverage += Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
        }
        widths.append(coverage / pixelsPerPoint)
    }
    guard !widths.isEmpty else { return nil }
    return widths.sorted()[widths.count / 2]
}

/// The polyline with extra points so no two consecutive points are more than `step` apart;
/// repeated points are dropped.
private func densified(_ points: [CGPoint], step: Double) -> [CGPoint] {
    guard var last = points.first else { return [] }
    var out = [last]
    for p in points.dropFirst() {
        let d = hypot(p.x - last.x, p.y - last.y)
        if d == 0 { continue }
        let n = Int((d / step).rounded(.up))
        for k in stride(from: 1, to: n, by: 1) {
            let t = Double(k) / Double(n)
            out.append(CGPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t))
        }
        out.append(p)
        last = p
    }
    return out
}

/// How far, in points, the line PencilKit actually draws strays from the polyline it was
/// given, measured both ways (drawn → intended and intended → drawn), so cut corners count.
/// PencilKit treats stroke points as spline control points, not as a polyline to follow.
private func deviation(of path: PKStrokePath, from polyline: [CGPoint]) -> Double {
    let drawn = path.interpolatedPoints(by: .distance(0.5)).map(\.location)
    func distance(_ p: CGPoint, to line: [CGPoint]) -> Double {
        guard line.count > 1 else { return line.first.map { hypot(p.x - $0.x, p.y - $0.y) } ?? 0 }
        var best = Double.infinity
        for (a, b) in zip(line, line.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let t = dx == 0 && dy == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
            best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
        }
        return best
    }
    let away = drawn.map { distance($0, to: polyline) }.max() ?? 0
    let missed = polyline.map { distance($0, to: drawn) }.max() ?? 0
    return max(away, missed)
}

// MARK: - Geometry

/// x' = a*x + c*y + tx; y' = b*x + d*y + ty
private struct Matrix {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0

    /// Applies `n`, then self.
    func then(_ n: Matrix) -> Matrix {
        Matrix(a: a * n.a + c * n.b, b: b * n.a + d * n.b, c: a * n.c + c * n.d,
               d: b * n.c + d * n.d, tx: a * n.tx + c * n.ty + tx, ty: b * n.tx + d * n.ty + ty)
    }

    func apply(_ p: CGPoint) -> CGPoint { CGPoint(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty) }
    var scale: Double { sqrt(abs(a * d - b * c)) }
}

private func numbers(_ s: String?) -> [Double] {
    let scanner = Scanner(string: s ?? "")
    scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\t\n\r")
    var out: [Double] = []
    while !scanner.isAtEnd {
        if let v = scanner.scanDouble() { out.append(v) } else { scanner.currentIndex = scanner.string.index(after: scanner.currentIndex) }
    }
    return out
}

private func parseTransform(_ t: String?) -> Matrix {
    var m = Matrix()
    guard let t, !t.isEmpty else { return m }
    let re = try! NSRegularExpression(pattern: "(matrix|translate|scale|rotate)\\s*\\(([^)]*)\\)")
    let ns = t as NSString
    for match in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
        let fn = ns.substring(with: match.range(at: 1))
        let v = numbers(ns.substring(with: match.range(at: 2)))
        var n = Matrix()
        switch fn {
        case "matrix" where v.count == 6: n = Matrix(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        case "translate" where !v.isEmpty: n.tx = v[0]; n.ty = v.count > 1 ? v[1] : 0
        case "scale" where !v.isEmpty: n.a = v[0]; n.d = v.count > 1 ? v[1] : v[0]
        case "rotate" where !v.isEmpty:
            let r = v[0] * .pi / 180, cx = v.count > 2 ? v[1] : 0, cy = v.count > 2 ? v[2] : 0
            let rotation = Matrix(a: cos(r), b: sin(r), c: -sin(r), d: cos(r))
            n = Matrix(tx: cx, ty: cy).then(rotation).then(Matrix(tx: -cx, ty: -cy))
        default: break
        }
        m = m.then(n)
    }
    return m
}

// MARK: - Colors

private func parseColor(_ text: String) -> NSColor? {
    let s = text.trimmingCharacters(in: .whitespaces).lowercased()
    if s.isEmpty || s == "none" || s == "transparent" { return nil }
    if s.hasPrefix("#") {
        var hex = String(s.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return .black }
        return NSColor(srgbRed: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, alpha: 1)
    }
    if s.hasPrefix("rgb"), let open = s.firstIndex(of: "(") {
        let v = numbers(String(s[s.index(after: open)...]))
        if v.count >= 3 { return NSColor(srgbRed: v[0] / 255, green: v[1] / 255, blue: v[2] / 255, alpha: 1) }
    }
    let named = ["black": "#000000", "white": "#ffffff", "red": "#ff0000", "green": "#008000", "blue": "#0000ff",
                 "yellow": "#ffff00", "orange": "#ffa500", "purple": "#800080", "gray": "#808080", "grey": "#808080",
                 "pink": "#ffc0cb", "brown": "#a52a2a", "navy": "#000080", "teal": "#008080", "currentcolor": "#000000"]
    return named[s].flatMap(parseColor) ?? .black
}

// MARK: - Paths

/// Collects subpaths of sampled points in SVG user space.
private final class PathBuilder {
    var subpaths: [[CGPoint]] = []
    private var current = CGPoint.zero, start = CGPoint.zero, lastControl = CGPoint.zero
    private var lastCommand: Character?

    func move(to p: CGPoint) { subpaths.append([p]); current = p; start = p }

    func line(to p: CGPoint) {
        if subpaths.isEmpty { move(to: current) }
        subpaths[subpaths.count - 1].append(p)
        current = p
    }

    func cubic(_ c1: CGPoint, _ c2: CGPoint, to p: CGPoint) {
        let p0 = current
        let length = hypot(c1.x - p0.x, c1.y - p0.y) + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(p.x - c2.x, p.y - c2.y)
        let n = max(4, min(64, Int(length / 2)))
        for i in 1...n {
            let t = Double(i) / Double(n), u = 1 - t
            line(to: CGPoint(x: u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p.x,
                             y: u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p.y))
        }
    }

    func quad(_ c: CGPoint, to p: CGPoint) {
        let p0 = current
        cubic(CGPoint(x: p0.x + 2.0 / 3 * (c.x - p0.x), y: p0.y + 2.0 / 3 * (c.y - p0.y)),
              CGPoint(x: p.x + 2.0 / 3 * (c.x - p.x), y: p.y + 2.0 / 3 * (c.y - p.y)), to: p)
    }

    /// SVG elliptical arc, endpoint parameterization (SVG 1.1 appendix F.6.5).
    func arc(rx rx0: Double, ry ry0: Double, rotation degrees: Double, large: Bool, sweep: Bool, to p: CGPoint) {
        let p0 = current
        if rx0 == 0 || ry0 == 0 { line(to: p); return }
        var rx = abs(rx0), ry = abs(ry0)
        let phi = degrees * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p.x) / 2, dy = (p0.y - p.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1, den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let k = (large == sweep ? -1.0 : 1.0) * sqrt(max(0, num / den))
        let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
        let cx = cp * cx1 - sp * cy1 + (p0.x + p.x) / 2, cy = sp * cx1 + cp * cy1 + (p0.y + p.y) / 2
        let theta1 = atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
        var delta = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - theta1
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let n = max(8, min(96, Int(abs(delta) * max(rx, ry) / 2)))
        for i in 1...n {
            let t = theta1 + delta * Double(i) / Double(n)
            line(to: CGPoint(x: cx + rx * cos(t) * cp - ry * sin(t) * sp, y: cy + rx * cos(t) * sp + ry * sin(t) * cp))
        }
    }

    func close() { if !subpaths.isEmpty { line(to: start) } }

    func parse(_ d: String) {
        let scanner = Scanner(string: d)
        let commandSet = CharacterSet(charactersIn: "MmLlHhVvCcSsQqTtAaZz")
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\t\n\r")
        var cmd: Character = "M"
        while !scanner.isAtEnd {
            if let letters = scanner.scanCharacters(from: commandSet) {
                for letter in letters {  // several letters in a row: only Z/z make sense
                    cmd = letter
                    if cmd == "Z" || cmd == "z" { close(); lastCommand = cmd }
                }
                if cmd == "Z" || cmd == "z" { continue }
            }
            let need = "MmLlTt".contains(cmd) ? 2 : "HhVv".contains(cmd) ? 1 : "Cc".contains(cmd) ? 6 : "SsQq".contains(cmd) ? 4 : 7
            var v: [Double] = []
            while v.count < need, let n = scanner.scanDouble() { v.append(n) }
            if v.count < need {
                if !scanner.isAtEnd { scanner.currentIndex = scanner.string.index(after: scanner.currentIndex) }
                continue
            }
            let relative = cmd.isLowercase
            let ox = relative ? current.x : 0, oy = relative ? current.y : 0
            let previous = lastCommand.map(String.init) ?? ""
            let reflected = "CcSsQqTt".contains(previous) && !previous.isEmpty
                ? CGPoint(x: 2 * current.x - lastControl.x, y: 2 * current.y - lastControl.y) : current
            switch cmd {
            case "M", "m": move(to: CGPoint(x: ox + v[0], y: oy + v[1])); cmd = relative ? "l" : "L"
            case "L", "l": line(to: CGPoint(x: ox + v[0], y: oy + v[1]))
            case "H", "h": line(to: CGPoint(x: ox + v[0], y: current.y))
            case "V", "v": line(to: CGPoint(x: current.x, y: oy + v[0]))
            case "C", "c":
                lastControl = CGPoint(x: ox + v[2], y: oy + v[3])
                cubic(CGPoint(x: ox + v[0], y: oy + v[1]), lastControl, to: CGPoint(x: ox + v[4], y: oy + v[5]))
            case "S", "s":
                let first = "CcSs".contains(previous) && !previous.isEmpty ? reflected : current
                lastControl = CGPoint(x: ox + v[0], y: oy + v[1])
                cubic(first, lastControl, to: CGPoint(x: ox + v[2], y: oy + v[3]))
            case "Q", "q":
                lastControl = CGPoint(x: ox + v[0], y: oy + v[1])
                quad(lastControl, to: CGPoint(x: ox + v[2], y: oy + v[3]))
            case "T", "t":
                lastControl = "QqTt".contains(previous) && !previous.isEmpty ? reflected : current
                quad(lastControl, to: CGPoint(x: ox + v[0], y: oy + v[1]))
            case "A", "a":
                arc(rx: v[0], ry: v[1], rotation: v[2], large: v[3] != 0, sweep: v[4] != 0, to: CGPoint(x: ox + v[5], y: oy + v[6]))
            default: break
            }
            lastCommand = cmd
        }
    }
}

// MARK: - Document

private struct Shape {
    let points: [CGPoint]
    let color: NSColor
    let width: Double
    /// An outline of a text glyph.
    var isText = false
}

private let textProperties = ["font-size", "font-family", "font-weight", "text-anchor", "dominant-baseline"]

private final class SVGReader: NSObject, XMLParserDelegate {
    var shapes: [Shape] = []
    var viewBox: CGRect?
    private(set) var textCount = 0
    private(set) var glyphCount = 0

    /// Inherited state: transform, stroke, fill, stroke width, text properties.
    private struct Context { var matrix: Matrix; var stroke: String; var fill: String; var width: Double; var text: [String: String] = [:] }
    private var stack = [Context(matrix: Matrix(), stroke: "none", fill: "black", width: 1)]
    /// The <text> being read: its attributes, context and characters (from it and its <tspan>s).
    private var pendingText: (attributes: [String: String], context: Context, content: String)?

    private func styleAttributes(_ attrs: [String: String]) -> [String: String] {
        var s = attrs.filter { (["stroke", "fill", "stroke-width"] + textProperties).contains($0.key) }
        for declaration in (attrs["style"] ?? "").split(separator: ";") {
            let kv = declaration.split(separator: ":", omittingEmptySubsequences: false)
            if kv.count == 2 { s[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces) }
        }
        return s
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        let parent = stack.last!
        let st = styleAttributes(a)
        var ctx = Context(matrix: parent.matrix.then(parseTransform(a["transform"])), stroke: st["stroke"] ?? parent.stroke,
                          fill: st["fill"] ?? parent.fill, width: st["stroke-width"].map { ($0 as NSString).doubleValue } ?? parent.width,
                          text: parent.text)
        for key in textProperties { if let v = st[key] { ctx.text[key] = v } }
        stack.append(ctx)

        if name == "text" { pendingText = (a, ctx, ""); return }
        if name == "tspan" { return }  // its characters belong to the enclosing <text>
        if name == "svg" {
            let vb = numbers(a["viewBox"])
            if vb.count == 4 { viewBox = CGRect(x: vb[0], y: vb[1], width: vb[2], height: vb[3]) }
            else if let w = a["width"], let h = a["height"] {
                viewBox = CGRect(x: 0, y: 0, width: (w as NSString).doubleValue, height: (h as NSString).doubleValue)
            }
            return
        }
        let b = PathBuilder()
        // Like -[NSString doubleValue]: "3px" reads as 3.
        func num(_ k: String) -> Double { ((a[k] ?? "") as NSString).doubleValue }
        switch name {
        case "path": b.parse(a["d"] ?? "")
        case "line": b.move(to: CGPoint(x: num("x1"), y: num("y1"))); b.line(to: CGPoint(x: num("x2"), y: num("y2")))
        case "polyline", "polygon":
            let v = numbers(a["points"])
            for i in stride(from: 0, to: v.count - 1, by: 2) {
                let p = CGPoint(x: v[i], y: v[i + 1])
                if i == 0 { b.move(to: p) } else { b.line(to: p) }
            }
            if name == "polygon" { b.close() }
        case "rect":
            let x = num("x"), y = num("y"), w = num("width"), h = num("height")
            // Rounded corners: rx and ry default to each other, and are capped at half the side.
            var rx = a["rx"] != nil ? num("rx") : num("ry"), ry = a["ry"] != nil ? num("ry") : rx
            rx = min(max(rx, 0), w / 2); ry = min(max(ry, 0), h / 2)
            if rx > 0 && ry > 0 {
                func corner(_ to: CGPoint) { b.arc(rx: rx, ry: ry, rotation: 0, large: false, sweep: true, to: to) }
                b.move(to: CGPoint(x: x + rx, y: y))
                b.line(to: CGPoint(x: x + w - rx, y: y)); corner(CGPoint(x: x + w, y: y + ry))
                b.line(to: CGPoint(x: x + w, y: y + h - ry)); corner(CGPoint(x: x + w - rx, y: y + h))
                b.line(to: CGPoint(x: x + rx, y: y + h)); corner(CGPoint(x: x, y: y + h - ry))
                b.line(to: CGPoint(x: x, y: y + ry)); corner(CGPoint(x: x + rx, y: y))
            } else {
                b.move(to: CGPoint(x: x, y: y)); b.line(to: CGPoint(x: x + w, y: y)); b.line(to: CGPoint(x: x + w, y: y + h))
                b.line(to: CGPoint(x: x, y: y + h)); b.close()
            }
        case "circle", "ellipse":
            let cx = num("cx"), cy = num("cy")
            let rx = name == "circle" ? num("r") : num("rx"), ry = name == "circle" ? num("r") : num("ry")
            b.move(to: CGPoint(x: cx + rx, y: cy))
            b.arc(rx: rx, ry: ry, rotation: 0, large: false, sweep: true, to: CGPoint(x: cx - rx, y: cy))
            b.arc(rx: rx, ry: ry, rotation: 0, large: false, sweep: true, to: CGPoint(x: cx + rx, y: cy))
        default:
            return
        }
        guard let color = parseColor(ctx.stroke) ?? parseColor(ctx.fill) else { return }
        let stroked = parseColor(ctx.stroke) != nil
        let width = (stroked ? ctx.width : 1) * ctx.matrix.scale
        for sub in b.subpaths where sub.count >= 2 {
            shapes.append(Shape(points: sub.map(ctx.matrix.apply), color: color, width: max(width, 0.5)))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        pendingText?.content += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "text", let text = pendingText {
            addText(text.content, attributes: text.attributes, context: text.context)
            pendingText = nil
        }
        if stack.count > 1 { stack.removeLast() }
    }

    /// Text as glyph outlines: CoreText lays the line out (falling back to other fonts, such
    /// as PingFang for Chinese, as needed), and each glyph's outline becomes strokes. PencilKit
    /// cannot fill, so text is drawn hollow, in its fill color.
    private func addText(_ raw: String, attributes a: [String: String], context ctx: Context) {
        let content = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !content.isEmpty else { return }
        let props = ctx.text
        let size = props["font-size"].map { ($0 as NSString).doubleValue }.flatMap { $0 > 0 ? $0 : nil } ?? 16
        let family = (props["font-family"] ?? "").split(separator: ",").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) ?? ""
        let generic: Set<String> = ["", "sans-serif", "serif", "system-ui", "-apple-system", "BlinkMacSystemFont", "monospace"]
        var font: CTFont = generic.contains(family)
            ? (family == "monospace" ? CTFontCreateWithName("Menlo" as CFString, size, nil)
                                     : CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil))
            : CTFontCreateWithName(family as CFString, size, nil)
        let weight = props["font-weight"] ?? ""
        if weight == "bold" || (Int(weight) ?? 0) >= 600,
           let bold = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) {
            font = bold
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: content, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        var x = ((a["x"] ?? "") as NSString).doubleValue, y = ((a["y"] ?? "") as NSString).doubleValue
        switch props["text-anchor"] {
        case "middle": x -= lineWidth / 2
        case "end": x -= lineWidth
        default: break
        }
        switch props["dominant-baseline"] {
        case "middle", "central": y += (ascent - descent) / 2
        case "hanging", "text-before-edge": y += ascent
        default: break
        }
        let b = PathBuilder()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let outline = CTFontCreatePathForGlyph(runFont, glyph, nil), !outline.isEmpty else { continue }  // spaces
                glyphCount += 1
                // Glyph space is y-up from the baseline; SVG is y-down.
                func point(_ q: CGPoint) -> CGPoint { CGPoint(x: x + position.x + q.x, y: y - position.y - q.y) }
                outline.applyWithBlock { element in
                    let e = element.pointee
                    switch e.type {
                    case .moveToPoint: b.move(to: point(e.points[0]))
                    case .addLineToPoint: b.line(to: point(e.points[0]))
                    case .addQuadCurveToPoint: b.quad(point(e.points[0]), to: point(e.points[1]))
                    case .addCurveToPoint: b.cubic(point(e.points[0]), point(e.points[1]), to: point(e.points[2]))
                    case .closeSubpath: b.close()
                    @unknown default: break
                    }
                }
            }
        }
        textCount += 1
        let color = parseColor(ctx.fill) ?? parseColor(ctx.stroke) ?? .black
        let width = (parseColor(ctx.stroke) != nil ? ctx.width : size * 0.045) * ctx.matrix.scale
        for sub in b.subpaths where sub.count >= 2 {
            shapes.append(Shape(points: sub.map(ctx.matrix.apply), color: color, width: width, isText: true))
        }
    }
}
