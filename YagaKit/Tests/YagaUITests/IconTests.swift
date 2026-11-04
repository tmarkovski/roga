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
        let widths = Icon.allCases.compactMap { symbol($0, size: 13)?.size.width }
        #expect(widths.count == Icon.allCases.count)
        let narrowest = try #require(widths.min())
        let widest = try #require(widths.max())
        #expect(widest - narrowest <= 1)
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
