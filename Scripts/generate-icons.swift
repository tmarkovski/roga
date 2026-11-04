#!/usr/bin/env swift
// Turns the icons in docs/design/icons into custom SF Symbols (decision 24). An
// icon there is a 24-by-24 SVG drawn with strokes, and a symbol has to be filled
// outlines, so this draws each stroke's outline at three weights and three sizes,
// from which the system works out the weights between them. It writes the asset
// catalog and the enum that names its icons into RogaKit/Sources/IconUI.
//
// Usage: Scripts/generate-icons.swift
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: #filePath).standardized.deletingLastPathComponent().deletingLastPathComponent()
let sources = root.appendingPathComponent("docs/design/icons")
let target = root.appendingPathComponent("RogaKit/Sources/IconUI")

/// The sizes a symbol's template has: where each one's baseline is, and how many
/// of the template's units one unit of an icon's grid takes up. A template's capital
/// letters are 70.459 units tall, so at the medium size an icon's grid is 113 units,
/// which draws it about as large as the SF Symbols beside it.
let sizes: [(name: String, baseline: Double, scale: Double)] = [
    ("S", 696, 3.68),
    ("M", 1126, 4.7),
    ("L", 1556, 6.06),
]
/// The weights a template has: where each one's column starts, and how wide its
/// strokes are on an icon's grid. Regular comes to about 1.4 points at a 16-point size.
let weights: [(name: String, column: Double, strokeWidth: Double)] = [
    ("Ultralight", 300, 0.65),
    ("Regular", 1300, 1.86),
    ("Black", 2300, 3.1),
]
let capHeight = 70.459
let gridSize = 24.0

typealias Element = (name: String, attributes: [String: String])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

// MARK: Reading an icon

/// What an icon's elements are, in the order the file has them.
final class IconReader: NSObject, XMLParserDelegate {
    var elements: [Element] = []
    var viewBox: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "svg" {
            viewBox = attributes["viewBox"]
        } else {
            elements.append((name, attributes))
        }
    }
}

func read(_ file: URL) -> [Element] {
    guard let parser = XMLParser(contentsOf: file) else { fail("Can't read \(file.path).") }
    let reader = IconReader()
    parser.delegate = reader
    guard parser.parse() else { fail("Can't parse \(file.path): \(parser.parserError.map(String.init(describing:)) ?? "")") }
    guard reader.viewBox == "0 0 24 24" else { fail("\(file.path) isn't on a 24-by-24 grid.") }
    return reader.elements
}

// MARK: Geometry

/// How far along its edge a cubic curve's control point sits to draw a quarter circle.
let kappa = 0.5522847498

func addOval(to path: CGMutablePath, x: Double, y: Double, radiusX: Double, radiusY: Double) {
    let controlX = radiusX * kappa, controlY = radiusY * kappa
    path.move(to: CGPoint(x: x, y: y - radiusY))
    path.addCurve(to: CGPoint(x: x + radiusX, y: y), control1: CGPoint(x: x + controlX, y: y - radiusY), control2: CGPoint(x: x + radiusX, y: y - controlY))
    path.addCurve(to: CGPoint(x: x, y: y + radiusY), control1: CGPoint(x: x + radiusX, y: y + controlY), control2: CGPoint(x: x + controlX, y: y + radiusY))
    path.addCurve(to: CGPoint(x: x - radiusX, y: y), control1: CGPoint(x: x - controlX, y: y + radiusY), control2: CGPoint(x: x - radiusX, y: y + controlY))
    path.addCurve(to: CGPoint(x: x, y: y - radiusY), control1: CGPoint(x: x - radiusX, y: y - controlY), control2: CGPoint(x: x - controlX, y: y - radiusY))
    path.closeSubpath()
}

