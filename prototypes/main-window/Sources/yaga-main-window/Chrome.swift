import AppKit
import SwiftUI

/// Colors for the preview. Surfaces are plain, sections are separated by thin
/// lines, and selection is a soft gray rather than the accent color.
nonisolated enum Palette {
    static let surface = dynamic(light: 1.0, dark: 0.135)
    static let chrome = dynamic(light: 1.0, dark: 0.115)
    static let selected = dynamic(light: 0.91, dark: 0.245)
    static let hover = dynamic(light: 0.948, dark: 0.19)
    static let separator = dynamic(light: 0.885, dark: 0.225)
    static let field = dynamic(light: 1.0, dark: 0.165)
    /// The navigator is a shade darker than the panels, like the Claude app's sidebar.
    static let sidebar = dynamic(light: 0.925, dark: 0.1)
    static let sidebarHover = dynamic(light: 0.885, dark: 0.16)
    static let sidebarSelected = dynamic(light: 0.87, dark: 0.2)
    static let segmentTrack = dynamic(light: 0.925, dark: 0.2)
    static let segmentSelected = dynamic(light: 1.0, dark: 0.3)
    static let added = Color.green.opacity(0.13)
    static let removed = Color.red.opacity(0.12)
    static let hunk = Color.blue.opacity(0.07)

    static func dynamic(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }
}

nonisolated enum Metrics {
    static let tabBarHeight: CGFloat = 44
    static let panelHeaderHeight: CGFloat = 40
    static let trafficLightsWidth: CGFloat = 84
}

/// A plain rectangle with its own header: a title or sub-tabs on the left and
/// commands on the right.
struct Panel<Leading: View, Trailing: View, Content: View>: View {
    var background = Palette.surface
    var showsHeaderDivider = true
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                leading
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 10)
            .frame(height: Metrics.panelHeaderHeight)
            .overlay(alignment: .bottom) {
                if showsHeaderDivider { Hairline() }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(background)
    }
}

/// A switch between a few views of the same panel, styled like the Claude
/// app's switch between chat and code: a gray track with the selected segment
/// raised in white.
struct SegmentedSwitch<Value: Hashable>: View {
    struct Segment {
        let value: Value
        let title: String
        var count: Int?
    }

    let segments: [Segment]
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.value) { segment in
                let isSelected = segment.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.18)) { selection = segment.value }
                } label: {
                    HStack(spacing: 5) {
                        Text(segment.title)
                        if let count = segment.count, count > 0 {
                            Text("\(count)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 24)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Palette.segmentSelected)
                                .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Palette.separator, lineWidth: 0.5)
                                )
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.segmentTrack))
    }
}

struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

struct PanelTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.leading, 4)
    }
}

/// An icon button in the Claude app's style: a dark, thin glyph that gets a
/// rounded gray square when the pointer is over it.
struct IconButton: View {
    let systemImage: String
    let help: String
    var isOn = false
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hovering = false

    init(_ systemImage: String, help: String, isOn: Bool = false, size: CGFloat = 28, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.isOn = isOn
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size >= 28 ? 13.5 : 12.5, weight: .regular))
                .foregroundStyle(Color.primary.opacity(isOn || hovering ? 0.92 : 0.72))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size >= 28 ? 7 : 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.1 : (isOn ? 0.06 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Lets the empty parts of the tab bar move the window, and double-clicking
/// them do what the user chose in System Settings.
struct TitleBarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarDragView { TitleBarDragView() }
    func updateNSView(_ view: TitleBarDragView, context: Context) {}
}

final class TitleBarDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }
}

/// Turns off macOS window tabbing for the window and centers the traffic
/// lights vertically in yaga's taller tab bar.
struct WindowChrome: NSViewRepresentable {
    let barHeight: CGFloat

    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        view.barHeight = barHeight
        return view
    }

    func updateNSView(_ view: WindowChromeView, context: Context) {}
}

final class WindowChromeView: NSView {
    var barHeight: CGFloat = Metrics.tabBarHeight
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        layoutTrafficLights()
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutTrafficLights() }
            })
        }
        DispatchQueue.main.async { [weak self] in self?.layoutTrafficLights() }
    }

    func layoutTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview,
              let container = titlebar.superview else { return }
        var frame = container.frame
        frame.size.height = barHeight
        frame.origin.y = window.frame.height - barHeight
        container.frame = frame
        titlebar.frame = container.bounds
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
        for button in buttons {
            button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: ((barHeight - button.frame.height) / 2).rounded()))
        }
    }
}

extension View {
    /// Runs the action on a click, and on VoiceOver's or accessibility's press action.
    func onActivate(_ action: @escaping () -> Void) -> some View {
        onTapGesture(perform: action)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}
