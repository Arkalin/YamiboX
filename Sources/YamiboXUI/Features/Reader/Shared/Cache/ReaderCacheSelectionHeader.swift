import SwiftUI
import YamiboXCore

/// Header row above a reader cache list: section label that swaps to a
/// select-all toggle in selection mode, with the select/done button at the
/// trailing edge.
struct ReaderCacheSelectionHeader: View {
    let sectionTitle: String
    let isSelecting: Bool
    let isAllSelected: Bool
    let isEmpty: Bool
    let onToggleAll: () -> Void
    let onToggleSelectionMode: () -> Void

    var body: some View {
        HStack {
            if isSelecting {
                SelectAllToolbarButton(
                    isSelectionComplete: isAllSelected,
                    isDisabled: isEmpty,
                    expandsHitTarget: true,
                    toggle: onToggleAll
                )
                .font(.subheadline.weight(.semibold))
            } else {
                Text(sectionTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            SelectionModeToggleButton(
                isSelecting: isSelecting,
                isDisabled: isEmpty && !isSelecting,
                expandsHitTarget: true,
                toggle: onToggleSelectionMode
            )
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
        }
    }
}
