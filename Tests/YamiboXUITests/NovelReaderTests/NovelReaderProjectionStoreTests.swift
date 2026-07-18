import Foundation
@preconcurrency import GRDB
import Testing
@testable import YamiboXCore

// 拆分自 ReaderCoreTests.swift:NovelReaderProjectionStore 投影缓存
// (持久化/删除、tid-first 索引、遗留索引兼容、schema 版本与语义完整性校验、
// 按 authorID 分变体),以及 NovelReaderProjection 的 schema 解码拒绝。
// novelReaderProjectionCacheFiles(全目录枚举)位于 NovelReaderTestSupport.swift。

@Test func novelReaderCacheStorePersistsAndDeletesPages() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = NovelReaderProjectionStore(baseDirectory: directory)
    let document = NovelReaderProjection(
        threadID: "10",
        view: 3,
        maxView: 5,
        resolvedAuthorID: "12",
        segments: [.text("正文", chapterTitle: "测试章")],
        fetchedAt: Date(timeIntervalSince1970: 100)
    )

    try await store.save(document)
    let loaded = await store.loadProjection(for: NovelPageRequest(threadID: "10", view: 3, authorID: "12"))
    #expect(loaded == document)
    #expect(await store.cachedViews(for: "10", authorID: "12") == [3])

    try await store.deleteViews([3], for: "10", authorID: "12")
    let deleted = await store.loadProjection(for: NovelPageRequest(threadID: "10", view: 3, authorID: "12"))
    #expect(deleted == nil)
}

@Test func novelReaderCacheStoreIndexUsesTidFirstIdentityWithoutThreadURL() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let database = try YamiboDatabase.openPool(rootDirectory: directory.appendingPathComponent("grdb", isDirectory: true))
    let store = NovelReaderProjectionStore(databasePool: database, baseDirectory: directory)
    let document = NovelReaderProjection(
        threadID: "18610",
        view: 4,
        maxView: 5,
        resolvedAuthorID: "12",
        segments: [.text("正文", chapterTitle: "测试章")]
    )

    try await store.save(document)

    let rows = try await novelReaderProjectionCacheRows(in: database)
    let metadata = try #require(rows.first)

    #expect(rows.count == 1)
    #expect(metadata.namespace == "novel-reader-projections")
    #expect(metadata.key == "tid_18610_author_12_view_4")
    #expect(!metadata.key.contains("https://"))
    #expect(FileManager.default.fileExists(
        atPath: novelReaderProjectionCacheFile(rootDirectory: directory, key: metadata.key).path
    ))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json", isDirectory: false).path))
}

@Test func novelReaderCacheStoreLegacyIndexAndFilesAreIgnoredAndPreserved() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try YamiboDatabase.openPool(rootDirectory: directory.appendingPathComponent("grdb", isDirectory: true))
    let legacyIndexURL = directory.appendingPathComponent("index.json", isDirectory: false)
    let legacyFileURL = directory.appendingPathComponent("legacy-reader-document.json", isDirectory: false)
    let legacyIndexData = Data(#"{"version":3,"threads":{"tid:18611":{"threadID":"18611","variants":{"source:fallbackUnfilteredPage":{"pages":{"1":{"fileName":"legacy-reader-document.json","fetchedAt":"2026-01-01T00:00:00Z"}}}}}}}"#.utf8)
    try legacyIndexData.write(to: legacyIndexURL, options: [.atomic])
    try Data(#"{"legacy":true}"#.utf8).write(to: legacyFileURL, options: [.atomic])

    let store = NovelReaderProjectionStore(databasePool: database, baseDirectory: directory)
    let legacyLoaded = await store.loadProjection(
        for: NovelPageRequest(threadID: "18611", view: 1)
    )
    try await store.save(
        NovelReaderProjection(
            threadID: "18612",
            view: 1,
            maxView: 1,
            segments: [.text("新缓存正文", chapterTitle: "新章")]
        )
    )

    #expect(legacyLoaded == nil)
    #expect(try Data(contentsOf: legacyIndexURL) == legacyIndexData)
    #expect(FileManager.default.fileExists(atPath: legacyFileURL.path))
}

@Test func novelReaderCacheStoreWritesDocumentSchemaVersionAndSemanticIdentities() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = NovelReaderProjectionStore(baseDirectory: directory)
    let document = NovelReaderProjection(
        threadID: "18601",
        view: 1,
        maxView: 1,
        segments: [.text("第一章\n正文", chapterTitle: "第一章")],
        segmentSemantics: [
            NovelReaderSegmentSemantics(
                chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-1"),
                chapterTitleRange: NovelCharacterRange(location: 0, length: "第一章".count),
                inlineTextStyles: [
                    NovelInlineTextStyleRange(style: .bold, range: NovelCharacterRange(location: 4, length: 2))
                ],
                blockTextStyles: [
                    NovelBlockTextStyleRange(style: .quote, range: NovelCharacterRange(location: 4, length: 2))
                ]
            )
        ]
    )

    try await store.save(document)

    let cacheFile = try #require(novelReaderProjectionCacheFiles(rootDirectory: directory).first)
    let object = try #require(
        JSONSerialization.jsonObject(with: try Data(contentsOf: cacheFile)) as? [String: Any]
    )
    let semantics = try #require(object["segmentSemantics"] as? [[String: Any]])
    let firstSemantics = try #require(semantics.first)
    let chapterIdentity = try #require(firstSemantics["chapterIdentity"] as? [String: Any])
    let textSegmentIdentity = try #require(firstSemantics["textSegmentIdentity"] as? [String: Any])
    let titleRange = try #require(firstSemantics["chapterTitleRange"] as? [String: Any])
    let inlineTextStyles = try #require(firstSemantics["inlineTextStyles"] as? [[String: Any]])
    let firstInlineStyle = try #require(inlineTextStyles.first)
    let firstInlineRange = try #require(firstInlineStyle["range"] as? [String: Any])
    let blockTextStyles = try #require(firstSemantics["blockTextStyles"] as? [[String: Any]])
    let firstBlockStyle = try #require(blockTextStyles.first)
    let firstBlockRange = try #require(firstBlockStyle["range"] as? [String: Any])

    #expect(object["schemaVersion"] as? Int == NovelReaderProjection.schemaVersion)
    #expect(object["threadID"] as? String == "18601")
    #expect(chapterIdentity["rawValue"] as? String != nil)
    #expect(textSegmentIdentity["rawValue"] as? String != nil)
    #expect(titleRange["location"] as? Int == 0)
    #expect(titleRange["length"] as? Int == "第一章".count)
    #expect(firstInlineStyle["style"] as? String == NovelInlineTextStyle.bold.rawValue)
    #expect(firstInlineRange["location"] as? Int == 4)
    #expect(firstInlineRange["length"] as? Int == 2)
    #expect(firstBlockStyle["style"] as? String == NovelBlockTextStyle.quote.rawValue)
    #expect(firstBlockRange["location"] as? Int == 4)
    #expect(firstBlockRange["length"] as? Int == 2)
}

