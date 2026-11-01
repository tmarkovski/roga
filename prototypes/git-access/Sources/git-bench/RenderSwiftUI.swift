import SwiftUI

private let lanePalette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red]

/// The rows as a collection of stable commit IDs, built on demand from the model's ID array so
/// that SwiftUI identifies rows by commit rather than by position.
struct HistoryRows: RandomAccessCollection {
    struct Element: Identifiable {
        let id: Int32
        let row: Int
    }

    let ids: [Int32]
    var startIndex: Int { 0 }
    var endIndex: Int { ids.count }
    subscript(position: Int) -> Element { Element(id: ids[position], row: position) }
}

/// Shows the history in a SwiftUI `List`.
struct ListHistoryView: View {
    @Bindable var model: HistoryModel

    var body: some View {
        List(HistoryRows(ids: model.ids), selection: $model.selection) { element in
            HistoryRow(model: model, id: element.id, row: element.row, highlightsSelection: false)
                .listRowInsets(EdgeInsets())
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, RowMetrics.height)
    }
}

/// Shows the history in a `LazyVStack` inside a `ScrollView`.
struct LazyStackHistoryView: View {
    let model: HistoryModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(HistoryRows(ids: model.ids)) { element in
                    HistoryRow(model: model, id: element.id, row: element.row, highlightsSelection: true)
                }
            }
        }
    }
}

struct HistoryRow: View {
    let model: HistoryModel
    let id: Int32
    let row: Int
    /// A `LazyVStack` has no selection of its own, so its rows draw the highlight themselves.
    let highlightsSelection: Bool

    var body: some View {
        let (column, width) = model.lanes(row)
        HStack(spacing: 8) {
            Canvas { context, size in
                for lane in 0..<width {
                    var path = Path()
                    path.move(to: CGPoint(x: RowMetrics.laneX(lane), y: 0))
                    path.addLine(to: CGPoint(x: RowMetrics.laneX(lane), y: size.height))
                    context.stroke(path, with: .color(lanePalette[lane % lanePalette.count]), lineWidth: 2)
                }
                let dot = CGRect(x: RowMetrics.laneX(column) - 4, y: size.height / 2 - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dot), with: .color(lanePalette[column % lanePalette.count]))
            }
            .frame(width: RowMetrics.graphWidth)
            Text(model.subject(row))
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(model.author(row))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
            Text(model.date(row))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
        }
        .frame(height: RowMetrics.height)
        .background(highlightsSelection && model.selection == id ? Color.accentColor.opacity(0.3) : .clear)
        .onAppear {
            firstRowDrawn = true
            rowsDrawn += 1
        }
    }
}
