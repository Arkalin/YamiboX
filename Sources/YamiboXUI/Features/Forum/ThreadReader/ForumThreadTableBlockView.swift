import SwiftUI
import YamiboXCore

struct ForumThreadTableBlockView: View {
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
                .stroke(ForumColors.brownLight.opacity(0.25), lineWidth: 1)
        }
    }
}

private struct ForumThreadTableCellView: View {
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
            .background(cell.isHeader ? ForumColors.accentFill.opacity(0.5) : ForumColors.creamBackground)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(ForumColors.brownLight.opacity(0.2))
                    .frame(width: 1)
            }
    }
}
