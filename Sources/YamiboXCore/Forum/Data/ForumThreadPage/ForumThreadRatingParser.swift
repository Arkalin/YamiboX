import Foundation

/// Parses rating ("评分") data: the per-post rating log, the full rating-results
/// popout rows, and the rate-options form.
enum ForumThreadRatingParser {
    static func ratingBlock(in container: Element, postID: String) -> ForumThreadRatingBlock? {
        let candidates = (
            container.selectAll("#ratelog_\(postID)") + container.selectAll("[id^=ratelog_], .ratelog, .ratl")
        ).deduplicatedByDOMIdentity()
        guard let element = candidates.first else { return nil }

        let allRatingsURL = element.firstURL("a[href*='action=viewratings']")
        let ratings = ratingRows(in: element)
        guard !ratings.isEmpty || allRatingsURL != nil else { return nil }
        let totalScore = explicitTotalScore(in: element.text()) ?? ratings.compactMap(scoreValue).reduce(0, +)
        let participantCount = participantCount(in: element.text()) ?? ratings.count
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

    /// Rows of the standalone viewratings float. Its `li.flex-box.mli` rows put
    /// the score BEFORE the user name (sibling `.z` cells, no profile links)
    /// and each reason in its own following single-cell row — a different shape
    /// from the in-thread `#ratelog_` block handled by `ratingRows`.
    static func ratingResultRows(in document: Document) -> [ForumThreadRating] {
        let rows = document.selectAll("li.mli")
        guard !rows.isEmpty else { return ratingRows(in: document) }

        var results: [(user: BlogReaderUser, scoreText: String, reason: String?)] = []
        for row in rows {
            let text = row.normalizedText()
            guard !text.contains("参与人数"),
                  !text.contains("參與人數"),
                  !text.contains("查看全部"),
                  !(text.contains("用户名") || text.contains("用戶名")) else {
                continue
            }
            let cellTexts = row.selectAll(".z").map { $0.normalizedText() }
            if let scoreIndex = cellTexts.firstIndex(where: { floatScoreText(inCell: $0) != nil }),
               let score = floatScoreText(inCell: cellTexts[scoreIndex]) {
                let name = cellTexts.dropFirst(scoreIndex + 1).first { !$0.isEmpty }
                    ?? cellTexts.prefix(scoreIndex).last { !$0.isEmpty }
                let uid = row.selectFirst("a[href*='uid='], a[href*='space-uid-']")
                    .flatMap { ForumUserIDParser.userID(fromHref: $0.attr("href")) }
                results.append((
                    user: BlogReaderUser(
                        uid: uid,
                        name: name ?? L10n.string("forum.thread.unknown_author"),
                        avatarURL: nil
                    ),
                    scoreText: score,
                    reason: nil
                ))
            } else if !results.isEmpty, results[results.count - 1].reason == nil,
                      let reason = (cellTexts.first { !$0.isEmpty } ?? text).nilIfBlank {
                results[results.count - 1].reason = reason
            }
        }
        return results.map { ForumThreadRating(user: $0.user, scoreText: $0.scoreText, reason: $0.reason) }
    }

    /// Total of a viewratings float: the `.o.pns` header total when present.
    static func resultsTotalScore(in document: Document, ratings: [ForumThreadRating]) -> Int {
        if let headerText = document.firstText(".o.pns, .o"),
           let value = HTMLTextExtractor.firstMatch(pattern: #"([+-]?\d+)"#, in: headerText)?
               .first
               .flatMap(Int.init) {
            return value
        }
        return totalScore(pageText: document.text(), ratings: ratings)
    }

    /// Signed score inside a float cell ("积分 + 2 点" → "+2").
    private static func floatScoreText(inCell text: String) -> String? {
        guard let match = HTMLTextExtractor.firstMatch(pattern: #"([+-])\s*(\d+)"#, in: text)?.dropFirst(),
              match.count >= 2 else {
            return nil
        }
        return match.joined()
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
        let uid = userLink.flatMap { ForumUserIDParser.userID(fromHref: $0.attr("href")) }
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
