import Foundation
import RepositoryEngine
import SwiftUI

/// What the clone form has been given, which outlasts the popover closing, as
/// when the open panel is up for Choose….
struct CloneFormState {
    var url = ""
    /// The name of the clone's folder, which follows the URL until the person
    /// types one of their own.
    var name = ""
    var isNameEdited = false
    /// The folder the clone goes in, or nil for the one most listed
    /// repositories are in.
    var folder: String?
    /// The folders the person chose with Choose…, which the pop-up offers too.
    var chosenFolders: [String] = []
    /// Whether it clones submodules too, which it does unless the person says
    /// otherwise, so that a repository with submodules works once it's cloned.
    var recursesSubmodules = true

    /// Takes a new URL, and the name from it unless the person typed one.
    mutating func setURL(_ url: String) {
        self.url = url
        if !isNameEdited { name = CloneRequest.name(fromURL: url) }
    }

    /// Takes a name the person typed. Clearing it goes back to the URL's.
    mutating func setName(_ name: String) {
        isNameEdited = !name.isEmpty
        self.name = isNameEdited ? name : CloneRequest.name(fromURL: url)
    }
}

/// The part of Add Repositories that clones a repository from a URL (decision
/// 113). It's laid out as the identity popover is: each field under its label,
/// gray words beside a label for where its value came from, Choose… in the
/// accent beside Folder's, Cancel and Clone at the trailing edge, and the
/// exact command along the bottom edge (decision 29). It says what's in the way
/// before Clone can be pressed. Clone closes the popover, and the repository's
/// row in the sidebar says how far along git is.
struct CloneForm: View {
    let list: RepositoryList
    @Binding var state: CloneFormState
    /// The folders a clone can go in, with the usual one first.
    let folders: [String]
    @Binding var selection: WorktreeSelection?
    /// Asks for another folder to clone into with the open panel.
    let chooseFolder: () -> Void
    @FocusState private var isURLFocused: Bool
    @Environment(\.dismiss) private var dismiss

    /// How far the form stands from the popover's edges, as the popover's
    /// title does.
    static let inset: CGFloat = 16
    private static let fieldWidth = AddRepositories.width - 2 * inset