@Test func readerPageDocumentRejectsOutdatedSchemaVersionOnDecode() async throws {
    let json = #"""
    {
      "schemaVersion": 3,
      "threadID": "18605",
      "view": 1,
      "maxView": 1,
      "contentSource": "fallbackUnfilteredPage",
      "retainedChapterCount": 1,
      "filteredChapterCandidateCount": 0,
      "segments": [
        {"kind": "text", "text": "第一章\n正文", "chapterTitle": "第一章"}
      ],
      "segmentSources": [null],
      "segmentSemantics": [
        {
          "chapterIdentity": {"rawValue": "post:1#chapter:0"},
          "textSegmentIdentity": {"rawValue": "post:1#chapter:0#text:0"},
          "chapterTitleRange": {"location": 0, "length": 3},
          "inlineTextStyles": [],
          "blockTextStyles": []
        }
      ],
      "fetchedAt": "2026-06-05T00:00:00Z"
    }
    """#.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    #expect(throws: (any Error).self) {
        _ = try decoder.decode(NovelReaderProjection.self, from: json)
    }
}

@Test func novelReaderCacheStoreInvalidatesDocumentWithCorruptExplicitTitleRange() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let database = try YamiboDatabase.openPool(rootDirectory: directory.appendingPathComponent("grdb", isDirectory: true))
    let store = NovelReaderProjectionStore(databasePool: database, baseDirectory: directory)
    let document = #"""
    {
      "schemaVersion": 6,
      "threadID": "18604",
      "view": 1,
      "maxView": 1,
      "contentSource": "fallbackUnfilteredPage",
      "retainedChapterCount": 1,
      "filteredChapterCandidateCount": 0,
      "segments": [
        {"kind": "text", "text": "短文", "chapterTitle": "短文"}
      ],
      "segmentSources": [null],
      "segmentSemantics": [
        {
          "chapterIdentity": {"rawValue": "post:1#chapter:0"},
          "textSegmentIdentity": {"rawValue": "post:1#chapter:0#text:0"},
          "chapterTitleRange": {"location": 0, "length": 20},
          "inlineTextStyles": [],
          "blockTextStyles": []
        }
      ],
      "fetchedAt": "2026-06-05T00:00:00Z"
    }
    """#
    try await store.save(
        NovelReaderProjection(
            threadID: "18604",
            view: 1,
            maxView: 1,
            segments: [.text("短文", chapterTitle: "短文")]
        )
    )
    let metadata = try #require(try await novelReaderProjectionCacheRows(in: database).first)
    let fileURL = novelReaderProjectionCacheFile(rootDirectory: directory, key: metadata.key)
    try Data(document.utf8).write(to: fileURL, options: [.atomic])

    let verifyingStore = NovelReaderProjectionStore(databasePool: database, baseDirectory: directory)
    let loaded = await verifyingStore.loadProjection(
        for: NovelPageRequest(threadID: "18604", view: 1)
    )

    #expect(loaded == nil)
    #expect(try await novelReaderProjectionCacheRows(in: database).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func novelReaderCacheStoreInvalidatesDocumentWithCorruptInlineTextStyleRange() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let database = try YamiboDatabase.openPool(rootDirectory: directory.appendingPathComponent("grdb", isDirectory: true))
    let store = NovelReaderProjectionStore(databasePool: database, baseDirectory: directory)
    let document = #"""
    {
      "schemaVersion": 6,
      "threadID": "18606",
      "view": 1,
      "maxView": 1,
      "contentSource": "fallbackUnfilteredPage",
      "retainedChapterCount": 1,
      "filteredChapterCandidateCount": 0,
      "segments": [
        {"kind": "text", "text": "短文", "chapterTitle": "短文"}
      ],
      "segmentSources": [null],
      "segmentSemantics": [
        {
          "chapterIdentity": {"rawValue": "post:1#chapter:0"},
          "textSegmentIdentity": {"rawValue": "post:1#chapter:0#text:0"},
          "chapterTitleRange": {"location": 0, "length": 2},
          "inlineTextStyles": [
            {"style": "bold", "range": {"location": 1, "length": 20}}
          ],
          "blockTextStyles": []
        }
      ],
      "fetchedAt": "2026-06-05T00:00:00Z"
    }
    """#
    try await store.save(
        NovelReaderProjection(
            threadID: "18606",
            view: 1,
            maxView: 1,
            segments: [.text("短文", chapterTitle: "短文")]
        )
    )
    let metadata = try #require(try await novelReaderProjectionCacheRows(in: database).first)
    let fileURL = novelReaderProjectionCacheFile(rootDirectory: directory, key: metadata.key)
    try Data(document.utf8).write(to: fileURL, options: [.atomic])

    let verifyingStore = NovelReaderProjectionStore(databasePool: database, baseDirectory: directory)
    let loaded = await verifyingStore.loadProjection(
        for: NovelPageRequest(threadID: "18606", view: 1)
    )

    #expect(loaded == nil)
    #expect(try await novelReaderProjectionCacheRows(in: database).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func novelReaderCacheStoreSeparatesVariantsByAuthorID() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = NovelReaderProjectionStore(baseDirectory: directory)
    let unfiltered = NovelReaderProjection(
        threadID: "21",
        view: 1,
        maxView: 3,
        segments: [.text("全部回复正文", chapterTitle: "第一章")]
    )
    let authorFiltered = NovelReaderProjection(
        threadID: "21",
        view: 1,
        maxView: 3,
        resolvedAuthorID: "42",
        segments: [.text("只看楼主正文", chapterTitle: "第一章")]
    )

    try await store.save(unfiltered)
    try await store.save(authorFiltered)

    let loadedUnfiltered = await store.loadProjection(
        for: NovelPageRequest(threadID: "21", view: 1)
    )
    let loadedAuthorFiltered = await store.loadProjection(
        for: NovelPageRequest(threadID: "21", view: 1, authorID: "42")
    )

    #expect(loadedUnfiltered?.segments == unfiltered.segments)
    #expect(loadedAuthorFiltered?.segments == authorFiltered.segments)
    #expect(await store.cachedViews(for: "21", authorID: nil) == [1])
    #expect(await store.cachedViews(for: "21", authorID: "42") == [1])

    try await store.deleteViews([1], for: "21", authorID: "42")

    let deletedAuthorFiltered = await store.loadProjection(
        for: NovelPageRequest(threadID: "21", view: 1, authorID: "42")
    )
    let preservedUnfiltered = await store.loadProjection(
        for: NovelPageRequest(threadID: "21", view: 1)
    )

    #expect(deletedAuthorFiltered == nil)
    #expect(preservedUnfiltered?.segments == unfiltered.segments)
}

private struct NovelReaderProjectionCacheRow: Sendable, Equatable {
    var namespace: String
    var key: String
}

private func novelReaderProjectionCacheRows(in database: DatabasePool) async throws -> [NovelReaderProjectionCacheRow] {
    try await database.read { db in
        try Row.fetchAll(
            db,
            sql: """
            SELECT namespace, cache_key
            FROM cache_entries
            WHERE namespace = ?
            ORDER BY cache_key
            """,
            arguments: [NovelReaderProjectionStore.projectionNamespace]
        ).map { row in
            NovelReaderProjectionCacheRow(
                namespace: row["namespace"],
                key: row["cache_key"]
            )
        }
    }
}

private func novelReaderProjectionCacheFile(rootDirectory: URL, key: String) -> URL {
    YamiboDatabase.cacheDirectoryURL(rootDirectory: rootDirectory)
        .appendingPathComponent(NovelReaderProjectionStore.projectionNamespace, isDirectory: true)
        .appendingPathComponent("\(key).json", isDirectory: false)
}
