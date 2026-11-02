import Foundation
import RepositoryEngine
import SwiftUI

/// What the user has chosen so far, which outlasts the popover closing while
/// the open panel is up.
struct AddRepositoriesChoices {
    /// The folders the user picked, whose clones show whoever owns them.
    var pickedFolders: [String] = []
    /// The clones checked, by their folders.
    var checked: Set<String> = []
}

/// The popover that adds clones already on this Mac to the sidebar. It looks in
/// the folders that listed repositories are in, and in any the user picks
/// (decision 16).
struct AddRepositories: View {
    let list: RepositoryList
    let scope: SidebarScope
    @Binding var choices: AddRepositoriesChoices
    let lookInAnotherFolder: () -> Void
    let select: (WorktreeSelection) -> Void
    /// The clones found, or nil while looking.
    @State private var clones: [LocalClone]?
    /// The row the keyboard is on.
    @State private var current: String?
    @State private var filter = ""
    @FocusState private var isFilterFocused: Bool
    @FocusState private var isListFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private static let rowHeight: CGFloat = 44
    /// The list fits its rows, between these many, so that a few clones don't
    /// leave a gap and a long filter result doesn't push the buttons away.
    private static let visibleRows = 2...7

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .frame(height: 44)
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            filterField
            Text(hint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 6, trailing: 16))
            rows
                .frame(height: Self.rowHeight * CGFloat(visible.count.clamped(to: Self.visibleRows)))
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
            HStack {
                Button("Look in Another Folder…", action: lookInAnotherFolder)
                Spacer()
                Button("Add Selected", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(toAdd.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 400)
        .task(id: choices.pickedFolders) {
            let found = await list.clonesToAdd(alsoLookingIn: choices.pickedFolders)
            guard !Task.isCancelled else { return }
            clones = found
            // A folder the user picked that is itself a clone is the one they
            // want.
            choices.checked.formUnion(found.map(\.path).filter(pickedPaths.contains))
        }
        .onAppear { isFilterFocused = true }
    }

    private var title: String {
        scope == .all || scope == .other ? "Add Repositories" : "Add to \(list.groups.title(of: scope))"
    }

    private var hint: String {
        switch scope {
        case .all:
            "Clones found in the folders you’ve already added from."
        case .organization:
            "Clones of \(list.groups.title(of: scope))’s repositories, found in the folders you’ve already added from."
        case .other:
            "Clones that aren’t in an organization on the rail, found in the folders you’ve already added from."
        }
    }

    /// The folders the user picked with symbolic links resolved, as git and
    /// the clones found have them.
    private var pickedPaths: Set<String> {
        Set(choices.pickedFolders.map { folder in
            guard let resolved = realpath(folder, nil) else { return folder }
            defer { free(resolved) }
            return String(cString: resolved)
        })
    }

    /// The clones that belong to what the rail picked, and any from a folder
    /// the user picked, narrowed by the filter.
    private var visible: [LocalClone] {
        let groups = list.groups
        let picked = pickedPaths
        return (clones ?? []).filter { clone in
            let isPicked = picked.contains(clone.path) || picked.contains((clone.path as NSString).deletingLastPathComponent)
            return (isPicked || scope == .all || groups.scope(ofOwner: clone.owner) == scope)
                && (filter.isEmpty || clone.name.localizedStandardContains(filter))
        }
    }

    /// What's checked, or else the row the keyboard is on, in the order shown.
    private var toAdd: [String] {
        let shown = visible.map(\.path)
        let chosen = shown.filter(choices.checked.contains)
        return chosen.isEmpty ? shown.filter { $0 == current } : chosen
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Filter repositories", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFilterFocused)
                .onKeyPress(.downArrow) {
                    move(by: 1)
                    isListFocused = true
                    return .handled
                }
                .onSubmit(add)
                .onChange(of: filter) {
                    current = filter.isEmpty ? nil : visible.first?.path
                }
                .accessibilityLabel("Filter Repositories")
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isFilterFocused ? Color.primary.opacity(0.35) : Palette.separator)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var rows: some View {
        let visible = visible
        if clones == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            Text(filter.isEmpty ? "There’s nothing more to add from these folders." : "No clones match the filter.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { clone in
                            CloneRow(clone: clone, isChecked: choices.checked.contains(clone.path), isCurrent: current == clone.path) {
                                toggle(clone.path)
                            }
                            .frame(height: Self.rowHeight)
                            .id(clone.path)
                        }
                    }
                }
                .focusable()
                .focused($isListFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow, .space, .return]) { press in
                    switch press.key {
                    case .upArrow, .downArrow:
                        move(by: press.key == .downArrow ? 1 : -1)
                        if let current { scroller.scrollTo(current) }
                    case .space:
                        if let current { toggle(current) }
                    default:
                        add()
                    }
                    return .handled
                }
            }
        }
    }

    private func toggle(_ path: String) {
        current = path
        if !choices.checked.insert(path).inserted { choices.checked.remove(path) }
    }

    private func move(by step: Int) {
        let shown = visible.map(\.path)
        let index = (shown.firstIndex { $0 == current } ?? (step > 0 ? -1 : shown.count)) + step
        if shown.indices.contains(index) { current = shown[index] }
    }

    /// Adds the repositories, then shows the first one.
    private func add() {
        let folders = toAdd
        guard !folders.isEmpty else { return }
        choices.checked = []
        dismiss()
        Task {
            var first: WorktreeSelection?
            for folder in folders {
                do {
                    let added = try await list.add(folder: folder)
                    first = first ?? added
                } catch {
                    showAlert("Can't Add \((folder as NSString).lastPathComponent)", error)
                }
            }
            if let first { select(first) }
        }
    }
}

/// A clone that can be added: a checkbox, its name and folder, and when it was
/// last used.
private struct CloneRow: View {
    let clone: LocalClone
    let isChecked: Bool
    let isCurrent: Bool
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle(clone.name, isOn: Binding { isChecked } set: { _ in toggle() })
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                Text(clone.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Text(((clone.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if let lastUsed = clone.lastUsed {
                Text(lastUsed, format: .relative(presentation: .named))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .background(isCurrent || isHovering ? Palette.hover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { isHovering = $0 }
        .help(clone.path)
        .accessibilityElement(children: .combine)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
