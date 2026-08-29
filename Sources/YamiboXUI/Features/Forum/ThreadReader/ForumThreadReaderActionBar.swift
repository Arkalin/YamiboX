import SwiftUI
import YamiboXCore

struct ForumThreadReaderActionBar: View {
    @Environment(\.forumTheme) private var theme
    let thread: ThreadIdentity
    let isFavorited: Bool
    let onReply: () -> Void
    let onFavorite: () -> Void
    let onFavoriteLongPress: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onReply) {
                Label(L10n.string("forum.thread.send_reply"), systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accentText)

            Button(action: onFavorite) {
                Label(
                    isFavorited ? L10n.string("forum.thread.favorited") : L10n.string("forum.thread.favorite"),
                    systemImage: isFavorited ? "star.fill" : "star"
                )
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isFavorited ? theme.warning : theme.accentText)
                .frame(width: 42, height: 34)
                .expandedHitTarget()
            }
            .buttonStyle(.bordered)
            .tint(theme.accentText)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in onFavoriteLongPress() })
            .accessibilityLabel(
                isFavorited ? L10n.string("forum.thread.favorited") : L10n.string("forum.thread.favorite")
            )

            ShareLink(item: Self.threadURL(for: thread)) {
                Label(L10n.string("forum.thread.share"), systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(theme.accentText)
                    .frame(width: 42, height: 34)
                    .expandedHitTarget()
            }
            .buttonStyle(.bordered)
            .tint(theme.accentText)
            .accessibilityLabel(L10n.string("forum.thread.share"))
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial)
    }

    private static func threadURL(for thread: ThreadIdentity) -> URL {
        YamiboRoute.threadByID(tid: thread.tid, page: 1, authorID: nil, reverse: false).url
    }
}
