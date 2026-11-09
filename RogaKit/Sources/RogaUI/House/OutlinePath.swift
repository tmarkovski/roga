import SwiftUI

/// Reads an outline from the path data of one of the files in
/// docs/design/branding, which only use M, L, C and Z, with a space between
/// every letter and number.
nonisolated enum OutlinePath {
    /// - Parameter offset: How far to move the outline, for a file that
    ///   places its paths with a `translate`.
    static func path(from data: String, offset: CGVector = .zero) -> Path {
        var path = Path()
        let words = data.split(whereSeparator: \.isWhitespace)
        var index = words.startIndex
        func point() -> CGPoint {
            defer { index += 2 }
            return CGPoint(x: Double(words[index])! + offset.dx, y: Double(words[index + 1])! + offset.dy)
        }
        // Each of these commands is followed by as many points as it has room
        // for, because the files leave out letters that repeat.
        var command = "M"
        while index < words.endIndex {
            if let first = words[index].first, first.isLetter {
                command = String(words[index])
                index += 1
                if command == "Z" {
                    path.closeSubpath()
                    continue
                }
            }
            switch command {
            case "M":
                path.move(to: point())
                command = "L"
            case "L":
                path.addLine(to: point())
            case "C":
                let control1 = point()
                let control2 = point()
                path.addCurve(to: point(), control1: control1, control2: control2)
            default:
                preconditionFailure("The outlines only use M, L, C and Z.")
            }
        }
        return path
    }
}