/// Adds SVG's elliptical arc as cubic curves of at most 90 degrees, by way of the
/// conversion from endpoints to a center in the SVG specification.
func addArc(to path: CGMutablePath, from start: CGPoint, radiusX: Double, radiusY: Double, rotation: Double, isLarge: Bool, isSweep: Bool, to end: CGPoint) {
    var radiusX = abs(radiusX), radiusY = abs(radiusY)
    guard start != end else { return }
    guard radiusX > 0, radiusY > 0 else {
        path.addLine(to: end)
        return
    }
    let angle = rotation * .pi / 180
    let cosine = cos(angle), sine = sin(angle)
    let halfX = (start.x - end.x) / 2, halfY = (start.y - end.y) / 2
    let x1 = cosine * halfX + sine * halfY, y1 = -sine * halfX + cosine * halfY
    let excess = x1 * x1 / (radiusX * radiusX) + y1 * y1 / (radiusY * radiusY)
    if excess > 1 {
        radiusX *= excess.squareRoot()
        radiusY *= excess.squareRoot()
    }
    let squaredX = radiusX * radiusX, squaredY = radiusY * radiusY
    let numerator = max(0, squaredX * squaredY - squaredX * y1 * y1 - squaredY * x1 * x1)
    let factor = (isLarge == isSweep ? -1.0 : 1.0) * (numerator / (squaredX * y1 * y1 + squaredY * x1 * x1)).squareRoot()
    let centerPrimeX = factor * radiusX * y1 / radiusY, centerPrimeY = -factor * radiusY * x1 / radiusX
    let centerX = cosine * centerPrimeX - sine * centerPrimeY + (start.x + end.x) / 2
    let centerY = sine * centerPrimeX + cosine * centerPrimeY + (start.y + end.y) / 2
    let firstAngle = atan2((y1 - centerPrimeY) / radiusY, (x1 - centerPrimeX) / radiusX)
    var sweep = atan2((-y1 - centerPrimeY) / radiusY, (-x1 - centerPrimeX) / radiusX) - firstAngle
    if !isSweep && sweep > 0 { sweep -= 2 * .pi } else if isSweep && sweep < 0 { sweep += 2 * .pi }
    let pieces = max(1, Int((abs(sweep) / (.pi / 2) - 1e-9).rounded(.up)))
    let step = sweep / Double(pieces)
    let control = 4.0 / 3.0 * tan(step / 4)
    func point(_ unitX: Double, _ unitY: Double) -> CGPoint {
        CGPoint(x: cosine * radiusX * unitX - sine * radiusY * unitY + centerX, y: sine * radiusX * unitX + cosine * radiusY * unitY + centerY)
    }
    var current = firstAngle
    for piece in 0..<pieces {
        let next = current + step
        path.addCurve(
            to: piece == pieces - 1 ? end : point(cos(next), sin(next)),
            control1: point(cos(current) - control * sin(current), sin(current) + control * cos(current)),
            control2: point(cos(next) + control * sin(next), sin(next) - control * cos(next))
        )
        current = next
    }
}

/// Adds an SVG path's `d` attribute.
func addPathData(to path: CGMutablePath, _ data: String, in file: String) {
    let bytes = Array(data.utf8)
    var index = 0
    func skipSeparators() {
        while index < bytes.count, [32, 44, 9, 10, 13].contains(bytes[index]) { index += 1 }
    }
    func number() -> Double {
        skipSeparators()
        let start = index
        if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
        var hasPoint = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= 48 && byte <= 57 {
                index += 1
            } else if byte == 46 && !hasPoint {
                hasPoint = true
                index += 1
            } else {
                break
            }
        }
        guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else { fail("\(file) has a path that can't be read: \(data)") }
        return value
    }
    // An arc's two flags can run together with what follows them, as in `a1 1 0 01.5.5`.
    func flag() -> Bool {
        skipSeparators()
        defer { index += 1 }
        return bytes[index] == 49
    }
    var current = CGPoint.zero, subpathStart = CGPoint.zero
    var lastCubicControl: CGPoint?, lastQuadraticControl: CGPoint?
    var command: UInt8 = 0
    while true {
        skipSeparators()
        guard index < bytes.count else { break }
        if (bytes[index] >= 65 && bytes[index] <= 90) || (bytes[index] >= 97 && bytes[index] <= 122) {
            command = bytes[index]
            index += 1
        }
        let isRelative = command >= 97
        let letter = Character(UnicodeScalar(isRelative ? command - 32 : command))
        func x() -> Double { (isRelative ? current.x : 0) + number() }
        func y() -> Double { (isRelative ? current.y : 0) + number() }
        func xy() -> CGPoint {
            let pointX = x()
            return CGPoint(x: pointX, y: y())
        }
        var cubicControl: CGPoint?, quadraticControl: CGPoint?
        switch letter {
        case "M":
            current = xy()
            subpathStart = current
            path.move(to: current)
            // Pairs after a move's first one are lines.
            command = isRelative ? 108 : 76
        case "L":
            current = xy()
            path.addLine(to: current)
        case "H":
            current.x = x()
            path.addLine(to: current)
        case "V":
            current.y = y()
            path.addLine(to: current)
        case "C", "S":
            let first = letter == "C" ? xy() : lastCubicControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
            let second = xy(), end = xy()
            path.addCurve(to: end, control1: first, control2: second)
            cubicControl = second
            current = end
        case "Q", "T":
            let control = letter == "Q" ? xy() : lastQuadraticControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
            let end = xy()
            path.addQuadCurve(to: end, control: control)
            quadraticControl = control
            current = end
        case "A":
            let radiusX = number(), radiusY = number(), rotation = number()
            let isLarge = flag(), isSweep = flag()
            let end = xy()
            addArc(to: path, from: current, radiusX: radiusX, radiusY: radiusY, rotation: rotation, isLarge: isLarge, isSweep: isSweep, to: end)
            current = end
        case "Z":
            path.closeSubpath()
            current = subpathStart
        default:
            fail("\(file) has a path command this doesn't know: \(letter)")
        }
        lastCubicControl = cubicControl
        lastQuadraticControl = quadraticControl
    }
}

