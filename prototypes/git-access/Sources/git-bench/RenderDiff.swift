import AppKit
import ArgumentParser

enum DiffViewKind: String, ExpressibleByArgument, CaseIterable {
    case table
    case text
    case textkit1
}

struct DiffRender: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff-render",
        abstract: "Open a window that shows a diff and measure how smoothly it scrolls."
    )

    @OptionGroup var common: CommonOptions

    @Option(help: "Which view draws the diff.")
    var engine: DiffViewKind = .table

    @Option(help: "The older revision.")
    var from: String = "v6.0"

    @Option(help: "The newer revision.")
    var to: String = "v6.1"

    @Flag(help: "In the text views, leave out line and word backgrounds.")
    var plain = false

    @Flag(help: "In the text views, wrap long lines instead of scrolling sideways.")
    var wrap = false

    @Option(help: "Show only this file's patch.")
    var path: String?

    @Option(help: "Steady scrolling speed, in points per second.")
    var speed: Double = 6000

    @Option(help: "How long to scroll steadily, in seconds.")
    var seconds: Double = 5

    @Option(help: "How many jumps to random positions to make.")
    var jumps: Int = 20

    func run() throws {
        let engine = engine
        let settings = ScrollSettings(speed: speed, seconds: seconds, jumps: jumps, inserts: 0, selections: 0)
        let scope = path ?? "whole diff"
        let title = "diff-render, \(engine.rawValue), \(from)..\(to), \(scope)"
        try MainActor.assumeIsolated {
            var timer = LapTimer()
            var bytes: [UInt8] = []
            bytes.reserveCapacity(64 << 20)
            let arguments = ["diff", "--no-color", "--no-ext-diff", "-M", from, to] + (path.map { ["--", $0] } ?? [])
            let status = try streamGit(arguments, in: common.repoPath) { bytes.append(contentsOf: $0) }
            guard status == 0 else { throw BenchError("git diff exited with status \(status)") }
            let gitTime = timer.lap()
            let document = DiffDocument(bytes: bytes)
            let parseTime = timer.lap()

            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                print("== \(title)\n   gave up: nothing finished within 300 s\n")
                Darwin.exit(2)
            }

            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let window = NSWindow(
                contentRect: NSRect(x: 120, y: 120, width: 1200, height: 800),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "yaga prototype: diff \(engine.rawValue)"
            _ = timer.lap() // Don't count starting AppKit and creating the window.
            var contentReady: @MainActor () -> Bool = { firstRowDrawn }
            var notes: [String] = []
            // Table views hold their data source weakly, so keep the engine alive for the run.
            let engineObject: AnyObject
            switch engine {
            case .table:
                let tableEngine = DiffTableEngine(document: document)
                window.contentView = tableEngine.makeView()
                engineObject = tableEngine
            case .text, .textkit1:
                let textEngine = DiffTextEngine(document: document, textKit2: engine == .text,
                                                colored: !plain, wrapped: wrap)
                window.contentView = textEngine.makeView()
                contentReady = { firstRowDrawn || textEngine.hasLaidOutViewport }
                notes.append("TextKit 2 in use: \(textEngine.usesTextKit2), backgrounds: \(!plain), wrapped: \(wrap)")
                engineObject = textEngine
            }
            let prepareTime = timer.lap()

            let summary = """
                \(document.count) lines in \(document.fileCount) files, \(bytes.count / 1_048_576) MB of patch text
                   git diff took \(Int(gitTime.milliseconds)) ms, splitting into lines \(Int(parseTime.milliseconds)) ms, \
                preparing the view \(Int(prepareTime.milliseconds)) ms
                """ + notes.map { "\n   " + $0 }.joined()
            let actions = ViewActions(insertCommits: {}, selectRow: { _ in }, contentReady: contentReady)
            let driver = ScrollDriver(window: window, settings: settings, actions: actions) { results in
                withExtendedLifetime(engineObject) {}
                results.print(title: title, setup: summary, settings: settings)
                Darwin.exit(0)
            }
            window.makeKeyAndOrderFront(nil)
            app.activate()
            driver.start()
            app.run()
        }
    }
}

@MainActor
enum DiffStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let characterWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
    static let rowHeight: CGFloat = 17
    static let gutterWidth: CGFloat = 100

    static func background(_ kind: DiffDocument.Kind) -> NSColor? {
        switch kind {
        case .added: NSColor.systemGreen.withAlphaComponent(0.15)
        case .removed: NSColor.systemRed.withAlphaComponent(0.15)
        case .hunkHeader: NSColor.systemBlue.withAlphaComponent(0.12)
        case .fileHeader: NSColor.secondaryLabelColor.withAlphaComponent(0.12)
        case .context: nil
        }
    }

    static func wordBackground(_ kind: DiffDocument.Kind) -> NSColor {
        kind == .added ? NSColor.systemGreen.withAlphaComponent(0.4) : NSColor.systemRed.withAlphaComponent(0.4)
    }

    static let text: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
    static let gutter: [NSAttributedString.Key: Any] = [.font: gutterFont, .foregroundColor: NSColor.tertiaryLabelColor]
}

