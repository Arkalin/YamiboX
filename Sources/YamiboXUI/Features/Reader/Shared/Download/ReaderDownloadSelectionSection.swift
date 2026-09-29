import SwiftUI
import YamiboXCore

/// Shared selection behavior; each reader continues to own its row data and layout.
struct ReaderDownloadSelectionSection<Row: Identifiable, RowContent: View>: View {
    let rows: [Row]
    let sectionTitle: String
    let emptyTitle: String
    let emptySystemImage: String
    @Binding var isSelecting: Bool
    @Binding var selection: Set<Row.ID>
    let isAllSelected: Bool
    let onToggleAll: () -> Void
    @ViewBuilder var rowContent: (Row, Bool) -> RowContent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReaderDownloadSelectionHeader(
                sectionTitle: sectionTitle,
                isSelecting: isSelecting,
                isAllSelected: isAllSelected,
                isEmpty: rows.isEmpty,
                onToggleAll: onToggleAll,
                onToggleSelectionMode: toggleSelectionMode
            )
            .frame(height: 38, alignment: .center)

            if rows.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptySystemImage)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(rows) { row in
                        rowContent(row, selection.contains(row.id))
                            .selectableCardRow(isSelecting: isSelecting, isSelected: selection.contains(row.id)) {
                                toggleSelection(row.id)
                            }
                    }
                }
            }
        }
    }

    private func toggleSelectionMode() {
        isSelecting.toggle()
        if !isSelecting { selection = [] }
    }

    private func toggleSelection(_ id: Row.ID) {
        if !isSelecting {
            isSelecting = true
            selection.insert(id)
        } else if !selection.insert(id).inserted {
            selection.remove(id)
        }
    }
}

enum ReaderDownloadDisplayState {
    case downloaded, notDownloaded, downloading

    var systemImage: String {
        switch self {
        case .downloaded: "checkmark.seal.fill"
        case .notDownloaded: "icloud"
        case .downloading: "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .downloaded: .green
        case .notDownloaded: .secondary
        case .downloading: .orange
        }
    }
}

struct ReaderDownloadStateBadge: View {
    let state: ReaderDownloadDisplayState
    let notDownloadedTitle: String
    let downloadingTitle: String
    let isDimmed: Bool

    var body: some View {
        Label(title, systemImage: state.systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isDimmed ? Color.secondary.opacity(0.55) : state.tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var title: String {
        switch state {
        case .downloaded: L10n.string("reader.downloaded")
        case .notDownloaded: notDownloadedTitle
        case .downloading: downloadingTitle
        }
    }
}
