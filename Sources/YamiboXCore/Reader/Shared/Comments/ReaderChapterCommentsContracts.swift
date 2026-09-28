/// Chapter-comment I/O shared by reader assembly and presentation.
public protocol ReaderChapterCommentsLoading: Sendable {
    func loadChapterComments(for target: ReaderChapterCommentTarget) async throws -> ChapterCommentsPage
    func loadMoreChapterComments(for target: ReaderChapterCommentTarget, view: Int) async throws -> ChapterCommentsPage
    func loadRatingReasons(for target: ReaderChapterCommentTarget, request: ChapterCommentRatingRequest) async throws -> [ChapterComment]
}
