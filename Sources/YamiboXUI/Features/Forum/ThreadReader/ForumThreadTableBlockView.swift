import SwiftUI
import YamiboXCore

struct ForumThreadTableBlockView: View {
    @Environment(\.forumTheme) private var theme
    let rows: [[ForumThreadTableCell]]
    let refererURL: URL
    let onImageTap: (String, URL, String?, URL) -> Void
    let onURLTap: (URL) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForumThreadTableGrid(rows: rows, refererURL: refererURL, onImageTap: onImageTap, onURLTap: onURLTap)
            ScrollView(.horizontal) {
                ForumThreadTableGrid(rows: rows, refererURL: refererURL, onImageTap: onImageTap, onURLTap: onURLTap)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.divider.opacity(0.25), lineWidth: 1)
        }
    }
}

private struct ForumThreadTableGrid: View {
    let rows: [[ForumThreadTableCell]]
    let refererURL: URL
    let onImageTap: (String, URL, String?, URL) -> Void
    let onURLTap: (URL) -> Void
    @ScaledMetric(relativeTo: .body) private var minimumColumnWidth: CGFloat = 72

    var body: some View {
        let grid = ForumThreadTableGridPlacement(rows: rows)
        ForumThreadTableLayout(grid: grid, minimumColumnWidth: minimumColumnWidth) {
            ForEach(grid.cells) { placement in
                ForumThreadTableCellView(cell: placement.cell, refererURL: refererURL,
                                        onImageTap: onImageTap, onURLTap: onURLTap)
            }
        }
    }
}

private struct ForumThreadTableGridPlacement {
    struct Cell: Identifiable {
        // Coordinates identify cells in this immutable parsed table, including empty cells.
        let id: String
        let row: Int
        let column: Int
        let columnSpan: Int
        let rowSpan: Int
        let cell: ForumThreadTableCell
    }
    var cells: [Cell] = []
    var columnCount = 1
    var rowCount: Int

    init(rows: [[ForumThreadTableCell]]) {
        rowCount = max(rows.count, 1)
        var occupiedUntil: [Int: Int] = [:]
        for (rowIndex, row) in rows.enumerated() {
            var column = 0
            for (cellIndex, cell) in row.enumerated() {
                let columns = min(max(cell.columnSpan ?? 1, 1), 100)
                let rowSpan = min(max(cell.rowSpan ?? 1, 1), rows.count - rowIndex)
                while (column ..< column + columns).contains(where: { (occupiedUntil[$0] ?? 0) > rowIndex }) {
                    column += 1
                }
                cells.append(Cell(id: "\(rowIndex)-\(cellIndex)", row: rowIndex, column: column,
                                  columnSpan: columns, rowSpan: rowSpan, cell: cell))
                for index in column ..< column + columns { occupiedUntil[index] = rowIndex + rowSpan }
                column += columns
                columnCount = max(columnCount, column)
            }
        }
    }
}

private struct ForumThreadTableLayout: Layout {
    let grid: ForumThreadTableGridPlacement
    let minimumColumnWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let width = max(proposedWidth, CGFloat(grid.columnCount) * minimumColumnWidth)
        let heights = rowHeights(width: width, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columnWidth = bounds.width / CGFloat(grid.columnCount)
        let heights = rowHeights(width: bounds.width, subviews: subviews)
        let offsets = heights.reduce(into: [CGFloat.zero]) { $0.append($0.last! + $1) }
        for (index, cell) in grid.cells.enumerated() where index < subviews.count {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + CGFloat(cell.column) * columnWidth, y: bounds.minY + offsets[cell.row]),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: CGFloat(cell.columnSpan) * columnWidth,
                                           height: offsets[cell.row + cell.rowSpan] - offsets[cell.row])
            )
        }
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let columnWidth = width / CGFloat(grid.columnCount)
        var heights = Array(repeating: CGFloat(0), count: grid.rowCount)
        // Solve ordinary rows first, then distribute the extra height required by spanning cells.
        for index in grid.cells.indices.sorted(by: { grid.cells[$0].rowSpan < grid.cells[$1].rowSpan }) where index < subviews.count {
            let cell = grid.cells[index]
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: CGFloat(cell.columnSpan) * columnWidth, height: nil))
            let range = cell.row ..< cell.row + cell.rowSpan
            let deficit = max(0, size.height - range.reduce(CGFloat.zero) { $0 + heights[$1] })
            for row in range { heights[row] += deficit / CGFloat(cell.rowSpan) }
        }
        return heights
    }
}

private struct ForumThreadTableCellView: View {
    @Environment(\.forumTheme) private var theme
    let cell: ForumThreadTableCell
    let refererURL: URL
    let onImageTap: (String, URL, String?, URL) -> Void
    let onURLTap: (URL) -> Void

    var body: some View {
        ForumThreadContentBlocksView(
            blocks: cell.blocks,
            fallbackText: "",
            refererURL: refererURL,
            onImageTap: onImageTap,
            onURLTap: onURLTap
        )
            .fontWeight(cell.isHeader ? .semibold : .regular)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ForumThreadAuthorColorAdapter.colors(for: ForumThreadTextStyle(backgroundHex: cell.backgroundHex), theme: theme).background
                        ?? (cell.isHeader ? theme.selectedFill.opacity(0.5) : theme.pageBackground))
            .overlay {
                Rectangle()
                    .stroke(theme.divider.opacity(0.2), lineWidth: 0.5)
            }
    }
}
