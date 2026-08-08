import SwiftUI
import YamiboXCore

struct ForumThreadRatingBlockView: View {
    @Environment(\.forumTheme) private var theme
    let block: ForumThreadRatingBlock
    let onShowAllRatings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(ratingTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.mutedAccent)
                Spacer(minLength: 0)
                if let totalScore = block.totalScore {
                    Text(L10n.string("forum.thread.ratings_total_format", totalScore))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.warning)
                }
            }

            ForEach(block.ratings) { rating in
                HStack(alignment: .top, spacing: 8) {
                    Text(rating.user.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: 92, alignment: .leading)
                    Text(rating.scoreText)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.warning)
                        .frame(width: 44, alignment: .leading)
                    Text(rating.reason ?? "")
                        .font(.caption)
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if block.allRatingsURL != nil {
                Button {
                    onShowAllRatings()
                } label: {
                    Label(L10n.string("forum.thread.ratings_all"), systemImage: "list.bullet")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.mutedAccent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.pageBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var ratingTitle: String {
        if let participantCount = block.participantCount {
            return L10n.string("forum.thread.ratings_title_format", participantCount)
        }
        return L10n.string("forum.thread.ratings")
    }
}
