import GitCore
import SwiftUI

/// What the diff panel shows of a submodule's row, in the place of a diff: a
/// band that says how the pointer moves, the submodule's own commits between the
/// two, or its uncommitted files, and what the buttons would do (decision 75).
/// git's own diff of a submodule is two `Subproject commit` lines, which say
/// none of that.
struct SubmoduleReportView: View {
    let report: SubmoduleReport
    /// Whether the panel is wide enough for each commit's author and date. In a
    /// narrower one they give way, the author first, so that the subject keeps
    /// its room.
    @State private var showsAuthors = true
    @State private var showsDates = true

    nonisolated private static let widthForAuthors = 520.0
    nonisolated private static let widthForDates = 380.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(report.sections) { section in
                    band(section)
                    // Rows of one height each, so that a lazy stack knows how
                    // tall it is, as the lists of files do.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(section.commits.enumerated()), id: \.element.id) { index, commit in
                            SubmoduleCommitRow(
                                commit: commit,
                                joinsAbove: index > 0,
                                joinsBelow: index < section.commits.count - 1,
                                showsAuthor: showsAuthors,
                                showsDate: showsDates
                            )
                        }
                    }
                    if section.moreCommits > 0 {
                        more("and \(section.moreCommits.formatted()) more \(section.moreCommits == 1 ? "commit" : "commits")")
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(section.files, id: \.path) { file in
                            SubmoduleFileRow(file: file)
                        }
                    }
                    if section.moreFiles > 0 {
                        more("and \(section.moreFiles.formatted()) more \(section.moreFiles == 1 ? "file" : "files")")
                    }
                }
                ForEach(report.notes, id: \.self) { note in
                    Text(note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
        }
        .onGeometryChange(for: [Bool].self) { geometry in
            [geometry.size.width >= Self.widthForAuthors, geometry.size.width >= Self.widthForDates]
        } action: { room in
            showsAuthors = room[0]
            showsDates = room[1]
        }
    }

    /// The band over a list, with a hunk header's tint, or the tint of a removed
    /// line when it says the pointer goes back.
    private func band(_ section: SubmoduleReport.Section) -> some View {
        Text(section.band)
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(section.goesBack ? AnyShapeStyle(Palette.red) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(section.goesBack ? Palette.red.opacity(0.12) : Color(nsColor: .systemBlue).opacity(0.09))
            .padding(.bottom, 4)
            .padding(.top, section.id == 0 ? 0 : 8)
            .help(section.band)
            .accessibilityAddTraits(.isHeader)
    }

    private func more(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.leading, 36)
            .frame(height: SubmoduleCommitRow.height)
    }
}

/// One of a submodule's own commits: a dot on a line, as in history, then its
/// short hash, subject, author and date.
private struct SubmoduleCommitRow: View {
    let commit: SubmoduleDetails.Commit
    /// Whether the line runs up to the commit above, and down to the one below.
    let joinsAbove: Bool
    let joinsBelow: Bool
    let showsAuthor: Bool
    let showsDate: Bool

    static let height = 26.0
    private static let dateWidth = 126.0

    var body: some View {
        let date = RepositoryModel.format(commit.time, now: Date())
        HStack(spacing: 8) {
            Dot(joinsAbove: joinsAbove, joinsBelow: joinsBelow)
                .frame(width: 22, height: Self.height)
            Text(commit.id.hex.prefix(8))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(commit.subject)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsAuthor {
                Text(commit.author)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 110, alignment: .leading)
            }
            if showsDate {
                // As wide as a date with its time, so that the authors line up
                // from one row to the next whatever each row's date is.
                Text(date)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: Self.dateWidth, alignment: .trailing)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(height: Self.height)
        .help("\(commit.id.hex)\n\(commit.subject)\n\(commit.author), \(date)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(commit.id.hex.prefix(8)) \(commit.subject), \(commit.author), \(date)")
    }

    /// The commit's dot, in the first lane's color, with the line through it.
    private struct Dot: View {
        let joinsAbove: Bool
        let joinsBelow: Bool

        var body: some View {
            Canvas { context, size in
                let middle = CGPoint(x: size.width / 2, y: size.height / 2)
                let color = Palette.lane(0)
                var line = Path()
                line.move(to: CGPoint(x: middle.x, y: joinsAbove ? 0 : middle.y))
                line.addLine(to: CGPoint(x: middle.x, y: joinsBelow ? size.height : middle.y))
                context.stroke(line, with: .color(color), lineWidth: 1.5)
                context.fill(Path(ellipseIn: CGRect(x: middle.x - 3.2, y: middle.y - 3.2, width: 6.4, height: 6.4)), with: .color(color))
            }
            .accessibilityHidden(true)
        }
    }
}

/// One of a submodule's own uncommitted files: its status and its path, with no
/// diff, because its changes belong to the submodule's repository.
private struct SubmoduleFileRow: View {
    let file: SubmoduleDetails.File

    var body: some View {
        let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
        let folder = file.path.count > name.count ? String(file.path.dropLast(name.count + 1)) : ""
        HStack(spacing: 8) {
            Text(file.status.letter)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(file.status.color)
                .frame(width: 12)
            Text(name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(folder)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: SubmoduleCommitRow.height)
        .help(file.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.status.word) \(file.path)")
    }
}
