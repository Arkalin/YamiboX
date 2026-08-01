import Foundation

/// Builds the persisted linear "book order" key shared by bookmarks and (from
/// the anchor refactor onward) Like Items.
///
/// Why a stored scalar rather than comparing anchors on the fly: anchor
/// comparison is only defined *within* one chapter
/// (`NovelLikeTextEndpointOrdering.compare` returns nil across chapters), and
/// resolving the order of two posts that share a forum page needs the novel
/// directory — which the annotation panel, and any device that merely synced
/// the rows, may not have loaded. Apple Books solves this the same way, with
/// `ZPLLOCATIONRANGESTART`.
///
/// The key packs four fields into one `Int64` by fixed decimal weight. Every
/// component is clamped rather than wrapped: a value past its band would
/// otherwise carry into the band above it and reorder unrelated rows.
public enum ReaderAnnotationSortKey {
    /// Digit widths, most significant first. `view` and `chapterOrdinal` get
    /// four digits each (a 9999-page thread is ~150k posts), text occurrence
    /// three (segments per chapter are split only by illustrations), and the
    /// character offset six. Total worst case is 9999e13 ≈ 1.0e17, comfortably
    /// inside `Int64`.
    static let offsetLimit: Int64 = 999_999
    static let occurrenceLimit: Int64 = 999
    static let chapterOrdinalLimit: Int64 = 9_999
    static let viewLimit: Int64 = 9_999

    static let occurrenceWeight: Int64 = 1_000_000
    /// Exposed because `LikeSortKey` composes a manga key from a chapter
    /// ordinal plus a page index rather than a single global index.
    static let chapterOrdinalWeight: Int64 = 1_000_000_000
    static let viewWeight: Int64 = 10_000_000_000_000

    /// Key for a position in a novel. `textOccurrence` is the `N` in a segment
    /// identity's trailing `#text:N` / `#image:N`, which is document order
    /// within the chapter.
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

    /// Key for a position in a novel, taking the text occurrence straight off a
    /// segment identity. Falls back to occurrence 0 when the identity carries
    /// no `#text:N` suffix, which only happens for content the reader could not
    /// give a semantic position to in the first place.
    public static func novel(
        view: Int,
        chapterOrdinal: Int,
        textSegmentIdentity: NovelTextSegmentIdentity?,
        displayedTextOffset: Int
    ) -> Int64 {
        let occurrence = textSegmentIdentity
            .flatMap { NovelLikeTextEndpointOrdering.occurrence(of: $0.rawValue) } ?? 0
        return novel(
            view: view,
            chapterOrdinal: chapterOrdinal,
            textOccurrence: occurrence,
            displayedTextOffset: displayedTextOffset
        )
    }

    /// Key for a manga page. No packing is needed: `globalIndex` is already
    /// the page's position across the whole work, so it is reading order.
    public static func manga(globalPageIndex: Int) -> Int64 {
        clamp(Int64(globalPageIndex), offsetLimit)
    }

    public static func of(_ anchor: BookmarkAnchorPayload) -> Int64 {
        switch anchor {
        case let .novel(novelAnchor):
            novel(
                view: novelAnchor.view,
                chapterOrdinal: novelAnchor.chapterOrdinal,
                textSegmentIdentity: novelAnchor.textSegmentIdentity,
                displayedTextOffset: novelAnchor.displayedTextOffset
            )
        case let .manga(mangaAnchor):
            manga(globalPageIndex: mangaAnchor.globalPageIndex)
        }
    }

    private static func clamp(_ value: Int64, _ limit: Int64) -> Int64 {
        min(max(value, 0), limit)
    }
}
