import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

private enum SheetModelTestError: LocalizedError {
    case plannedFailure

    var errorDescription: String? {
        "planned failure"
    }
}

@MainActor
@Test func ratingResultsSheetModelLoadsPageForItsPost() async {
    var requestedPostIDs: [String] = []
    let model = ForumThreadRatingResultsSheetModel(postID: "4001") { postID in
        requestedPostIDs.append(postID)
        return ForumThreadRatingResultsPage(ratings: [], totalScore: 2)
    }

    await model.loadPage()

    #expect(requestedPostIDs == ["4001"])
    #expect(model.page?.totalScore == 2)
    #expect(model.errorMessage == nil)
    #expect(!model.isLoading)
}

@MainActor
@Test func ratingResultsSheetModelSurfacesLoadFailure() async {
    let model = ForumThreadRatingResultsSheetModel(postID: "4001") { _ in
        throw SheetModelTestError.plannedFailure
    }

    await model.loadPage()

    #expect(model.page == nil)
    #expect(model.errorMessage == SheetModelTestError.plannedFailure.localizedDescription)
    #expect(!model.isLoading)
}

@MainActor
@Test func pollVotersSheetModelSelectingOptionResetsPageNumber() async {
    var requests: [String] = []
    let model = ForumThreadPollVotersSheetModel(optionID: "opt-1") { optionID, page in
        requests.append("\(optionID ?? "nil"):\(page)")
        return ForumThreadPollVotersPage(threadID: "704", selectedOptionID: optionID, pollOptions: [], voters: [])
    }

    await model.loadPage()
    model.goToPage(3)
    await model.loadPage()
    model.selectOption("opt-2")
    await model.loadPage()

    #expect(model.pageNumber == 1)
    #expect(model.selectedOptionID == "opt-2")
    #expect(requests == ["opt-1:1", "opt-1:3", "opt-2:1"])
}

@MainActor
@Test func rateSheetModelRejectsNonIntegerScoreWithoutSubmitting() async {
    var submitted = false
    let model = ForumThreadRateSheetModel(
        postID: "4001",
        loadOptions: { _ in ForumThreadRateOptionsPage(availableScores: [], defaultReasons: []) },
        submit: { _, _, _, _ in
            submitted = true
            return ""
        }
    )
    model.scoreText = " abc "

    let shouldDismiss = await model.submitRate()

    #expect(!shouldDismiss)
    #expect(!submitted)
    #expect(model.errorMessage == L10n.string("forum.thread.rate_score_invalid"))
}

@MainActor
@Test func rateSheetModelSubmitsTrimmedScoreAndReportsDismissal() async {
    var recorded: [String] = []
    let model = ForumThreadRateSheetModel(
        postID: "4001",
        loadOptions: { _ in ForumThreadRateOptionsPage(availableScores: [], defaultReasons: []) },
        submit: { postID, score, reason, noticeAuthor in
            recorded.append("\(postID)|\(score)|\(reason)|\(noticeAuthor)")
            return "评分成功"
        }
    )
    model.scoreText = " 2 "
    model.reason = "好文"
    model.noticeAuthor = true

    let shouldDismiss = await model.submitRate()

    #expect(shouldDismiss)
    #expect(recorded == ["4001|2|好文|true"])
    #expect(model.errorMessage == nil)
    #expect(!model.isSubmitting)
}

@MainActor
@Test func rateSheetModelSurfacesSubmitFailureAndStaysPresented() async {
    let model = ForumThreadRateSheetModel(
        postID: "4001",
        loadOptions: { _ in ForumThreadRateOptionsPage(availableScores: [], defaultReasons: []) },
        submit: { _, _, _, _ in throw SheetModelTestError.plannedFailure }
    )
    model.scoreText = "1"

    let shouldDismiss = await model.submitRate()

    #expect(!shouldDismiss)
    #expect(model.errorMessage == SheetModelTestError.plannedFailure.localizedDescription)
    #expect(!model.isSubmitting)
}

@MainActor
@Test func rateSheetModelLoadOptionsFailureShowsHintInsteadOfOptions() async {
    let model = ForumThreadRateSheetModel(
        postID: "4001",
        loadOptions: { _ in throw SheetModelTestError.plannedFailure },
        submit: { _, _, _, _ in "" }
    )

    await model.loadRateOptions()

    #expect(model.options == nil)
    #expect(model.hintMessage == L10n.string("forum.thread.rate_options_failed"))
    #expect(!model.isLoadingOptions)
}

@MainActor
@Test func commentSheetModelSubmitsMessageAndBlocksBlankInput() async {
    var recorded: [String] = []
    let model = ForumThreadCommentSheetModel(postID: "4001") { postID, message in
        recorded.append("\(postID)|\(message)")
        return "评论成功"
    }

    #expect(!model.canSubmit)
    model.message = "  "
    #expect(!model.canSubmit)
    model.message = "评论内容"
    #expect(model.canSubmit)

    let shouldDismiss = await model.submitComment()

    #expect(shouldDismiss)
    #expect(recorded == ["4001|评论内容"])
    #expect(!model.isSubmitting)
}

@MainActor
@Test func commentSheetModelSurfacesSubmitFailure() async {
    let model = ForumThreadCommentSheetModel(postID: "4001") { _, _ in
        throw SheetModelTestError.plannedFailure
    }
    model.message = "评论内容"

    let shouldDismiss = await model.submitComment()

    #expect(!shouldDismiss)
    #expect(model.errorMessage == SheetModelTestError.plannedFailure.localizedDescription)
}
