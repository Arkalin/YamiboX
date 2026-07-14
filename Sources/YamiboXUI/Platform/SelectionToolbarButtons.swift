import SwiftUI
import YamiboXCore

/// Top-bar counterpart of `SelectionBottomToolbar`: the "select all /
/// invert selection" toggle shown while selection mode is active.
struct SelectAllToolbarButton: View {
    let isSelectionComplete: Bool
    var isDisabled = false
    /// Set inside custom (non-toolbar) headers, where the bare text would
    /// otherwise be a sub-44pt target.
    var expandsHitTarget = false
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            if expandsHitTarget {
                Text(title)
                    .expandedHitTarget(width: 0)
            } else {
                Text(title)
            }
        }
        .disabled(isDisabled)
        .accessibilityLabel(title)
    }

    private var title: String {
        isSelectionComplete
            ? L10n.string("common.invert_selection")
            : L10n.string("common.select_all")
    }
}

/// The "select ⇄ done" button that enters and leaves selection mode.
struct SelectionModeToggleButton: View {
    let isSelecting: Bool
    var isDisabled = false
    var expandsHitTarget = false
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            if expandsHitTarget {
                Text(title)
                    .expandedHitTarget(width: 0)
            } else {
                Text(title)
            }
        }
        .disabled(isDisabled)
        .accessibilityLabel(title)
    }

    private var title: String {
        isSelecting ? L10n.string("common.done") : L10n.string("common.select")
    }
}
