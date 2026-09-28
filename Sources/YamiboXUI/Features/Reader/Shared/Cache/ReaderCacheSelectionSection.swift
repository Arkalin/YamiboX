import SwiftUI
import YamiboXCore

/// Shared selection behavior; each reader continues to own its row data and layout.
struct ReaderCacheSelectionSection<Row: Identifiable, RowContent: View>: View {
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
            ReaderCacheSelectionHeader(
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

enum ReaderCacheDisplayState {
    case cached, uncached, caching

    var systemImage: String {
        switch self {
        case .cached: "checkmark.seal.fill"
        case .uncached: "icloud"
        case .caching: "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .cached: .green
        case .uncached: .secondary
        case .caching: .orange
        }
    }
}

struct ReaderCacheStateBadge: View {
    let state: ReaderCacheDisplayState
    let uncachedTitle: String
    let cachingTitle: String
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
        case .cached: L10n.string("reader.cached")
        case .uncached: uncachedTitle
        case .caching: cachingTitle
        }
    }
}
