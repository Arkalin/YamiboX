import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

@Suite("Storage Usage")
struct StorageUsageTests {
    @Test func progressCountsAllPayloadFieldsButNotSyncMarkers() async throws {
        let fixture = try StorageUsageFixture()
        defer { fixture.cleanUp() }
        let store = ReadingProgressStore(databasePool: fixture.database)
        #expect(try await store.estimatedDataUsageBytes() == 0)
        try await fixture.database.write { db in
            try db.execute(sql: """
                INSERT INTO reading_progress (id, target_kind, kind, updated_at)
                VALUES ('p', 'novelThread', 'novel', 1)
                """)
        }
        var expected = "pnovelThreadnovel".utf8.count + 8
        #expect(try await store.estimatedDataUsageBytes() == expected)
        let textColumns = [
            "thread_id", "manga_id", "clean_book_name", "novel_last_chapter", "novel_author_id",
            "novel_resume_point_json", "manga_chapter_thread_id", "manga_last_chapter", "thread_anchor_post_id"
        ]
        for column in textColumns {
            try await fixture.database.write { db in
                try db.execute(sql: "UPDATE reading_progress SET \(column) = ?", arguments: ["章节"])
            }
            expected += "章节".utf8.count
            #expect(try await store.estimatedDataUsageBytes() == expected)
        }
        let numberColumns = [
            "last_read_at", "novel_last_view", "novel_max_view", "novel_document_surface_progress_percent",
            "manga_chapter_view", "manga_page_index", "manga_page_count", "thread_last_page", "thread_page_count"
        ]
        for column in numberColumns {
            try await fixture.database.write { db in
                try db.execute(sql: "UPDATE reading_progress SET \(column) = 1")
            }
            expected += 8
            #expect(try await store.estimatedDataUsageBytes() == expected)
        }

        try await store.clearAllForSync()
        #expect(try await store.estimatedDataUsageBytes() == 0)
        let markerCount = try await fixture.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reading_progress_sync_state") ?? 0
        }
        #expect(markerCount > 0)
    }

    @Test func historyCountsUTF8AndNullableFieldsIndependentlyOfProgress() async throws {
        let fixture = try StorageUsageFixture()
        defer { fixture.cleanUp() }
        let store = BrowsingHistoryStore(databasePool: fixture.database)
        #expect(try await store.estimatedDataUsageBytes() == 0)
        try await fixture.database.write { db in
            try db.execute(sql: """
                INSERT INTO browsing_history (id, target_kind, category, title, last_visit_time)
                VALUES ('h', 'normalThread', 'forum', '标题', 1)
                """)
        }
        var expected = "hnormalThreadforum标题".utf8.count + 8
        #expect(try await store.estimatedDataUsageBytes() == expected)
        let textColumns = [
            "thread_id", "manga_id", "clean_book_name", "forum_id", "author_id",
            "chapter_title", "chapter_thread_id", "last_visited_thread_id", "last_visited_thread_title"
        ]
        for column in textColumns {
            try await fixture.database.write { db in
                try db.execute(sql: "UPDATE browsing_history SET \(column) = ?", arguments: ["章节"])
            }
            expected += "章节".utf8.count
            #expect(try await store.estimatedDataUsageBytes() == expected)
        }
        try await fixture.database.write { db in
            try db.execute(sql: "UPDATE browsing_history SET page_index = 1, page_count = 2")
        }
        #expect(try await store.estimatedDataUsageBytes() == expected + 16)

        let progress = ReadingProgressStore(databasePool: fixture.database)
        try await progress.saveNormalThread(threadID: "1", page: 1)
        #expect(try await store.estimatedDataUsageBytes() == expected + 16)
        try await store.clearAll()
        #expect(try await store.estimatedDataUsageBytes() == 0)
        #expect(try await progress.estimatedDataUsageBytes() > 0)
    }

    @Test func favoriteUpdatesCountEveryClearedTable() async throws {
        let fixture = try StorageUsageFixture()
        defer { fixture.cleanUp() }
        let store = FavoriteUpdateStore(databasePool: fixture.database)
        #expect(try await store.estimatedDataUsageBytes() == 0)
        let json = "{\"title\":\"标题\"}"
        let inserts: [(String, Int)] = [
            ("INSERT INTO favorite_update_tracked_targets (target_id, target_json) VALUES ('t', ?)", 1),
            ("INSERT INTO favorite_update_events (id, target_id, detected_at, event_json) VALUES ('e', 't', 1, ?)", 10),
            ("INSERT INTO favorite_update_runs (run_id, updated_at, run_json) VALUES ('r', 1, ?)", 9),
            ("INSERT INTO favorite_update_fid_filters (fid, manual_order, filter_json) VALUES ('f', 0, ?)", 9),
            ("INSERT INTO favorite_update_category_filters (category_id, manual_order, filter_json) VALUES ('c', 0, ?)", 9)
        ]
        var expected = 0
        for (sql, overhead) in inserts {
            try await fixture.database.write { db in
                try db.execute(sql: sql, arguments: [json])
            }
            expected += json.utf8.count + overhead
            #expect(try await store.estimatedDataUsageBytes() == expected)
        }
        try await fixture.database.write { db in
            try db.execute(sql: "UPDATE favorite_update_events SET dismissed_at = 2")
        }
        #expect(try await store.estimatedDataUsageBytes() == expected + 8)
        try await store.clearAll()
        #expect(try await store.estimatedDataUsageBytes() == 0)
    }

    @Test func checkInCountsOnlyItsOwnPrefixedKeys() async throws {
        let suiteName = "storage-usage-check-in-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = YamiboCheckInStore(defaults: defaults, keyPrefix: "check-in")
        #expect(await store.estimatedDataUsageBytes() == 0)
        defaults.set("2026-09-08", forKey: "check-in.account")
        defaults.set("2026-09-07", forKey: "check-in.账号")
        defaults.set("unrelated", forKey: "check-in-other.account")
        let expected = "check-in.account2026-09-08check-in.账号2026-09-07".utf8.count
        #expect(await store.estimatedDataUsageBytes() == expected)
        await store.clearAll()
        #expect(await store.estimatedDataUsageBytes() == 0)
        #expect(defaults.string(forKey: "check-in-other.account") == "unrelated")
    }
}

private struct StorageUsageFixture {
    let root: URL
    let database: DatabasePool

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-usage-\(UUID().uuidString)")
        database = try YamiboDatabase.openPool(rootDirectory: root)
    }

    func cleanUp() {
        try? database.close()
        try? FileManager.default.removeItem(at: root)
    }
}
