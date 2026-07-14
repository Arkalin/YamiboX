import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

/// Covers smart-comic-mode design decision #16: the "设为漫画封面：《书名》"
/// entry (and its restore-manga-cover counterpart) must disappear entirely
/// when the tapped thread's board has Smart Comic Mode off — even when a
/// `MangaDirectory` still technically exists for that tid.
final class ImageBrowserCoverActionsTests: XCTestCase {
    func testManualCoverActionsIncludeMangaEntryWhenSmartModeEnabledAndDirectoryExists() async throws {
        let fixture = try await makeFixture(
            directories: [makeDirectory(tid: "701", cleanBookName: "测试漫画")]
        )

        let actions = await ImageBrowserThreadCoverActions.provider(
            tid: "701",
            contentCoverStore: { fixture.contentCoverStore },
            mangaDirectoryStore: { fixture.directoryStore },
            isSmartComicModeEnabled: { true }
        )()

        XCTAssertEqual(actions.map(\.id), ["cover.set.thread", "cover.set.manga"])
    }

    func testManualCoverActionsOmitMangaEntryWhenSmartModeDisabledEvenIfDirectoryExists() async throws {
        // The directory technically exists (e.g. a leftover from when the
        // board was previously on) but the board's Smart Comic Mode is
        // currently off: decision #16 says this must not surface any
        // manga-directory-aware UI at all, regardless of that leftover data.
        let fixture = try await makeFixture(
            directories: [makeDirectory(tid: "701", cleanBookName: "测试漫画")]
        )

        let actions = await ImageBrowserThreadCoverActions.provider(
            tid: "701",
            contentCoverStore: { fixture.contentCoverStore },
            mangaDirectoryStore: { fixture.directoryStore },
            isSmartComicModeEnabled: { false }
        )()

        XCTAssertEqual(actions.map(\.id), ["cover.set.thread"])
    }

    func testManualCoverActionsOmitRestoreMangaEntryWhenSmartModeDisabledEvenWithExistingManualCover() async throws {
        let fixture = try await makeFixture(
            directories: [makeDirectory(tid: "701", cleanBookName: "测试漫画")]
        )
        try await fixture.contentCoverStore.setManualCover(
            try XCTUnwrap(URL(string: "https://img.example.com/manga-cover.jpg")),
            for: .smartManga(cleanBookName: "测试漫画")
        )
        try await fixture.contentCoverStore.setManualCover(
            try XCTUnwrap(URL(string: "https://img.example.com/thread-cover.jpg")),
            for: .thread(tid: "701")
        )

        let actions = await ImageBrowserThreadCoverActions.provider(
            tid: "701",
            contentCoverStore: { fixture.contentCoverStore },
            mangaDirectoryStore: { fixture.directoryStore },
            isSmartComicModeEnabled: { false }
        )()

        XCTAssertEqual(actions.map(\.id), ["cover.set.thread", "cover.restore.thread"])
    }

}

private struct ImageBrowserCoverActionsFixture {
    let contentCoverStore: ContentCoverStore
    let directoryStore: any MangaDirectoryPersisting
}

private func makeFixture(
    directories: [MangaDirectory]
) async throws -> ImageBrowserCoverActionsFixture {
    let defaults = try YamiboTestDefaults.defaults(suiteName: YamiboTestDefaults.suiteName(prefix: "image-browser-cover-actions"))
    let contentCoverStore = ContentCoverStore(defaults: defaults, key: "content-covers")
    let directoryStore = CoverActionsTestMangaDirectoryStore(directories: directories)
    return ImageBrowserCoverActionsFixture(contentCoverStore: contentCoverStore, directoryStore: directoryStore)
}

private func makeDirectory(tid: String, cleanBookName: String) -> MangaDirectory {
    MangaDirectory(
        cleanBookName: cleanBookName,
        strategy: .links,
        sourceKey: cleanBookName,
        chapters: [
            MangaChapter(tid: tid, rawTitle: cleanBookName, chapterNumber: 1)
        ]
    )
}

private actor CoverActionsTestMangaDirectoryStore: MangaDirectoryPersisting {
    private let directories: [MangaDirectory]

    init(directories: [MangaDirectory]) {
        self.directories = directories
    }

    func directory(named name: String) async throws -> MangaDirectory? {
        directories.first { $0.cleanBookName == name }
    }

    func directory(containingTID tid: String) async throws -> MangaDirectory? {
        directories.first { directory in
            directory.chapters.contains { $0.tid == tid }
        }
    }

    func saveDirectory(_ directory: MangaDirectory) async throws {}

    func deleteDirectory(named name: String) async throws {}
}
