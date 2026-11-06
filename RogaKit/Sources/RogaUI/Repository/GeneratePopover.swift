import AgentEngine
import SwiftUI

/// What the Generate button's chevron opens: which agent writes the message,
/// with which model and effort, and the exact command that runs (decision 41).
///
/// It's laid out as Roga's dialogs are (decision 29), with the command along
/// its bottom edge. Every pick is stored as it's made, the same values the
/// Commit page in Settings shows, so the next click of Generate uses them.
struct GeneratePopover: View {
    let agents: AgentProvider
    /// The worktree's folder and whether the box has words in it, which the
    /// command shows.
    let worktree: String
    let hasDraft: Bool
    /// Whether Generate can run now, which it can't with nothing staged.
    let canGenerate: Bool
    let generate: (AgentKind) -> Void
    let close: () -> Void

    static var width: CGFloat { 312 }

    var body: some View {
        let picked = agents.generateAgent
        let setup = picked.flatMap { agents.generation(with: $0) }
        VStack(alignment: .leading, spacing: 0) {
            Text("Write the message with")
                .font(.system(size: 13, weight: .semibold))
                .padding(EdgeInsets(top: 13, leading: 16, bottom: 8, trailing: 16))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 2) {
                ForEach(AgentKind.allCases, id: \.self) { kind in
                    GeneratePopoverAgentRow(kind: kind, agents: agents, isPicked: kind == picked)
                }
            }
            .padding(.horizontal, 6)
            if let picked {
                GeneratePopoverChoices(kind: picked, codexDefaultModel: agents.codexDefaultModel)
                    .id(picked)
            }
            HStack(spacing: 8) {
                Text("Remembered for next time")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DialogColors.note)
                Spacer(minLength: 8)
                Button("Generate") {
                    if let picked { generate(picked) }
                }
                .buttonStyle(GeneratePopoverButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(setup == nil || !canGenerate)
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            if let setup {
                CommandBlock(lines: setup.terminal(worktree: worktree, hasDraft: hasDraft), isCompact: true)
            }
        }
        .frame(width: Self.width)
        .font(.system(size: 13))
        // The popover's arrow points down at the chevron from under the command,
        // so it's the command's color, as the canvas draws it. The system clips
        // what's drawn past the popover's edges to its shape, arrow included.
        .background(alignment: .bottom) {
            if setup != nil {
                DialogColors.terminal
                    .frame(height: 24)
                    .offset(y: 24)
            }
        }
        // A plain surface over the system's material, like a dialog's.
        .background {
            DialogColors.surface
                .padding(-24)
        }
        .background {
            // Escape closes it, as it does a menu.
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

extension GeneratePopover {
    /// Why an agent can't be picked, for the second line of its row, or nil
    /// when it can.
    static func unusableReason(_ kind: AgentKind, in agents: AgentProvider) -> String? {
        guard let lookup = agents.lookups[kind] else { return "Looking for it…" }
        switch lookup {
        case .found:
            return agents.settings[kind]?.isEnabled == false ? "Turned off" : nil
        case .notFound, .configuredMissing:
            return "Not found"
        case .unusable(let skipped):
            return reason(skipped)
        case .configuredUnusable(let skipped):
            return reason([skipped])
        }
    }

    private static func reason(_ skipped: [SkippedAgent]) -> String {
        let isTooOld = skipped.contains { if case .tooOld = $0.reason { true } else { false } }
        return isTooOld ? "Too old to use" : "Couldn't run it"
    }

    /// The second line of a usable agent's row: its model and its effort, as in
    /// "haiku · low effort". Codex's own default model is named when its
    /// configuration says which it is.
    static func detail(_ kind: AgentKind, model: String, effort: String, codexDefaultModel: String?) -> String {
        let modelWords = model.isEmpty ? (kind == .codex ? codexDefaultModel : nil) ?? "default model" : model
        let effortWords = effort.isEmpty ? "default effort" : "\(effort) effort"
        return "\(modelWords) · \(effortWords)"
    }

    /// The models to offer: the agent's own choices, and the stored one too when
    /// it isn't one of them, as when someone typed a Codex model in Settings.
    static func modelChoices(_ kind: AgentKind, stored: String) -> [String] {
        kind.modelChoices.contains(stored) ? kind.modelChoices : kind.modelChoices + [stored]
    }

    /// What a model's chip says: Default for the agent's own, with Codex's
    /// model from its configuration when that's known.
    static func modelTitle(_ model: String, kind: AgentKind, codexDefaultModel: String?) -> String {
        if model.isEmpty, kind == .codex, let codexDefaultModel { return "Default · \(codexDefaultModel)" }
        return AgentKind.modelTitle(model)
    }
}

/// One agent in the popover, with its model and effort under its name, or why
/// it can't be used, dimmed.
struct GeneratePopoverAgentRow: View {
    let kind: AgentKind
    let agents: AgentProvider
    let isPicked: Bool
    @AppStorage private var model: String
    @AppStorage private var effort: String

    init(kind: AgentKind, agents: AgentProvider, isPicked: Bool) {
        self.kind = kind
        self.agents = agents
        self.isPicked = isPicked
        _model = AppStorage(wrappedValue: kind.recommendedModel, AgentPreferences.modelKey(kind))
        _effort = AppStorage(wrappedValue: AgentPreferences.recommendedEffort, AgentPreferences.effortKey(kind))
    }

    var body: some View {
        let reason = GeneratePopover.unusableReason(kind, in: agents)
        Button {
            agents.setGenerateAgent(kind)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                GeneratePopoverRadio(isOn: isPicked)
                    .opacity(reason == nil ? 1 : 0.5)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.name)
                        .foregroundStyle(reason == nil ? Color.primary : DialogColors.note)
                    Text(reason ?? GeneratePopover.detail(kind, model: model, effort: effort, codexDefaultModel: agents.codexDefaultModel))
                        .font(.system(size: 12))
                        .foregroundStyle(DialogColors.note)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if isPicked {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DialogColors.card)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GeneratePopoverRowStyle())
        .disabled(reason != nil)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

/// An agent's row. One that can't be picked is already gray, and says why, so
/// unlike the plain style it isn't dimmed again, which would make the why hard
/// to read.
private struct GeneratePopoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The ring of a choice of one: hollow, or filled in ink with a white middle
/// once it's picked.
private struct GeneratePopoverRadio: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .strokeBorder(isOn ? DialogColors.ink : DialogColors.note, lineWidth: isOn ? 4.5 : 1)
            .frame(width: 14, height: 14)
    }
}

/// The picked agent's model, as chips, and its effort, as segments.
private struct GeneratePopoverChoices: View {
    let kind: AgentKind
    let codexDefaultModel: String?
    @AppStorage private var model: String
    @AppStorage private var effort: String

    init(kind: AgentKind, codexDefaultModel: String?) {
        self.kind = kind
        self.codexDefaultModel = codexDefaultModel
        _model = AppStorage(wrappedValue: kind.recommendedModel, AgentPreferences.modelKey(kind))
        _effort = AppStorage(wrappedValue: AgentPreferences.recommendedEffort, AgentPreferences.effortKey(kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Model") {
                GeneratePopoverFlow(spacing: 4) {
                    ForEach(GeneratePopover.modelChoices(kind, stored: model), id: \.self) { choice in
                        Button(GeneratePopover.modelTitle(choice, kind: kind, codexDefaultModel: codexDefaultModel)) {
                            model = choice
                        }
                        .buttonStyle(GeneratePopoverChipStyle(isOn: model == choice))
                        .accessibilityAddTraits(model == choice ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Model")
            }
            row("Effort") {
                HStack(spacing: 2) {
                    ForEach(AgentKind.effortChoices, id: \.self) { choice in
                        Button(AgentKind.effortTitle(choice)) {
                            effort = choice
                        }
                        .buttonStyle(GeneratePopoverSegmentStyle(isOn: effort == choice))
                        .accessibilityAddTraits(effort == choice ? .isSelected : [])
                    }
                }
                .padding(2)
                .background(DialogColors.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Effort")
            }
        }
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(DialogColors.note)
                .frame(width: 52, alignment: .leading)
                .accessibilityHidden(true)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
    }
}

/// A model's chip: gray, or ink once it's picked.
private struct GeneratePopoverChipStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: isOn ? .medium : .regular))
            .lineLimit(1)
            .foregroundStyle(isOn ? DialogColors.onInk : Color.primary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(isOn ? DialogColors.ink : DialogColors.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed && !isOn ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// One of the effort's segments, each as wide as the others, with the picked
/// one raised in white.
private struct GeneratePopoverSegmentStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DialogColors.surface)
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(SettingsColors.line, lineWidth: 0.5)
                        }
                }
            }
            .opacity(configuration.isPressed && !isOn ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The popover's Generate, in ink like a dialog's main button.
private struct GeneratePopoverButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(DialogColors.onInk)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(DialogColors.ink, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Lays its views out in rows, going on to the next row when one is full, as
/// the chips do when a model's name is long.
private struct GeneratePopoverFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(of: subviews, width: bounds.width) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(of subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
