import AppKit
import Observation
import Synchronization

/// The font code shows in, and its size, chosen in Settings › Appearance
/// (decision 73): a diff's lines, a conflicted file's, and the box a conflict is
/// edited in. Names that are typed elsewhere, such as a commit's ID or a
/// command, keep the system's monospaced font at the size their place was
/// drawn for.
public struct CodeFont: Hashable, Sendable {
    /// The family's name, such as Menlo, or nil for the system's monospaced font.
    public var family: String?
    /// In points.
    public var size: Double

    public static let familyKey = "codeFontFamily"
    public static let sizeKey = "codeFontSize"

    /// What the system's monospaced font is called, which is its name in the
    /// Mac's own apps.
    public static let systemFamilyTitle = "SF Mono"
    public static let defaultSize = 12.0
    /// The sizes Settings offers.
    public static let sizes: [Double] = [11, 12, 13, 14, 15, 16, 18, 20]

    /// The system's monospaced font at 12 points, which is what diffs were
    /// drawn in before there was a choice.
    public static let standard = CodeFont()

    public init(family: String? = nil, size: Double = CodeFont.defaultSize) {
        self.family = family
        self.size = size
    }

    // MARK: The fonts

    /// The font for code, or the heavier one for a heading among it, such as
    /// the name of a conflict's side. A family that isn't installed any more
    /// gives the system's font, and one with no bold face gives its regular one.
    public func font(isBold: Bool = false) -> NSFont {
        let size = CGFloat(size)
        if let family, let faces = Self.faces(of: family), let font = NSFont(name: isBold ? faces.bold : faces.regular, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: isBold ? .semibold : .regular)
    }

    private struct Faces: Sendable {
        var regular: String
        var bold: String
    }

    /// The faces found for each family that's been asked for, or nil for one
    /// that isn't installed. A diff's text is built away from the main actor,
    /// and the font manager is only asked from one thread at a time.
    private static let knownFaces = Mutex<[String: Faces?]>([:])

    private static func faces(of family: String) -> Faces? {
        knownFaces.withLock { known in
            if let faces = known[family] { return faces }
            let manager = NSFontManager.shared
            // Weight 5 is the regular face, which a family's first face isn't
            // always: some start with their thinnest.
            let regular = manager.font(withFamily: family, traits: [], weight: 5, size: 12)
            let faces = regular.map { regular in
                let bold = manager.font(withFamily: family, traits: .boldFontMask, weight: 5, size: 12) ?? regular
                return Faces(regular: regular.fontName, bold: bold.fontName)
            }
            known[family] = .some(faces)
            return faces
        }
    }

    /// Whether a family is installed with a face to draw code in.
    public static func isInstalled(_ family: String) -> Bool {
        faces(of: family) != nil
    }

    /// The families Settings offers besides the system's: each installed one
    /// with a face whose characters are all one width, by name. The system's
    /// own font is left out where it's installed as a family too.
    @MainActor public static func installedFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard family != systemFamilyTitle, !family.hasPrefix("."), let members = manager.availableMembers(ofFontFamily: family) else { return false }
            // Each member is a face: its name, its style, its weight and its traits.
            return members.contains { member in
                guard member.count > 3, let traits = member[3] as? UInt else { return false }
                return NSFontTraitMask(rawValue: traits).contains(.fixedPitchFontMask)
            }
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: The font in use

    private static let chosen = Mutex(CodeFont.standard)

    /// The font in use. Anything can read it, because a diff's text is built
    /// away from the main actor.
    public static var current: CodeFont {
        chosen.withLock { $0 }
    }

    /// The font in use, for SwiftUI: a view whose body reads it draws again
    /// when it changes.
    @MainActor public static var observed: CodeFont {
        ThemeObservation.shared.codeFont
    }

    /// The font `defaults` has: the system's when it has no family or one that
    /// isn't installed, and 12 points when it has no size. A size from outside
    /// Settings is kept within the sizes it offers.
    public static func stored(in defaults: UserDefaults = .standard) -> CodeFont {
        var font = CodeFont.standard
        if let family = defaults.string(forKey: familyKey), !family.isEmpty, isInstalled(family) {
            font.family = family
        }
        if let size = defaults.object(forKey: sizeKey) as? Double {
            font.size = usable(size: size)
        }
        return font
    }

    /// A size as Roga uses it: a whole number of points, no smaller or larger
    /// than the sizes Settings offers.
    public static func usable(size: Double) -> Double {
        guard let smallest = sizes.first, let largest = sizes.last else { return defaultSize }
        return min(max(size.rounded(), smallest), largest)
    }

    /// Makes this the font in use. What shows code builds it again in the new
    /// font, which it finds out about from `observed`.
    @MainActor public func use() {
        guard Self.chosen.withLock({ font in
            defer { font = self }
            return font != self
        }) else { return }
        ThemeObservation.shared.codeFont = self
    }

    /// Uses the font in user defaults. The app does this as it starts, before
    /// its first window shows.
    @MainActor public static func useStored() {
        stored().use()
    }
}
