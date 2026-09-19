import SwiftUI
import YamiboXCore

/// The previous/next pager shown under forum-style paged lists. The page
/// number always comes from the caller (`currentPage`) rather than
/// `navigation` because some screens track an optimistic page separately
/// from the last parsed one.
struct ForumPageNavigationBar: View {
    @Environment(\.forumTheme) private var theme
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

                pageSelector(navigation)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.secondaryText)

                Spacer()

                Button {
                    goToPage(currentPage + 1)
                } label: {
                    Label(L10n.string("forum.board.next_page"), systemImage: "chevron.right")
                }
                .disabled(navigation.totalPages.map { currentPage >= $0 } ?? false)
            }
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(theme.accentText)
        }
    }

    @ViewBuilder
    private func pageSelector(_ navigation: ForumPageNavigation) -> some View {
        if let totalPages = navigation.totalPages, totalPages > 1 {
            Menu {
                if totalPages <= 50 {
                    pageButtons(in: 1...totalPages)
                } else {
                    ForEach(Array(stride(from: 1, through: totalPages, by: 50)), id: \.self) { start in
                        let end = start + min(49, totalPages - start)
                        Menu {
                            pageButtons(in: start...end)
                        } label: {
                            let title = "\(start.formatted())–\(end.formatted())"
                            if (start...end).contains(currentPage) {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(pageText(navigation))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pageText(navigation))
        } else {
            Text(pageText(navigation))
        }
    }

    private func pageButtons(in pages: ClosedRange<Int>) -> some View {
        ForEach(pages, id: \.self) { page in
            Button {
                guard page != currentPage else { return }
                goToPage(page)
            } label: {
                if page == currentPage {
                    Label(L10n.string("forum.board.current_page", page), systemImage: "checkmark")
                } else {
                    Text(L10n.string("forum.board.current_page", page))
                }
            }
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
