import SwiftUI
import YamiboXCore

struct ForumThreadReaderActionBar: View {
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
            .tint(ForumColors.brownDeep)

            Button(action: onFavorite) {
                Label(
                    isFavorited ? L10n.string("forum.thread.favorited") : L10n.string("forum.thread.favorite"),
                    systemImage: isFavorited ? "star.fill" : "star"
                )
                .labelStyle(.iconOnly)
                .foregroundStyle(isFavorited ? ForumColors.orangeAccent : ForumColors.brownEmphasis)
                .frame(width: 42, height: 34)
            }
            .buttonStyle(.bordered)
            .tint(ForumColors.brownEmphasis)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in onFavoriteLongPress() })
            .accessibilityLabel(
                isFavorited ? L10n.string("forum.thread.favorited") : L10n.string("forum.thread.favorite")
            )

            ShareLink(item: Self.threadURL(for: thread)) {
                Label(L10n.string("forum.thread.share"), systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(ForumColors.brownEmphasis)
                    .frame(width: 42, height: 34)
            }
            .buttonStyle(.bordered)
            .tint(ForumColors.brownEmphasis)
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
