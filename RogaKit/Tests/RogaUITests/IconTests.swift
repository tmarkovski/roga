import AppKit
import IconUI
import Testing

/// The icons in the asset catalog: that each one loads from the package's bundle,
/// and that it responds to a size and a weight as an SF Symbol does.
@Suite(.timeLimit(.minutes(1)))
struct IconTests {
    private func symbol(_ icon: Icon, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        icon.nsImage?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    /// How much of a bitmap the symbol covers, adding up each pixel's opacity.
    private func ink(_ image: NSImage?) -> Int {
        guard let image else { return 0 }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        )!
        bitmap.size = NSSize(width: 32, height: 32)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let bytes = UnsafeBufferPointer(start: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) }
    }

    @Test func everyIconLoadsAndDrawsSomething() {
        for icon in Icon.allCases {
            #expect(ink(symbol(icon, size: 16)) > 0, "\(icon.rawValue) drew nothing")
        }
    }

    @Test func everyIconIsAboutTheSameWidthSoThatAColumnOfThemLinesUp() throws {
        // They all have the grid's width, which the system rounds to a whole point.
        var icons: [CGFloat: [String]] = [:]
        for icon in Icon.allCases {
            let width = try #require(symbol(icon, size: 13)?.size.width, "\(icon.rawValue) didn't load")
            icons[width, default: []].append(icon.rawValue)
        }
        let narrowest = try #require(icons.keys.min())
        let widest = try #require(icons.keys.max())
        // On a display at 2x they come out 15 or 16 points wide. At 1x, which
        // is what a CI runner has, they come out 14, 15 or 16. A failure names
        // some icons of each width.
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        let found = icons.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.prefix(6).joined(separator: ", "))" }
            .joined(separator: "; ")
        #expect(widest - narrowest <= (scale < 2 ? 2 : 1), "\(found), on a display at \(scale)x")
    }

    @Test func aLargerPointSizeDrawsALargerIcon() throws {
        let small = try #require(symbol(.branch, size: 9))
        let large = try #require(symbol(.branch, size: 16))
        #expect(large.size.width > small.size.width)
    }

    @Test func aHeavierWeightDrawsMoreOfTheIcon() {
        let light = ink(symbol(.branch, size: 16, weight: .light))
        let regular = ink(symbol(.branch, size: 16, weight: .regular))
        let bold = ink(symbol(.branch, size: 16, weight: .bold))
        #expect(light < regular)
        #expect(regular < bold)
    }

    /// One icon family only looks like one if nothing slips in from another.
    @Test func theAppDrawsNoSFSymbols() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let folders = [package.appendingPathComponent("Sources"), package.deletingLastPathComponent().appendingPathComponent("App")]
        var checked = 0
        for folder in folders {
            let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                checked += 1
                for call in ["systemName:", "systemImage:", "systemSymbolName:"] {
                    #expect(!source.contains(call), "\(file.lastPathComponent) uses \(call)")
                }
            }
        }
        #expect(checked > 50)
    }
}
