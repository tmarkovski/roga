import AppKit
import IconUI
import SwiftUI

// MARK: The box

/// The size of the box that fields and dropdowns share.
enum SettingsBoxMetrics {
    static let height: CGFloat = 28
    static let cornerRadius: CGFloat = 8
}

/// The box that fields and dropdowns share, drawn the way the Claude app
/// draws its own: a soft gray fill with no line around it, a step lighter
/// while the pointer is over it, and a thin ring in the accent color a point
/// outside it while it has focus or its list is open.
struct SettingsBox: ViewModifier {
    var cornerRadius = SettingsBoxMetrics.cornerRadius
    var isHovering: Bool
    var isFocused: Bool
    /// Whether the box sits on a gray card, such as a program's row, whose
    /// gray is the page's field gray, so it takes a step stronger.
    var isOnCard = false

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if isFocused {
                    SettingsFocusRing(cornerRadius: cornerRadius)
                }
            }
    }

    private var fill: Color {
        switch (isOnCard, isHovering) {
        case (false, false): SettingsColors.field
        case (false, true): SettingsColors.fieldHover
        case (true, false): SettingsColors.fieldOnCard
        case (true, true): SettingsColors.fieldOnCardHover
        }
    }
}

extension View {
    func settingsBox(cornerRadius: CGFloat = SettingsBoxMetrics.cornerRadius, isHovering: Bool, isFocused: Bool, isOnCard: Bool = false) -> some View {
        modifier(SettingsBox(cornerRadius: cornerRadius, isHovering: isHovering, isFocused: isFocused, isOnCard: isOnCard))
    }
}

/// The ring around a box with focus: a one-point line in the accent color
/// with a point of the page between it and the box, and a glow outside the
/// line that fades over four points.
struct SettingsFocusRing: View {
    let cornerRadius: CGFloat

    /// How strong the glow is at each point out from the line.
    private static let glow: [Double] = [0.22, 0.13, 0.07, 0.03]

