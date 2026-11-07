import SwiftUI

/// Text on one line that fades out over its last points when it doesn't fit,
/// rather than being cut short with an ellipsis (decision 51). Names in the
/// sidebar and the refs panel, and a sidebar row's second line, use it. What's
/// shown is always the start of the text, so two branches that differ only at
/// their end look alike until the row is wider. Their tooltips have the rest.
///
/// It's as flexible as a `Text` with a line limit of 1: it takes the room it's
/// offered, up to the width of the whole text, so it gives way beside other
/// views as text does.
struct FadingText: View {
    private let text: Text
    private let fade: CGFloat

    /// How many points the fade runs over.
    static var fadeWidth: CGFloat { 18 }

    init(_ string: String, fade: CGFloat = Self.fadeWidth) {
        text = Text(string)
        self.fade = fade
    }

    init(_ text: Text, fade: CGFloat = Self.fadeWidth) {
        self.text = text
        self.fade = fade
    }

    var body: some View {
        // The first that fits: the whole text, or else its start, faded.
        ViewThatFits(in: .horizontal) {
            text
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            StartOfText {
                text.lineLimit(1)
            }
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade)
                }
            }
        }
    }
}

/// Lays out its one view at its whole width, from its leading edge, and is no
/// wider than the room it's offered, so what doesn't fit runs past its end for
/// a mask to hide.
private struct StartOfText: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let whole = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: min(whole.width, proposal.width ?? whole.width), height: whole.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let whole = subview.sizeThatFits(.unspecified)
        subview.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(whole))
    }
}
