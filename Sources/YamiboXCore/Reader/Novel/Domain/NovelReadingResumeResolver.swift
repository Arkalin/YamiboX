import Foundation

/// Shared position precedence. Entry points retain their own title, source,
/// preview policy and defaults; this type performs no I/O or navigation.
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
        // Starting over discards the position, not the stored author scope.
        let resumePoint = startsFromBeginning ? nil : progress?.novelResumePoint ?? fallbackResumePoint
        return Position(
            view: startsFromBeginning ? 1 : resumePoint?.view ?? progress?.lastView ?? fallbackView,
            authorID: resumePoint?.authorID ?? progress?.authorID ?? fallbackAuthorID,
            resumePoint: resumePoint
        )
    }
}
