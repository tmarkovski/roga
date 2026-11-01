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
            .overlay(alignment: .bottom) { Hairline() }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.surface)
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

struct SubTab: View {
    let title: String
    var count: Int?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Palette.selected : (hovering ? Palette.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct IconButton: View {
    let systemImage: String
    let help: String
    var isOn = false
    let action: () -> Void
    @State private var hovering = false

    init(_ systemImage: String, help: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering || isOn ? Palette.hover : .clear)
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