    var body: some View {
        ZStack {
            ring(outset: 2, opacity: 1)
            ForEach(Array(Self.glow.enumerated()), id: \.offset) { step, opacity in
                ring(outset: CGFloat(3 + step), opacity: opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A one-point line whose outer edge is `outset` points outside the box.
    private func ring(outset: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius + outset, style: .continuous)
            .strokeBorder(SettingsColors.focus.opacity(opacity), lineWidth: 1)
            .padding(-outset)
    }
}

// MARK: The dropdown

/// One row of a dropdown's list.
struct DropdownItem {
    let title: String
    /// Gray words after the title, as in "SF Mono · Default".
    var detail: String?
    var isChosen = false
    /// Whether it's a command after the choices, such as a model's name to
    /// type, which a line sets apart from them.
    var isCommand = false
    let choose: () -> Void

    /// A row for each option, with the check beside the one `selection` holds.
    static func choices<Value: Hashable>(
        _ selection: Binding<Value>,
        _ options: [(value: Value, title: String)],
        detail: (Value) -> String? = { _ in nil }
    ) -> [DropdownItem] {
        options.map { option in
            DropdownItem(title: option.title, detail: detail(option.value), isChosen: option.value == selection.wrappedValue) {
                selection.wrappedValue = option.value
            }
        }
    }
}

/// A box with what's chosen and a chevron, which opens a list of the choices
/// under it, at least as wide as the box, with a check beside the chosen one,
/// as the Claude app's settings do. The list opens as the mouse button goes
/// down, as Roga's menus do (decision 111), and a press dragged onto a row
/// and let go there chooses it, as in a Mac pop-up button.
struct SettingsDropdown<Label: View>: View {
    let items: [DropdownItem]
    /// The box's width, or nil for as wide as what it shows.
    var width: CGFloat?
    @ViewBuilder var label: Label
    @State private var isOpen = false
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                label
                    .lineLimit(1)
                    .frame(maxWidth: width == nil ? nil : .infinity, alignment: .leading)
                SettingsChevron()
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(width: width, height: SettingsBoxMetrics.height)
            .settingsBox(isHovering: isHovering && isEnabled, isFocused: isOpen)
            .contentShape(RoundedRectangle(cornerRadius: SettingsBoxMetrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .opensOnPress($isOpen, isEnabled: !items.isEmpty)
        .background {
            DropdownAnchor(isOpen: $isOpen, items: items)
        }
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.45)
    }
}

extension View {
    /// Lets VoiceOver step through `options` with its adjust gestures, without
    /// opening the list.
    func settingsAdjustable<Value: Hashable>(_ selection: Binding<Value>, _ options: [(value: Value, title: String)]) -> some View {
        accessibilityAdjustableAction { direction in
            guard let index = options.firstIndex(where: { $0.value == selection.wrappedValue }) else { return }
            switch direction {
            case .increment where index + 1 < options.count:
                selection.wrappedValue = options[index + 1].value
            case .decrement where index > 0:
                selection.wrappedValue = options[index - 1].value
            default:
                break
            }
        }
    }
}

/// How a dropdown's list is laid out, which its view draws and its window is
/// sized by.
enum DropdownMetrics {
    /// Between the list's edge and its rows.
    static let inset: CGFloat = 5
    static let rowHeight: CGFloat = 28
    /// The room for the line before the commands.
    static let dividerHeight: CGFloat = 9
    /// Between the box and the list.
    static let gap: CGFloat = 6
    static let cornerRadius: CGFloat = 12
    static let rowCornerRadius: CGFloat = 7
    /// Before a row's words, and after its check.
    static let rowPadding: CGFloat = 12
    /// The room for the check at a row's end.
    static let checkWidth: CGFloat = 16
    /// Between a row's words and its check.
    static let checkSpacing: CGFloat = 12
    /// The tallest a list gets before it scrolls.
    static let maxHeight: CGFloat = 420
    /// The room the list keeps from the screen's edges.
    static let screenMargin: CGFloat = 8
    static let fontSize: CGFloat = 13

    /// How tall the list is with all its rows showing.
    static func height(of items: [DropdownItem]) -> CGFloat {
        2 * inset + CGFloat(items.count) * rowHeight + (items.contains(where: \.isCommand) ? dividerHeight : 0)
    }

    /// How wide the list needs to be for its longest row.
    static func width(of items: [DropdownItem]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let widest = items.map { item in
            NSAttributedString(string: words(of: item), attributes: [.font: font]).size().width
        }.max() ?? 0
        // A point more than the words measure, for rounding where they're drawn.
        return ceil(widest) + 1 + 2 * inset + 2 * rowPadding + checkSpacing + checkWidth
    }

    /// What a row says, with its detail after a dot.
    static func words(of item: DropdownItem) -> String {
        item.detail.map { "\(item.title) · \($0)" } ?? item.title
    }
}

/// Where a dropdown's list opens from: an AppKit view behind the box, whose
/// place on the screen the list's window lines up with.
private struct DropdownAnchor: NSViewRepresentable {
    @Binding var isOpen: Bool
    let items: [DropdownItem]

    func makeCoordinator() -> DropdownList {
        DropdownList()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        let list = context.coordinator
        let isOpen = $isOpen
        list.closedByItself = { isOpen.wrappedValue = false }
        list.items = items
        if self.isOpen, view.window != nil {
            list.open(under: view)
        } else {
            list.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: DropdownList) {
        coordinator.close()
    }
}

/// A dropdown's list while it's open: a window of its own under the box, so
/// that it can reach past the edges of the sheet or the popover the box is
/// in, as a menu can. The window never becomes key, so the box's window keeps
/// its focus, and a local event monitor gives the list the keys a menu takes:
/// the arrows, Return, Space, Escape and typing a choice's first letters.
/// A press anywhere else closes it without doing anything else, as a click
/// outside a menu does.
@Observable
final class DropdownList {
    var items: [DropdownItem] = []
    /// The row the pointer or the arrow keys are on.
    var highlighted: Int?
    /// The row the keys last moved to, which the list scrolls to show. The
    /// pointer's row isn't, so that a row half in view doesn't move away
    /// from under it, as a menu's rows don't.
    var scrollTarget: Int?
    var width: CGFloat = 0
    var height: CGFloat = 0
    @ObservationIgnored var closedByItself: () -> Void = {}
    /// Each row's frame from the list's top-left corner, for a press that
    /// starts on the box and is let go over a row.
    @ObservationIgnored var rowFrames: [Int: CGRect] = [:]
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var typed = ""
    @ObservationIgnored private var typedAt = Date.distantPast

    var isOpen: Bool { panel != nil }

    func open(under anchor: NSView) {
        guard panel == nil, let window = anchor.window, !items.isEmpty else { return }
        let box = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? box.insetBy(dx: -1000, dy: -1000)
        let margin = DropdownMetrics.screenMargin
        let below = box.minY - DropdownMetrics.gap - screen.minY - margin
        let above = screen.maxY - box.maxY - DropdownMetrics.gap - margin
        let natural = DropdownMetrics.height(of: items)
        let opensAbove = natural > below && above > below
        width = min(max(box.width, DropdownMetrics.width(of: items)), screen.width - 2 * margin)
        height = min(natural, DropdownMetrics.maxHeight, max(opensAbove ? above : below, DropdownMetrics.rowHeight * 3))
        highlighted = items.firstIndex(where: \.isChosen)
        scrollTarget = nil
        typed = ""

        let x = min(max(box.minX, screen.minX + margin), screen.maxX - margin - width)
        let y = opensAbove ? box.maxY + DropdownMetrics.gap : box.minY - DropdownMetrics.gap - height
        let panel = DropdownPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.appearance = window.effectiveAppearance
        panel.contentView = DropdownHostingView(rootView: DropdownListView(list: self))
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel
        // The shadow follows the list's rounded corners once it has drawn.
        DispatchQueue.main.async { [weak panel] in panel?.invalidateShadow() }

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        ) { [weak self] event in
            guard let self else { return event }
            return handle(event)
        }
        let center = NotificationCenter.default
        let dismiss: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: dismiss),
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: dismiss),
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: dismiss),
        ]
    }

    func close() {
        guard let panel else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        rowFrames = [:]
    }

    /// Closes the list and tells the box, for a close the box didn't ask for.
    private func dismiss() {
        guard isOpen else { return }
        close()
        closedByItself()
    }

    func choose(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        dismiss()
        item.choose()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let panel else { return event }
        let isInList = event.window === panel
        switch event.type {
        case .keyDown:
            return key(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if isInList { return event }
            dismiss()
            return nil
        case .leftMouseDragged:
            // A press that opened the list from the box, dragged over it.
            if !isInList, let row = row(at: event) { highlighted = row }
            return event
        case .leftMouseUp:
            if !isInList, let row = row(at: event) {
                choose(row)
                return nil
            }
            return event
        case .scrollWheel:
            if isInList { return event }
            dismiss()
            return nil
        default:
            return event
        }
    }

    /// The row under the pointer, for an event in another window.
    private func row(at event: NSEvent) -> Int? {
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        guard let panel, panel.frame.contains(point) else { return nil }
        // The rows' frames are from the list's top-left corner.
        let inList = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
        return rowFrames.first { $0.value.contains(inList) }?.key
    }

    private func key(_ event: NSEvent) -> NSEvent? {
        if event.modifierFlags.contains(.command) {
            dismiss()
            return event
        }
        switch event.keyCode {
        case 53, 48: // Escape, Tab
            dismiss()
        case 125: // Down
            move(by: 1)
        case 126: // Up
            move(by: -1)
        case 115, 116: // Home, Page Up
            highlight(0)
        case 119, 121: // End, Page Down
            highlight(items.count - 1)
        case 36, 76: // Return, Enter
            if let highlighted { choose(highlighted) } else { dismiss() }
        case 49 where typed.isEmpty || Date().timeIntervalSince(typedAt) > 1: // Space
            if let highlighted { choose(highlighted) } else { dismiss() }
        default:
            if let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
                typeSelect(characters)
            }
        }
        return nil
    }

    private func move(by step: Int) {
        guard !items.isEmpty else { return }
        let next = highlighted.map { $0 + step } ?? (step > 0 ? 0 : items.count - 1)
        highlight(min(max(next, 0), items.count - 1))
    }

    /// Moves to the first choice that starts with what's been typed in the
    /// last second, as a menu does.
    private func typeSelect(_ characters: String) {
        let now = Date()
        typed = now.timeIntervalSince(typedAt) < 1 ? typed + characters : characters
        typedAt = now
        let prefix = typed.lowercased()
        if let index = items.firstIndex(where: { !$0.isCommand && $0.title.lowercased().hasPrefix(prefix) }) {
            highlight(index)
        }
    }

    private func highlight(_ index: Int) {
        guard items.indices.contains(index) else { return }
        scrollTarget = index
        guard index != highlighted else { return }
        highlighted = index
        // VoiceOver stays on the box, so it hears each row as it's reached.
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: DropdownMetrics.words(of: items[index]), .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}

