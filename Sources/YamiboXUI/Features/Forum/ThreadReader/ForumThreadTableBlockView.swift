import SwiftUI
import YamiboXCore

struct ForumThreadTableBlockView: View {
    @Environment(\.forumTheme) private var theme
    let rows: [[ForumThreadTableCell]]
    let refererURL: URL
    let onImageTap: (String, URL, String?, URL) -> Void
    let onURLTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(rows[rowIndex].indices, id: \.self) { cellIndex in
                        ForumThreadTableCellView(
                            cell: rows[rowIndex][cellIndex],
                            refererURL: refererURL,
                            onImageTap: onImageTap,
                            onURLTap: onURLTap
                        )
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.divider.opacity(0.25), lineWidth: 1)
        }
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
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cell.isHeader ? theme.selectedFill.opacity(0.5) : theme.pageBackground)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(theme.divider.opacity(0.2))
                    .frame(width: 1)
            }
    }
}