/// Shows a diff in an `NSTableView` with one self-drawn row per line.
@MainActor
final class DiffTableEngine: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let document: DiffDocument
    private let tableView = NSTableView()

    init(document: DiffDocument) { self.document = document }

    func makeView() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = DiffStyle.rowHeight
        tableView.intercellSpacing = .zero
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        return scrollView
    }

    func numberOfRows(in tableView: NSTableView) -> Int { document.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: DiffRowView.identifier, owner: nil) as? DiffRowView
            ?? DiffRowView(document: document)
        view.line = row
        view.needsDisplay = true
        return view
    }
}

@MainActor
final class DiffRowView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("DiffRowView")

    private let document: DiffDocument
    var line = 0

    init(document: DiffDocument) {
        self.document = document
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        firstRowDrawn = true
        rowsDrawn += 1
        let kind = document.kinds[line]
        if let background = DiffStyle.background(kind) {
            background.setFill()
            bounds.fill()
        }
        let textX = DiffStyle.gutterWidth + 8
        if let changed = document.changedRange(line) {
            let start = document.column(line, byteOffset: changed.lowerBound)
            let end = document.column(line, byteOffset: changed.upperBound)
            DiffStyle.wordBackground(kind).setFill()
            NSRect(x: textX + CGFloat(start) * DiffStyle.characterWidth, y: 0,
                   width: CGFloat(end - start) * DiffStyle.characterWidth, height: bounds.height).fill()
        }
        let old = document.oldNumbers[line]
        let new = document.newNumbers[line]
        if old > 0 { ("\(old)" as NSString).draw(at: NSPoint(x: 4, y: 2), withAttributes: DiffStyle.gutter) }
        if new > 0 { ("\(new)" as NSString).draw(at: NSPoint(x: 52, y: 2), withAttributes: DiffStyle.gutter) }
        (document.displayText(line) as NSString).draw(at: NSPoint(x: textX, y: 1), withAttributes: DiffStyle.text)
    }
}

/// Shows a diff as one attributed string in a TextKit 2 `NSTextView`.
@MainActor
final class DiffTextEngine {
    private let document: DiffDocument
    private let textView: DiffTextView
    private let colored: Bool
    private let wrapped: Bool

    var usesTextKit2: Bool { textView.textLayoutManager != nil }

    var hasLaidOutViewport: Bool {
        textView.textLayoutManager?.textViewportLayoutController.viewportRange != nil
    }

    init(document: DiffDocument, textKit2: Bool, colored: Bool, wrapped: Bool) {
        self.document = document
        self.colored = colored
        self.wrapped = wrapped
        textView = DiffTextView(usingTextLayoutManager: textKit2)
        // TextKit 1 lays out only what's visible when non-contiguous layout is on. Asking a
        // TextKit 2 view for its layoutManager silently switches it to TextKit 1, so only do
        // this for TextKit 1.
        if !textKit2 { textView.layoutManager?.allowsNonContiguousLayout = true }
    }

    func makeView() -> NSView {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.isVerticallyResizable = true
        // A text view that sizes its own width has to measure every line to find the longest,
        // so unwrapped views get a fixed width instead.
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if !wrapped {
            // TextKit 2 stalled badly with an unlimited width, so lines wrap only past 20,000
            // points, about 2,800 characters.
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: 20_000, height: CGFloat.greatestFiniteMagnitude)
        }
        fill(textView.textStorage!)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        if wrapped {
            textView.autoresizingMask = [.width]
        } else {
            textView.setFrameSize(NSSize(width: 20_000, height: textView.frame.height))
        }
        return scrollView
    }

    /// Builds the whole diff as attributed text: line backgrounds, then changed-word backgrounds.
    private func fill(_ storage: NSTextStorage) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = DiffStyle.characterWidth * 8
        paragraph.tabStops = []
        var attributes = DiffStyle.text
        attributes[.paragraphStyle] = paragraph

        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(
            string: String(decoding: document.bytes, as: UTF8.self), attributes: attributes))
        var offset = 0
        for line in 0..<(colored ? document.count : 0) {
            let length = document.utf16Length(line)
            let kind = document.kinds[line]
            if let background = DiffStyle.background(kind) {
                storage.addAttribute(.backgroundColor, value: background, range: NSRange(location: offset, length: length))
            }
            if let changed = document.changedRange(line) {
                let start = document.utf16Length(line, bytes: 0..<changed.lowerBound)
                let width = document.utf16Length(line, bytes: changed)
                storage.addAttribute(.backgroundColor, value: DiffStyle.wordBackground(kind),
                                     range: NSRange(location: offset + start, length: width))
            }
            offset += length + 1
        }
        storage.endEditing()
    }
}

final class DiffTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        firstRowDrawn = true
    }
}
