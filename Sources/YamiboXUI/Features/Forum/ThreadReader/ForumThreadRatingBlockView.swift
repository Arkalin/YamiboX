import SwiftUI
import YamiboXCore

struct ForumThreadRatingBlockView: View {
    let block: ForumThreadRatingBlock
    let onShowAllRatings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(ratingTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ForumColors.brownPrimary)
                Spacer(minLength: 0)
                if let totalScore = block.totalScore {
                    Text(L10n.string("forum.thread.ratings_total_format", totalScore))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ForumColors.orangeAccent)
                }
            }

            ForEach(block.ratings) { rating in
                HStack(alignment: .top, spacing: 8) {
                    Text(rating.user.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ForumColors.secondaryText)
                        .frame(maxWidth: 92, alignment: .leading)
                    Text(rating.scoreText)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(ForumColors.orangeAccent)
                        .frame(width: 44, alignment: .leading)
                    Text(rating.reason ?? "")
                        .font(.caption)
                        .foregroundStyle(ForumColors.textDark)
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
                .foregroundStyle(ForumColors.brownPrimary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ForumColors.creamBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var ratingTitle: String {
        if let participantCount = block.participantCount {
            return L10n.string("forum.thread.ratings_title_format", participantCount)
        }
        return L10n.string("forum.thread.ratings")
    }
}
