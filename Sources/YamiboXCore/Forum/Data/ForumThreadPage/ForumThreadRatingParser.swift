import Foundation

/// Parses rating ("评分") data: the per-post rating log, the full rating-results
/// popout rows, and the rate-options form.
enum ForumThreadRatingParser {
    static func ratingBlock(in container: Element, postID: String) throws -> ForumThreadRatingBlock? {
        let candidates = try (
            container.selectAll("#ratelog_\(postID)") + container.selectAll("[id^=ratelog_], .ratelog, .ratl")
        ).deduplicatedByDOMIdentity()
        guard let element = candidates.first else { return nil }

        let allRatingsURL = element.firstURL("a[href*='action=viewratings']")
        let ratings = ratingRows(in: element)
        guard !ratings.isEmpty || allRatingsURL != nil else { return nil }
        let totalScore = explicitTotalScore(in: try element.text()) ?? ratings.compactMap(scoreValue).reduce(0, +)
        let participantCount = participantCount(in: try element.text()) ?? ratings.count
        return ForumThreadRatingBlock(
            participantCount: participantCount,
            totalScore: totalScore,
            ratings: ratings,
            allRatingsURL: allRatingsURL
        )
    }

    static func ratingRows(in element: Element) -> [ForumThreadRating] {
        element.selectAll("li, tr").compactMap(ratingRow)
    }

    /// Total score of a rating-results page: the explicitly printed total when present,
    /// otherwise the sum of the individual scores.
    static func totalScore(pageText: String, ratings: [ForumThreadRating]) -> Int {
        explicitTotalScore(in: pageText) ?? ratings.compactMap(scoreValue).reduce(0, +)
    }

    /// Scores and default reasons offered by the rate-options form.
    static func rateOptionsPage(in document: Document) -> ForumThreadRateOptionsPage {
        let scores = document.selectAll("select#rate1 option")
            .compactMap { option in
                (option.attrText("value") ?? option.normalizedText().nilIfBlank)
                    .flatMap(Int.init)
            }
        let reasons = document.selectAll("select#reason option")
            .compactMap { option in
                option.attrText("value") ?? option.normalizedText().nilIfBlank
            }
        return ForumThreadRateOptionsPage(availableScores: scores, defaultReasons: reasons)
    }

    private static func ratingRow(_ row: Element) -> ForumThreadRating? {
        let text = row.normalizedText()
        guard !text.isEmpty,
              !text.contains("参与人数"),
              !text.contains("參與人數"),
              !text.contains("查看全部"),
              !text.localizedCaseInsensitiveContains("viewratings") else {
            return nil
        }

        let cells = row.selectAll("td, th, div")
        guard cells.count >= 2 else { return nil }
        let first = cells[0]
        let userLink = first.selectFirst("a[href*='uid='], a[href*='space-uid-'], a")
        let userName = (userLink ?? first).normalizedText()
            .nilIfBlank
            ?? L10n.string("forum.thread.unknown_author")
        let scoreText = cells[1].normalizedText()
        guard scoreText.contains("+") || scoreText.contains("-") || Int(scoreText) != nil else {
            return nil
        }
        let reason = cells.dropFirst(2)
            .map { $0.normalizedText() }
            .joined(separator: " ")
            .nilIfBlank
        let uid = userLink.flatMap { ForumUserIDParser.userID(fromHref: (try? $0.attr("href")) ?? "") }
        return ForumThreadRating(
            user: BlogReaderUser(uid: uid, name: userName, avatarURL: nil),
            scoreText: scoreText,
            reason: reason
        )
    }

    private static func explicitTotalScore(in text: String) -> Int? {
        HTMLTextExtractor.firstMatch(pattern: #"(?:总积分|總積分|积分|積分)\D*([+-]?\d+)"#, in: text)?
            .dropFirst()
            .first
            .flatMap(Int.init)
    }

    private static func participantCount(in text: String) -> Int? {
        HTMLTextExtractor.firstMatch(pattern: #"(?:参与人数|參與人數|共)\D*(\d+)\D*(?:人)?"#, in: text)?
            .dropFirst()
            .first
            .flatMap(Int.init)
    }

    private static func scoreValue(_ rating: ForumThreadRating) -> Int? {
        HTMLTextExtractor.firstMatch(pattern: #"([+-]?\d+)"#, in: rating.scoreText)?
            .dropFirst()
            .first
            .flatMap(Int.init)
    }
}
