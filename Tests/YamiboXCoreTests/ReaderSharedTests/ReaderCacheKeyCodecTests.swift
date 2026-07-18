import Foundation
import Testing
@testable import YamiboXCore

@Test func readerCacheKeyCodecKeepsHealthyNumericIDsVerbatim() {
    #expect(
        ReaderCacheKeyCodec.entryKey(threadID: "940", view: 3, authorID: nil)
            == "tid_940_author_all_view_3"
    )
    #expect(
        ReaderCacheKeyCodec.entryKey(threadID: "940", view: 2, authorID: "123")
            == "tid_940_author_123_view_2"
    )
    #expect(
        ReaderCacheKeyCodec.groupKey(threadID: "940", authorID: "123")
            == "tid_940_author_123"
    )
}

@Test func readerCacheKeyCodecRoundTripsForNumericIDs() {
    let key = ReaderCacheKeyCodec.entryKey(threadID: "940", view: 7, authorID: "55")
    let components = ReaderCacheKeyCodec.components(from: key)
    #expect(components == ReaderCacheKeyCodec.Components(threadID: "940", authorID: "55", view: 7))
}

/// Regression: an authorID containing the `_` separator used to produce a key
/// the novel-side parser rejected (component count != 6), so cachedViews
/// silently under-reported. Sanitizing keeps the key parseable and the
/// encode/decode pair consistent.
@Test func readerCacheKeyCodecSanitizesSeparatorCharactersIntoParseableKeys() throws {
    let key = ReaderCacheKeyCodec.entryKey(threadID: "940", view: 2, authorID: "a_b")
    let components = try #require(ReaderCacheKeyCodec.components(from: key))
    #expect(components.view == 2)
    #expect(components.threadID == "940")
    // The sanitized author component still matches its re-encoded form.
    #expect(key.hasPrefix(ReaderCacheKeyCodec.groupKey(threadID: "940", authorID: "a_b") + "_view_"))
    // Distinct raw ids stay distinct after sanitizing.
    #expect(
        ReaderCacheKeyCodec.entryKey(threadID: "940", view: 2, authorID: "a_b")
            != ReaderCacheKeyCodec.entryKey(threadID: "940", view: 2, authorID: "a_c")
    )
}

@Test func readerCacheKeyCodecNormalizesBlankAndFloorValues() {
    #expect(
        ReaderCacheKeyCodec.entryKey(threadID: "940", view: 0, authorID: "  ")
            == "tid_940_author_all_view_1"
    )
    #expect(ReaderCacheKeyCodec.components(from: "not_a_cache_key") == nil)
    #expect(ReaderCacheKeyCodec.components(from: "tid_940_author_all_view_x") == nil)
}
