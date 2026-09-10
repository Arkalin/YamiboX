import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ForumEmoticonCatalogTests {
    @Test func bundledCatalogHasEveryVerifiedCategoryAndUniqueForumCodes() throws {
        let groups = ForumEmoticonCatalog.categories
        #expect(groups.map(\.id) == ["coolmonkey", "default", "gexing", "gexing2", "azukisan", "bugcat"])
        #expect(groups.map { $0.items.count } == [51, 137, 63, 29, 30, 30])
        let items = groups.flatMap(\.items)
        #expect(Set(items.map(\.code)).count == 340)
        #expect(items.allSatisfy { $0.code.hasPrefix("{:") && $0.code.hasSuffix(":}") })
        #expect(items.allSatisfy { $0.imageURL.scheme == "https" && $0.imageURL.host == YamiboDomain.forumHost && $0.imageURL.path.hasPrefix("/static/image/smiley/") })
        let first = try #require(items.first { $0.code == "{:1_910:}" })
        #expect(first.imageURL.path == "/static/image/smiley/default/89.png")
        // IDs and image numbers are not interchangeable or always contiguous.
        #expect(!items.contains { $0.code == "{:1_1038:}" })
        #expect(items.first { $0.code == "{:4_mao:}" }?.imageURL.lastPathComponent == "mao.jpg")
        #expect(items.first { $0.code == "{:9_633:}" }?.imageURL.lastPathComponent == "Capoo9.gif")
    }
}
