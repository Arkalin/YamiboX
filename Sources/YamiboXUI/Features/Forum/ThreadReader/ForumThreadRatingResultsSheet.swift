import SwiftUI
import YamiboXCore

struct ForumThreadRatingResultsRequest: Identifiable, Equatable {
    var postID: String

    var id: String {
        postID
    }
}

@MainActor
@Observable
final class ForumThreadRatingResultsSheetModel {
    private(set) var page: ForumThreadRatingResultsPage?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let postID: String
    @ObservationIgnored private let load: (String) async throws -> ForumThreadRatingResultsPage

    init(postID: String, load: @escaping (String) async throws -> ForumThreadRatingResultsPage) {
        self.postID = postID
        self.load = load
    }

    func loadPage() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            page = try await load(postID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ForumThreadRatingResultsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ForumThreadRatingResultsSheetModel

    let onUserTap: (String, String?) -> Void

    init(
        request: ForumThreadRatingResultsRequest,
        load: @escaping (String) async throws -> ForumThreadRatingResultsPage,
        onUserTap: @escaping (String, String?) -> Void
    ) {
        _model = State(wrappedValue: ForumThreadRatingResultsSheetModel(postID: request.postID, load: load))
        self.onUserTap = onUserTap
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.page == nil {
                    ForumContentLoadingView()
                } else if let errorMessage = model.errorMessage, model.page == nil {
                    ForumContentErrorView(message: errorMessage) {
                        Task {
                            await model.loadPage()
                        }
                    }
                } else if let page = model.page {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(L10n.string("forum.thread.rating_participants_format", page.ratings.count))
                                .font(.caption)
                                .foregroundStyle(ForumColors.secondaryText)
                            Spacer(minLength: 0)
                            if let totalScore = page.totalScore {
                                Text(L10n.string("forum.thread.ratings_total_format", totalScore))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(ForumColors.orangeAccent)
                            }
                        }

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(page.ratings) { rating in
                                    ForumThreadRatingResultRow(rating: rating, onUserTap: openUser)
                                    Divider()
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(L10n.string("forum.thread.ratings_all"))
            .yamiboInlineNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.close")) {
                        dismiss()
                    }
                }
            }
            .topRefreshIndicator(isVisible: model.isLoading && model.page != nil)
        }
        .task {
            await model.loadPage()
        }
    }

    private func openUser(uid: String, name: String?) {
        dismiss()
        onUserTap(uid, name)
    }
}

private struct ForumThreadRatingResultRow: View {
    let rating: ForumThreadRating
    let onUserTap: (String, String?) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let uid = rating.user.uid {
                Button(rating.user.name) {
                    onUserTap(uid, rating.user.name)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ForumColors.brownPrimary)
                .frame(maxWidth: 120, alignment: .leading)
            } else {
                Text(rating.user.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ForumColors.secondaryText)
                    .frame(maxWidth: 120, alignment: .leading)
            }

            Text(rating.scoreText)
                .font(.caption.weight(.bold))
                .foregroundStyle(ForumColors.orangeAccent)
                .frame(width: 48, alignment: .leading)

            Text(rating.reason ?? "")
                .font(.caption)
                .foregroundStyle(ForumColors.textDark)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
    }
}
