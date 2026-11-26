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
/// 113). It shows the exact command as it's filled in (decision 29), and says
/// what's in the way before Clone can be pressed. Clone closes the popover, and
/// the repository's row in the sidebar says how far along git is.
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

    /// The pop-up's tag for Choose…, which can't be a folder's path.
    private static let chooseTag = "\u{0}choose"

    var body: some View {
        let request = request
        let problem = request?.problem
        let existing = list.repository(withRemote: state.url)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                row("URL") {
                    TextField("https://github.com/owner/repository", text: Binding { state.url } set: { state.setURL($0) })
                        .textFieldStyle(.roundedBorder)
                        .focused($isURLFocused)
                        .onSubmit(clone)
                        .accessibilityLabel("URL")
                }
                row("Name") {
                    TextField("Folder name", text: Binding { state.name } set: { state.setName($0) })
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(clone)
                        .accessibilityLabel("Name")
                }
                row("Folder") {
                    folderPicker
                }
                row(nil) {
                    Toggle("Clone submodules too", isOn: $state.recursesSubmodules)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            note(problem: problem, existing: existing)
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
            Group {
                if let request, !request.url.isEmpty {
                    CommandBlock(lines: [.command(request.arguments)], isCompact: true)
                } else {
                    CommandBlock(lines: [.comment("The command shows here once there's a URL.")], isCompact: true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
            HStack {
                Spacer()
                Button("Clone", action: clone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(request == nil || problem != nil)
            }
            .padding(12)
        }
        .task {
            // Once the field is in the popover's window. Switching to the form
            // from the segmented control puts it there a moment after the form
            // appears, and setting the focus before then does nothing.
            try? await Task.sleep(for: .milliseconds(50))
            isURLFocused = true
        }
    }

    /// A row of the form: its label, right-aligned in a column as wide as the
    /// longest, and what it labels, as wide as the rest of the popover.
    private func row(_ title: String?, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(title ?? "")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .accessibilityHidden(true)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The folder it clones into, or the usual one, which is the folder most
    /// listed repositories are in.
    private var folder: String? {
        state.folder ?? folders.first
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

    /// A pop-up of the folders Add Repositories looks in, and Choose… for
    /// another, which opens the open panel.
    @ViewBuilder private var folderPicker: some View {
        let choices = folder.map { folders.contains($0) ? folders : folders + [$0] } ?? folders
        // With nothing listed there's no folder to offer, and a pop-up showing
        // Choose… couldn't be used to choose it again.
        if choices.isEmpty {
            Button("Choose…", action: chooseFolder)
                .accessibilityLabel("Choose a Folder")
        } else {
            folderPopUp(choices)
        }
    }

    private func folderPopUp(_ choices: [String]) -> some View {
        Picker("Folder", selection: Binding {
            folder ?? Self.chooseTag
        } set: { picked in
            if picked == Self.chooseTag {
                chooseFolder()
            } else {
                state.folder = picked
            }
        }) {
            ForEach(choices, id: \.self) { folder in
                Text((folder as NSString).abbreviatingWithTildeInPath).tag(folder)
            }
            Divider()
            Text("Choose…").tag(Self.chooseTag)
        }
        .labelsHidden()
        .accessibilityLabel("Folder")
    }

    /// What's in the way, under the fields: a folder that's already there, or
    /// a repository with that remote that the sidebar already has, which it
    /// offers to show instead.
    @ViewBuilder private func note(problem: CloneRequest.Problem?, existing: ListedRepository?) -> some View {
        if let request, problem == .destinationExists {
            Text("\((request.destination as NSString).abbreviatingWithTildeInPath) is already there. Choose another name or folder.")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if problem == .nameIsNotAFolder {
            Text("The name has to be one folder, without a slash.")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let existing {
            HStack(spacing: 6) {
                Text(existing.cloning == nil ? "The sidebar already has \(existing.name) from this URL." : "\(existing.name) is already being cloned from this URL.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if existing.cloning == nil {
                    Button("Show") {
                        selection = existing.home
                        dismiss()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
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
        isCancelling ? "git is stopping, and deleting what it cloned." : "git is cloning this repository. Its menu can cancel the clone."
    }

    /// What VoiceOver says.
    var spoken: String {
        [words, end].compactMap(\.self).joined(separator: " ")
    }
}
