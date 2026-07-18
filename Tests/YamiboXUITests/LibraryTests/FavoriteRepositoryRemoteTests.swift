import Foundation
import Testing
import XCTest
@testable import YamiboXCore

// 迁移自 NovelReaderTests/ReaderCoreTests.swift(收藏域测试原先混在阅读器
// 大文件里):FavoriteRepository 的远端收藏读写(登录态识别、删除、添加与
// 收藏页解析)。StubURLProtocol 位于 NovelReaderTests/NovelReaderTestSupport.swift
// (同一测试 target,internal 可见)。

@Test func repositoryTreatsLoginFavoritesPageAsNotAuthenticated() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let repository = FavoriteRepository(
        client: YamiboClient(session: session, cookie: "sid=1; favorite-delete-success=1", userAgent: "Test-UA")
    )

    await #expect(throws: YamiboError.notAuthenticated) {
        _ = try await repository.fetchFavorites()
    }
}

final class FavoriteRepositoryDeleteTests: XCTestCase {
    func testDeletesFavoriteUsingFormhashAndFavoriteID() async throws {
        let repository = makeFavoriteRepository(cookie: "sid=1; favorite-delete-success=1")
        try await repository.deleteFavorite(remoteFavoriteID: "55")
    }

    func testThrowsWhenDeleteFormhashIsMissing() async {
        let repository = makeFavoriteRepository(cookie: "sid=1; missing-token=1")

        do {
            try await repository.deleteFavorite(remoteFavoriteID: "55")
            XCTFail("Expected missingFavoriteDeleteToken")
        } catch let error as FavoriteActionError {
            XCTAssertEqual(error, .missingFavoriteDeleteToken)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testThrowsWhenDeleteResponseIsFailure() async {
        let repository = makeFavoriteRepository(cookie: "sid=1")

        do {
            try await repository.deleteFavorite(remoteFavoriteID: "999")
            XCTFail("Expected favoriteDeleteFailed")
        } catch let error as FavoriteActionError {
            XCTAssertEqual(error, .favoriteDeleteFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeFavoriteRepository(cookie: String) -> FavoriteRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return FavoriteRepository(
            client: YamiboClient(session: session, cookie: cookie, userAgent: "Test-UA")
        )
    }
}

final class FavoriteRepositoryThreadFavoriteTests: XCTestCase {
    func testAddsThreadFavoriteAndBackfillsRemoteFavoriteID() async throws {
        let repository = makeFavoriteRepository(cookie: "sid=1; favorite-add-success=1")

        let remoteFavorite = try await repository.addThreadFavorite(threadID: "704", formHash: "abc12345")

        XCTAssertEqual(remoteFavorite?.remoteFavoriteID, "8801")
        XCTAssertEqual(remoteFavorite?.threadID, "704")
    }

    func testFindsRemoteFavoriteIDAcrossFavoritePages() async throws {
        let repository = makeFavoriteRepository(cookie: "sid=1; favorite-target-page2=1")

        let remoteFavorite = try await repository.remoteFavorite(forThreadID: "805")

        XCTAssertEqual(remoteFavorite?.remoteFavoriteID, "9902")
    }

    func testFavoritePageParserReadsPagination() {
        let html = """
        <html><body>
          <div class="findbox mt10 cl">
            <ul>
              <li class="sclist"><a href="home.php?mod=spacecp&amp;ac=favorite&amp;op=delete&amp;favid=9001" class="dialog mdel"><i class="dm-error"></i></a><a href="forum.php?mod=viewthread&amp;tid=900&amp;mobile=2">收藏</a></li>
            </ul>
          </div>
          <div class="pg"><a href="home.php?page=1">1</a><strong>2</strong><a href="home.php?page=3">3</a></div>
        </body></html>
        """

        let page = FavoriteHTMLParser.parseFavoritePage(from: html)

        XCTAssertEqual(page.currentPage, 2)
        XCTAssertEqual(page.totalPages, 3)
        XCTAssertEqual(page.favorites.count, 1)
    }

    func testFavoritePageParserDistinguishesUnparseableFromGenuinelyEmptyDocument() {
        let unparseable = FavoriteHTMLParser.parseFavoritePage(from: "")
        XCTAssertFalse(unparseable.documentParsed)
        XCTAssertTrue(unparseable.favorites.isEmpty)

        let wellFormedButEmpty = FavoriteHTMLParser.parseFavoritePage(from: "<html><body></body></html>")
        XCTAssertTrue(wellFormedButEmpty.documentParsed)
        XCTAssertTrue(wellFormedButEmpty.favorites.isEmpty)
    }

    private func makeFavoriteRepository(cookie: String) -> FavoriteRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return FavoriteRepository(
            client: YamiboClient(session: session, cookie: cookie, userAgent: "Test-UA")
        )
    }
}
