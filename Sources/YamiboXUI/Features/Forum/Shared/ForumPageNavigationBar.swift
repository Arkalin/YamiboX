import SwiftUI
import YamiboXCore

/// The previous/next pager shown under forum-style paged lists. The page
/// number always comes from the caller (`currentPage`) rather than
/// `navigation` because some screens track an optimistic page separately
/// from the last parsed one.
struct ForumPageNavigationBar: View {
    let navigation: ForumPageNavigation?
    let currentPage: Int
    let goToPage: (Int) -> Void
    /// Hides the whole bar for single-page content instead of rendering a
    /// disabled pager.
    var hidesOnSinglePage = false

    var body: some View {
        if let navigation, isVisible(navigation) {
            HStack(spacing: 12) {
                Button {
                    goToPage(currentPage - 1)
                } label: {
                    Label(L10n.string("forum.board.previous_page"), systemImage: "chevron.left")
                }
                .disabled(currentPage <= 1)

                Spacer()

                Text(pageText(navigation))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ForumColors.secondaryText)

                Spacer()

                Button {
                    goToPage(currentPage + 1)
                } label: {
                    Label(L10n.string("forum.board.next_page"), systemImage: "chevron.right")
                }
                .labelStyle(.titleAndIcon)
                .disabled(navigation.totalPages.map { currentPage >= $0 } ?? false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(ForumColors.brownEmphasis)
        }
    }

    private func isVisible(_ navigation: ForumPageNavigation) -> Bool {
        !hidesOnSinglePage || (navigation.totalPages ?? navigation.currentPage) > 1
    }

    private func pageText(_ navigation: ForumPageNavigation) -> String {
        if let totalPages = navigation.totalPages {
            return L10n.string("forum.board.page_count", currentPage, totalPages)
        }
        return L10n.string("forum.board.current_page", currentPage)
    }
}
