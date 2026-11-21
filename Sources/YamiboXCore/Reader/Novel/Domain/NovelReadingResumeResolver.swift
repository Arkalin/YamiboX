import Foundation

public enum NovelReadingResumeResolver {
    public struct Position: Equatable, Sendable {
        public var view: Int?
        public var authorID: String?
        public var resumePoint: NovelResumePoint?
    }

    public static func resolve(
        progress: NovelReadingProgressRecord?,
        fallbackView: Int? = nil,
        fallbackAuthorID: String? = nil,
        fallbackResumePoint: NovelResumePoint? = nil,
        startsFromBeginning: Bool = false
    ) -> Position {
        let resumePoint = startsFromBeginning ? nil : progress?.novelResumePoint ?? fallbackResumePoint
        return Position(
            view: startsFromBeginning ? 1 : resumePoint?.view ?? progress?.lastView ?? fallbackView,
            authorID: resumePoint?.authorID ?? progress?.authorID ?? fallbackAuthorID,
            resumePoint: resumePoint
        )
    }
}