/// The list's window, which never takes the keys from the box's.
private final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The list's view, which takes a click without its window having to come
/// forward first.
private final class DropdownHostingView: NSHostingView<DropdownListView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The rows of a dropdown's list on a rounded card with a line around it,
/// scrolling when there are more than fit.
private struct DropdownListView: View {
    let list: DropdownList

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DropdownMetrics.cornerRadius, style: .continuous)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                        if item.isCommand, index == list.items.firstIndex(where: \.isCommand) {
                            Rectangle()
                                .fill(SettingsColors.listLine)
                                .frame(height: 1)
                                .padding(.horizontal, DropdownMetrics.rowPadding - 4)
                                .frame(height: DropdownMetrics.dividerHeight)
                        }
                        DropdownRow(item: item, isHighlighted: list.highlighted == index)
                            .id(index)
                            .onHover { if $0 { list.highlighted = index } }
                            .onTapGesture { list.choose(index) }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                list.rowFrames[index] = frame
                            }
                    }
                }
                .padding(DropdownMetrics.inset)
            }
            .scrollDisabled(DropdownMetrics.height(of: list.items) <= list.height)
            .scrollIndicators(.automatic)
            .onAppear {
                if let chosen = list.highlighted { proxy.scrollTo(chosen, anchor: .center) }
            }
            .onChange(of: list.scrollTarget) { _, row in
                if let row { proxy.scrollTo(row) }
            }
        }
        .frame(width: list.width, height: list.height)
        .background(SettingsColors.list, in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(SettingsColors.listLine, lineWidth: 1)
        }
        .font(.system(size: DropdownMetrics.fontSize))
        .accessibilityElement(children: .contain)
    }
}

/// One choice: its words, then a check in the accent color if it's chosen,
/// on a gray rounded fill while the pointer or the arrow keys are on it.
private struct DropdownRow: View {
    let item: DropdownItem
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: DropdownMetrics.checkSpacing) {
            words
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Icon.check.image
                .font(.system(size: 15))
                .foregroundStyle(SettingsColors.focus)
                .frame(width: DropdownMetrics.checkWidth)
                .opacity(item.isChosen ? 1 : 0)
        }
        .padding(.horizontal, DropdownMetrics.rowPadding)
        .frame(height: DropdownMetrics.rowHeight)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: DropdownMetrics.rowCornerRadius, style: .continuous)
                    .fill(SettingsColors.listHighlight)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DropdownMetrics.words(of: item))
        .accessibilityAddTraits(item.isChosen ? [.isButton, .isSelected] : .isButton)
    }

    private var words: Text {
        guard let detail = item.detail else { return Text(item.title) }
        return Text("\(item.title) \(Text("· \(detail)").foregroundStyle(SettingsColors.note))")
    }
}
