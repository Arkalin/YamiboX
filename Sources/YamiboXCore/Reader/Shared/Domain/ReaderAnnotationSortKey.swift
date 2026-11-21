import Foundation

public enum ReaderAnnotationSortKey {
    static let offsetLimit: Int64 = 999_999
    static let occurrenceLimit: Int64 = 999
    static let chapterOrdinalLimit: Int64 = 9_999
    static let viewLimit: Int64 = 9_999

    static let occurrenceWeight: Int64 = 1_000_000
    static let chapterOrdinalWeight: Int64 = 1_000_000_000
    static let viewWeight: Int64 = 10_000_000_000_000

    public static func novel(
        view: Int,
        chapterOrdinal: Int,
        textOccurrence: Int,
        displayedTextOffset: Int
    ) -> Int64 {
        clamp(Int64(view), viewLimit) * viewWeight
            + clamp(Int64(chapterOrdinal), chapterOrdinalLimit) * chapterOrdinalWeight
            + clamp(Int64(textOccurrence), occurrenceLimit) * occurrenceWeight
            + clamp(Int64(displayedTextOffset), offsetLimit)
    }

    public static func novel(
        view: Int,
        chapterOrdinal: Int,
        textSegmentIdentity: NovelTextSegmentIdentity?,
        displayedTextOffset: Int
    ) -> Int64 {
        let occurrence = textSegmentIdentity
            .flatMap { NovelSegmentIdentityParser.occurrence(of: $0.rawValue) } ?? 0
        return novel(
            view: view,
            chapterOrdinal: chapterOrdinal,
            textOccurrence: occurrence,
            displayedTextOffset: displayedTextOffset
        )
    }

    public static func manga(globalPageIndex: Int) -> Int64 {
        clamp(Int64(globalPageIndex), offsetLimit)
    }

    private static func clamp(_ value: Int64, _ limit: Int64) -> Int64 {
        min(max(value, 0), limit)
    }
}