    var body: some View {
        let request = request
        let problem = request?.problem
        let existing = list.repository(withRemote: state.url)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                field("URL") {
                    SettingsTextField(
                        text: Binding { state.url } set: { state.setURL($0) },
                        placeholder: "https://github.com/owner/repository",
                        width: Self.fieldWidth,
                        isMonospaced: true
                    )
                    .focused($isURLFocused)
                    .accessibilityLabel("URL")
                    .onSubmit(clone)
                }
                field("Name", note: state.isNameEdited || state.name.isEmpty ? nil : "from the URL") {
                    SettingsTextField(
                        text: Binding { state.name } set: { state.setName($0) },
                        placeholder: "The clone's folder",
                        width: Self.fieldWidth
                    )
                    .accessibilityLabel("Name")
                    .onSubmit(clone)
                }
                field(
                    "Folder",
                    note: folder != nil && state.folder == nil ? "where most listed repositories are" : nil,
                    action: ("Choose…", "Choose another folder to clone into", chooseFolder)
                ) {
                    SettingsSelect(
                        selection: Binding { folder ?? "" } set: { state.folder = $0 },
                        options: folderChoices.map { ($0, ($0 as NSString).abbreviatingWithTildeInPath) },
                        emptyTitle: "No folder yet",
                        width: Self.fieldWidth
                    )
                    .accessibilityLabel("Folder")
                }
                HStack(spacing: 6) {
                    Text("Clone submodules")
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Toggle("Clone submodules", isOn: $state.recursesSubmodules)
                        .toggleStyle(.settings)
                        .labelsHidden()
                }
                note(problem: problem, existing: existing)
            }
            .padding(.horizontal, Self.inset)
            HStack(spacing: 8) {
                DialogActionButton(button: .cancel { dismiss() })
                DialogActionButton(button: DialogButton(title: "Clone", kind: .primary, isEnabled: request != nil && problem == nil, action: clone))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(EdgeInsets(top: 16, leading: Self.inset, bottom: 14, trailing: Self.inset))
            CommandBlock(
                lines: request.flatMap { $0.url.isEmpty ? nil : [.command($0.arguments)] } ?? [.comment("Nothing to clone yet")],
                isCompact: true
            )
        }
        .font(.system(size: 13))
        .task {
            // Once the field is in the popover's window. Switching to the form
            // from the segmented control puts it there a moment after the form
            // appears, and setting the focus before then does nothing.
            try? await Task.sleep(for: .milliseconds(50))
            isURLFocused = true
        }
    }

    /// A field under its label, with gray words after the label, and an action
    /// in the accent at the label's end, as the identity popover has them.
    private func field(
        _ title: String,
        note: String? = nil,
        action: (title: String, help: String, perform: () -> Void)? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
                if let note {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DialogColors.note)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let action {
                    Button(action.title, action: action.perform)
                        .buttonStyle(.contextual)
                        .fixedSize()
                        .help(action.help)
                }
            }
            content()
        }
    }

    /// The folder it clones into, or the usual one, which is the folder most
    /// listed repositories are in.
    private var folder: String? {
        state.folder ?? folders.first
    }

    /// The folders the Folder select offers, with one chosen with Choose…
    /// that isn't among them.
    private var folderChoices: [String] {
        guard let folder, !folders.contains(folder) else { return folders }
        return folders + [folder]
    }

    /// What would run, once there's a folder to clone into.
    private var request: CloneRequest? {
        guard let folder else { return nil }
        return CloneRequest(
            url: state.url.trimmingCharacters(in: .whitespacesAndNewlines),
            folder: folder,
            name: state.name.trimmingCharacters(in: .whitespacesAndNewlines),
            recursesSubmodules: state.recursesSubmodules
        )
    }

    /// What's in the way, under the fields: a folder that's already there,
    /// which the identity popover's warnings' amber says, or a repository with
    /// that remote that the sidebar already has, which it offers to show
    /// instead.
    @ViewBuilder private func note(problem: CloneRequest.Problem?, existing: ListedRepository?) -> some View {
        if let request, problem == .destinationExists {
            Text("\(request.name) already exists in this folder. Choose a different name or location.")
                .font(.system(size: 12))
                .foregroundStyle(AgentColors.warn)
                .fixedSize(horizontal: false, vertical: true)
        } else if problem == .nameIsNotAFolder {
            Text("Enter a folder name without slashes.")
                .font(.system(size: 12))
                .foregroundStyle(AgentColors.warn)
                .fixedSize(horizontal: false, vertical: true)
        } else if let existing {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(existing.cloning == nil ? "\(existing.name) is already in the sidebar." : "\(existing.name) is already being cloned from this URL.")
                    .font(.system(size: 12))
                    .foregroundStyle(DialogColors.note)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if existing.cloning == nil {
                    Button("Show \(existing.name)") {
                        selection = existing.home
                        dismiss()
                    }
                    .buttonStyle(.contextual)
                    .fixedSize()
                }
            }
        }
    }

    /// Closes the popover and clones, and shows the repository once it's cloned,
    /// unless the window has moved on to another worktree by then.
    private func clone() {
        guard let request, request.problem == nil else { return }
        state.url = ""
        state.name = ""
        state.isNameEdited = false
        dismiss()
        let selection = $selection
        let before = selection.wrappedValue
        Task {
            do {
                let cloned = try await list.clone(request)
                if selection.wrappedValue == before { selection.wrappedValue = cloned }
            } catch is CancellationError {
            } catch {
                showAlert("Can't clone \(request.name)", error)
            }
        }
    }
}

/// What the second line of a repository that's being cloned says, as in
/// `Cloning · receiving objects` and `42%` at the right (decisions 48 and 113).
struct CloneLine: Equatable {
    var progress: CloneProgress
    var isCancelling: Bool

    init(job: CloneJob) {
        progress = job.progress
        isCancelling = job.isCancelling
    }

    init(progress: CloneProgress, isCancelling: Bool = false) {
        self.progress = progress
        self.isCancelling = isCancelling
    }

    var words: String {
        if isCancelling { return "Cancelling clone…" }
        let cloning = progress.submodule.map { "Cloning \($0)" } ?? "Cloning"
        return progress.step.map { cloning + " · " + $0 } ?? cloning + "…"
    }

    var end: String? {
        isCancelling ? nil : progress.percent.map { "\($0)%" }
    }

    var help: String {
        isCancelling ? "Cancelling the clone and removing downloaded files." : "Cloning this repository. To cancel, open its sidebar menu."
    }

    /// What VoiceOver says.
    var spoken: String {
        [words, end].compactMap(\.self).joined(separator: " ")
    }
}