/// An icon's outline at a stroke width: what its strokes cover, plus the dots it fills.
func outline(of elements: [Element], strokeWidth: Double, in file: String) -> CGPath {
    func value(_ attributes: [String: String], _ key: String, default fallback: Double = 0) -> Double {
        attributes[key].flatMap(Double.init) ?? fallback
    }
    let strokes = CGMutablePath(), filled = CGMutablePath()
    for (name, attributes) in elements {
        if let fill = attributes["fill"] {
            // A filled circle with a stroke around it is a disk. Stroking and filling
            // it separately would leave a hole at the thinnest weight.
            guard name == "circle", fill == "currentColor" else { fail("\(file) fills a \(name), which this doesn't know how to draw.") }
            let radius = value(attributes, "r") + strokeWidth / 2
            addOval(to: filled, x: value(attributes, "cx"), y: value(attributes, "cy"), radiusX: radius, radiusY: radius)
            continue
        }
        if attributes["stroke"] != nil || attributes["stroke-width"] != nil || attributes["transform"] != nil {
            fail("\(file) has a \(name) with paint or a transform of its own, which this doesn't know how to draw.")
        }
        switch name {
        case "path":
            addPathData(to: strokes, attributes["d"] ?? "", in: file)
        case "circle":
            let radius = value(attributes, "r")
            addOval(to: strokes, x: value(attributes, "cx"), y: value(attributes, "cy"), radiusX: radius, radiusY: radius)
        case "ellipse":
            addOval(to: strokes, x: value(attributes, "cx"), y: value(attributes, "cy"), radiusX: value(attributes, "rx"), radiusY: value(attributes, "ry"))
        case "line":
            strokes.move(to: CGPoint(x: value(attributes, "x1"), y: value(attributes, "y1")))
            strokes.addLine(to: CGPoint(x: value(attributes, "x2"), y: value(attributes, "y2")))
        case "rect":
            let rect = CGRect(x: value(attributes, "x"), y: value(attributes, "y"), width: value(attributes, "width"), height: value(attributes, "height"))
            let radiusX = value(attributes, "rx", default: value(attributes, "ry")), radiusY = value(attributes, "ry", default: value(attributes, "rx"))
            strokes.addRoundedRect(in: rect, cornerWidth: min(radiusX, rect.width / 2), cornerHeight: min(radiusY, rect.height / 2))
        case "polyline", "polygon":
            let numbers = (attributes["points"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            let points = stride(from: 0, to: numbers.count - 1, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
            strokes.addLines(between: points)
            if name == "polygon" { strokes.closeSubpath() }
        default:
            fail("\(file) has a \(name), which this doesn't know how to draw.")
        }
    }
    let result = CGMutablePath()
    // Overlaps in this outline stay, since the system fills it with the nonzero rule.
    // Removing them would give each weight different points, which it can't blend.
    result.addPath(strokes.copy(strokingWithWidth: strokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 10))
    result.addPath(filled)
    return result
}

// MARK: Writing a symbol

func format(_ value: Double) -> String {
    var text = String(format: "%.2f", value)
    while text.contains("."), text.hasSuffix("0") || text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
}

func pathData(of path: CGPath) -> String {
    var data = ""
    path.applyWithBlock { pointer in
        let points = pointer.pointee.points
        func pair(_ index: Int) -> String { "\(format(points[index].x)) \(format(points[index].y))" }
        switch pointer.pointee.type {
        case .moveToPoint: data += "M\(pair(0))"
        case .addLineToPoint: data += "L\(pair(0))"
        case .addQuadCurveToPoint: data += "Q\(pair(0)) \(pair(1))"
        case .addCurveToPoint: data += "C\(pair(0)) \(pair(1)) \(pair(2))"
        case .closeSubpath: data += "Z"
        @unknown default: fail("A path has an element this doesn't know.")
        }
    }
    return data
}

/// The order of an outline's elements, which has to be the same at every weight for
/// the system to blend between them.
func structure(of path: CGPath) -> [Int32] {
    var types: [Int32] = []
    path.applyWithBlock { types.append($0.pointee.type.rawValue) }
    return types
}

let guideStyle = "style=\"fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;\""

/// The symbol, and whether its weights can blend.
func symbol(from elements: [Element], in file: String) -> (svg: String, canBlend: Bool) {
    var guides = "", glyphs = ""
    var structures = Set<[Int32]>()
    for size in sizes {
        guides += "<line id=\"Baseline-\(size.name)\" \(guideStyle) x1=\"263\" x2=\"3036\" y1=\"\(format(size.baseline))\" y2=\"\(format(size.baseline))\"/>\n"
        guides += "<line id=\"Capline-\(size.name)\" \(guideStyle) x1=\"263\" x2=\"3036\" y1=\"\(format(size.baseline - capHeight))\" y2=\"\(format(size.baseline - capHeight))\"/>\n"
        // Every icon is as wide as the grid, so that a column of them lines up, with
        // its center halfway up the capital letters of the text beside it.
        let width = gridSize * size.scale
        var placement = CGAffineTransform(a: size.scale, b: 0, c: 0, d: size.scale, tx: 0, ty: -capHeight / 2 - gridSize / 2 * size.scale)
        for weight in weights {
            guard let placed = outline(of: elements, strokeWidth: weight.strokeWidth, in: file).copy(using: &placement) else { fail("Can't place \(file).") }
            structures.insert(structure(of: placed))
            let right = weight.column + width
            guides += "<line id=\"left-margin-\(weight.name)-\(size.name)\" \(guideStyle) x1=\"\(format(weight.column))\" x2=\"\(format(weight.column))\" y1=\"\(format(size.baseline - 100))\" y2=\"\(format(size.baseline + 20))\"/>\n"
            guides += "<line id=\"right-margin-\(weight.name)-\(size.name)\" \(guideStyle) x1=\"\(format(right))\" x2=\"\(format(right))\" y1=\"\(format(size.baseline - 100))\" y2=\"\(format(size.baseline + 20))\"/>\n"
            glyphs += "<g id=\"\(weight.name)-\(size.name)\" transform=\"matrix(1 0 0 1 \(format(weight.column)) \(format(size.baseline)))\"><path d=\"\(pathData(of: placed))\"/></g>\n"
        }
    }
    let svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
    <g id="Notes"><text id="template-version" x="3036" y="100">Template v.3.0</text></g>
    <g id="Guides">
    \(guides)</g>
    <g id="Symbols">
    \(glyphs)</g>
    </svg>

    """
    return (svg, structures.count == 1)
}

// MARK: Writing the catalog and the enum

func write(_ text: String, to file: URL) throws {
    try text.write(to: file, atomically: true, encoding: .utf8)
}

/// `git-branch` becomes `gitBranch`.
func caseName(_ name: String) -> String {
    let words = name.split(separator: "-").map(String.init)
    return words[0] + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
}

let fileManager = FileManager.default
var files: [String: URL] = [:]
for folder in ["lucide", "roga"] {
    let url = sources.appendingPathComponent(folder)
    for file in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) where file.pathExtension == "svg" {
        let name = file.deletingPathExtension().lastPathComponent
        if files[name] != nil { fail("Two icons are named \(name).") }
        files[name] = file
    }
}
let names = files.keys.sorted()

let catalog = target.appendingPathComponent("Icons.xcassets")
if fileManager.fileExists(atPath: catalog.path) { try fileManager.removeItem(at: catalog) }
try fileManager.createDirectory(at: catalog, withIntermediateDirectories: true)
try write("{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n", to: catalog.appendingPathComponent("Contents.json"))

var fixedWeights: [String] = []
for name in names {
    let (svg, canBlend) = symbol(from: read(files[name]!), in: "\(name).svg")
    if !canBlend { fixedWeights.append(name) }
    let folder = catalog.appendingPathComponent("\(name).symbolset")
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    try write(svg, to: folder.appendingPathComponent("\(name).svg"))
    try write("{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  },\n  \"symbols\" : [\n    {\n      \"filename\" : \"\(name).svg\",\n      \"idiom\" : \"universal\"\n    }\n  ]\n}\n", to: folder.appendingPathComponent("Contents.json"))
}

let cases = names.map { "    case \(caseName($0)) = \"\($0)\"" }.joined(separator: "\n")
try write("""
// Generated by Scripts/generate-icons.swift from the files in docs/design/icons.
// To add an icon, add its file there and run the script again.

/// Every icon in the catalog, named after its file. Icon.swift has the names to use
/// for icons that stand for something in Roga, such as `Icon.worktree`.
public enum Icon: String, CaseIterable, Sendable {
\(cases)
}

""", to: target.appendingPathComponent("GeneratedIcons.swift"))

print("Wrote \(names.count) icons to \(catalog.path).")
if !fixedWeights.isEmpty {
    print("These stay at one weight from light to bold, because their outlines differ between weights: \(fixedWeights.joined(separator: ", "))")
}
