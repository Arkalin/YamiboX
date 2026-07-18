import Foundation
import Testing
@testable import YamiboXCore

@Test func favoriteLibraryWebDAVPayloadExcludesProgressAuthLogsAndCoverBytes() throws {
    let payload = FavoriteLibraryWebDAVPayload(
        updatedAt: Date(timeIntervalSince1970: 1),
        accountUID: "uid",
        library: FavoriteLibraryDocument()
    )

    let data = try JSONEncoder().encode(payload)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["library"] != nil)
    #expect(object["readingProgress"] == nil)
    #expect(object["auth"] == nil)
    #expect(object["logs"] == nil)
    #expect(object["coverBytes"] == nil)
}

@Test func favoriteLibraryWebDAVMergePreservesIndependentLocationsAndTagsWithTombstones() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "1001")
    let baseDate = Date(timeIntervalSince1970: 10)
    var localDocument = FavoriteLibraryDocument()
    let category = localDocument.createCategory(name: "分类")
    let collection = localDocument.createCollection(categoryID: category.id, name: "合集")
    let tag = localDocument.createTag(name: "标签", color: .blue)
    var localItem = try FavoriteItem(target: target, title: "主题", locations: [.category(category.id)], tagIDs: [tag.id], updatedAt: baseDate)
    localDocument.upsertItem(localItem)

    var remoteDocument = localDocument
    localItem.locations = [.collection(categoryID: category.id, collectionID: collection.id)]
    localItem.tagIDs = []
    remoteDocument.items = [localItem]

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: baseDate, library: localDocument),
        remote: FavoriteLibraryWebDAVPayload(
            updatedAt: baseDate.addingTimeInterval(1),
            library: remoteDocument,
            tombstones: FavoriteLibraryWebDAVTombstones(removedTagIDsByTargetID: [target.id: [tag.id]])
        ),
        updatedAt: baseDate.addingTimeInterval(2)
    )

    let item = try #require(merged.library.items.first)
    #expect(Set(item.locations) == [.category(category.id), .collection(categoryID: category.id, collectionID: collection.id)])
    #expect(item.tagIDs.isEmpty)
}

@Test func favoriteLibraryWebDAVMergeUsesFieldDomainClocks() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "1002")
    let localClock = Date(timeIntervalSince1970: 20)
    let remoteClock = Date(timeIntervalSince1970: 30)
    let localItem = try FavoriteItem(
        target: target,
        title: "主题",
        displayName: "本地名",
        forumID: "10",
        forumName: "本地版块",
        contentUpdatedAt: Date(timeIntervalSince1970: 100),
        remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "local"),
        locations: [.category(FavoriteCategory.defaultID)]
    )
    var remoteItem = localItem
    remoteItem.displayName = "远端名"
    remoteItem.forumID = "10"
    remoteItem.forumName = "远端版块"
    remoteItem.contentUpdatedAt = Date(timeIntervalSince1970: 200)
    remoteItem.remoteMapping = FavoriteRemoteMapping(yamiboFavoriteID: "remote")

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(
            updatedAt: localClock,
            library: FavoriteLibraryDocument(items: [localItem]),
            clocks: FavoriteLibraryWebDAVClocks(
                displayNameUpdatedAtByTargetID: [target.id: remoteClock],
                remoteMappingUpdatedAtByTargetID: [target.id: localClock]
            )
        ),
        remote: FavoriteLibraryWebDAVPayload(
            updatedAt: remoteClock,
            library: FavoriteLibraryDocument(items: [remoteItem]),
            clocks: FavoriteLibraryWebDAVClocks(
                displayNameUpdatedAtByTargetID: [target.id: localClock],
                remoteMappingUpdatedAtByTargetID: [target.id: remoteClock]
            )
        ),
        updatedAt: remoteClock.addingTimeInterval(1)
    )

    let item = try #require(merged.library.items.first)
    #expect(item.displayName == "本地名")
    #expect(item.forumID == "10")
    #expect(item.forumName == "本地版块")
    #expect(item.contentUpdatedAt == Date(timeIntervalSince1970: 200))
    #expect(item.remoteMapping?.yamiboFavoriteID == "remote")
}

@Test func readingProgressWebDAVMergeUsesStableTargetIdentityAndNewestRecord() throws {
    let target = FavoriteContentTarget(mangaCleanBookName: "清理后的书名")
    let older = ReadingProgressRecord(
        contentTarget: target,
        threadID: "1101",
        kind: .manga,
        updatedAt: Date(timeIntervalSince1970: 10),
        manga: MangaReadingProgressRecord(
            chapterThreadID: "1101",
            lastChapter: "第一话",
            mangaPageIndex: 1,
            mangaPageCount: 8
        )
    )
    var newer = older
    newer.updatedAt = Date(timeIntervalSince1970: 20)
    newer.manga = MangaReadingProgressRecord(
        chapterThreadID: "1101",
        lastChapter: "第一话",
        mangaPageIndex: 7,
        mangaPageCount: 10
    )

    let merged = ReadingProgressWebDAVMerger().merge(
        local: ReadingProgressWebDAVPayload(updatedAt: older.updatedAt, records: [older]),
        remote: ReadingProgressWebDAVPayload(updatedAt: newer.updatedAt, records: [newer]),
        updatedAt: Date(timeIntervalSince1970: 30)
    )

    let record = try #require(merged.records.first)
    #expect(record.id == target.id)
    #expect(record.manga?.mangaPageIndex == 7)
    #expect(record.manga?.mangaPageCount == 10)
}

@Test func readingProgressWebDAVPayloadWritesTidFirstSchemaWithoutURLFields() throws {
    let payload = ReadingProgressWebDAVPayload(
        updatedAt: Date(timeIntervalSince1970: 40),
        records: [
            ReadingProgressRecord(
                contentTarget: FavoriteContentTarget(kind: .novelThread, threadID: "1201"),
                threadID: "1201",
                kind: .novel,
                updatedAt: Date(timeIntervalSince1970: 41),
                novel: NovelReadingProgressRecord(lastView: 4, lastChapter: "第四章")
            ),
            ReadingProgressRecord(
                contentTarget: FavoriteContentTarget(mangaID: "manga-1", mangaCleanBookName: "漫画"),
                threadID: "1201",
                kind: .manga,
                updatedAt: Date(timeIntervalSince1970: 42),
                manga: MangaReadingProgressRecord(
                    chapterThreadID: "1202",
                    chapterView: 2,
                    lastChapter: "第二话",
                    mangaPageIndex: 3,
                    mangaPageCount: 8
                )
            ),
        ]
    )

    let data = try JSONEncoder().encode(payload)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let records = try #require(object["records"] as? [[String: Any]])
    let novelRecord = try #require(records.first { ($0["kind"] as? String) == ReadingProgressKind.novel.rawValue })
    let mangaRecord = try #require(records.first { ($0["kind"] as? String) == ReadingProgressKind.manga.rawValue })
    let novelTarget = try #require(novelRecord["contentTarget"] as? [String: Any])
    let manga = try #require(mangaRecord["manga"] as? [String: Any])

    #expect(object["version"] as? Int == ReadingProgressWebDAVPayload.currentVersion)
    #expect(novelTarget["threadID"] as? String == "1201")
    #expect(mangaRecord["threadID"] as? String == "1201")
    #expect(manga["chapterThreadID"] as? String == "1202")
    #expect(manga["chapterView"] as? Int == 2)

    let decoded = try JSONDecoder().decode(ReadingProgressWebDAVPayload.self, from: data)
    #expect(decoded.records.count == 2)
    #expect(decoded.records.first { $0.kind == .novel }?.threadID == "1201")
    #expect(decoded.records.first { $0.kind == .manga }?.manga?.chapterThreadID == "1202")
    #expect(decoded.records.first { $0.kind == .manga }?.manga?.chapterView == 2)
}

/// Payloads written before revisions existed carry no `syncRevision`; they
/// must keep decoding (revision nil), and the service-injected envelope field
/// must round-trip through each payload's decoder.
@Test func webDAVPayloadEnvelopesTolerateMissingSyncRevisionAndRoundTripInjectedOnes() throws {
    let exported = try JSONEncoder().encode(FavoriteLibraryWebDAVPayload(
        updatedAt: Date(timeIntervalSince1970: 1),
        accountUID: "uid",
        library: FavoriteLibraryDocument()
    ))
    // Participants export without a revision, so the wire format is identical
    // to what pre-revision builds wrote; decoding it must yield a nil
    // revision instead of failing.
    let exportedObject = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
    #expect(exportedObject["syncRevision"] == nil)
    let decodedLegacy = try JSONDecoder().decode(FavoriteLibraryWebDAVPayload.self, from: exported)
    #expect(decodedLegacy.syncRevision == nil)

    // The sync service stamps the revision into the exported envelope; the
    // stamped payload must decode with the revision and unchanged content.
    let stamped = WebDAVPayloadEnvelope.injectingSyncRevision(7, into: exported)
    let decodedStamped = try JSONDecoder().decode(FavoriteLibraryWebDAVPayload.self, from: stamped)
    #expect(decodedStamped.syncRevision == 7)
    #expect(decodedStamped.library == decodedLegacy.library)
    #expect(decodedStamped.updatedAt == decodedLegacy.updatedAt)
    #expect(decodedStamped.accountUID == "uid")

    let stampedProgress = WebDAVPayloadEnvelope.injectingSyncRevision(
        9,
        into: try JSONEncoder().encode(ReadingProgressWebDAVPayload(updatedAt: Date(timeIntervalSince1970: 2), records: []))
    )
    #expect(try JSONDecoder().decode(ReadingProgressWebDAVPayload.self, from: stampedProgress).syncRevision == 9)

    let stampedLikes = WebDAVPayloadEnvelope.injectingSyncRevision(
        11,
        into: try JSONEncoder().encode(LikeLibraryWebDAVPayload(updatedAt: Date(timeIntervalSince1970: 3), items: [], tombstones: [:]))
    )
    #expect(try JSONDecoder().decode(LikeLibraryWebDAVPayload.self, from: stampedLikes).syncRevision == 11)

    let stampedAppSettings = WebDAVPayloadEnvelope.injectingSyncRevision(
        13,
        into: try JSONEncoder().encode(AppSettingsWebDAVPayload(
            updatedAt: Date(timeIntervalSince1970: 4),
            appSettings: WebDAVSyncedAppSettings(homePage: .forum, webBrowser: WebBrowserSettings())
        ))
    )
    #expect(try JSONDecoder().decode(AppSettingsWebDAVPayload.self, from: stampedAppSettings).syncRevision == 13)

    // Non-JSON-object data degrades to the unstamped bytes instead of failing
    // the round.
    let notAnObject = Data("[1, 2, 3]".utf8)
    #expect(WebDAVPayloadEnvelope.injectingSyncRevision(1, into: notAnObject) == notAnObject)
}

/// A settings blob stored by a pre-revision build has no revision dictionaries
/// (and possibly none of the later bookkeeping fields at all). It must decode
/// with defaults instead of failing — a decode failure would reset the store
/// and silently drop the user's WebDAV credentials.
@Test func webDAVSyncSettingsDecodePreRevisionBlobsPreservingCredentialsAndBookkeeping() throws {
    let preRevisionBlob = Data(
        """
        {
          "baseURLString": "https://dav.example.com",
          "username": "admin",
          "password": "secret",
          "isAutoSyncEnabled": true,
          "localUpdatedAt": 1000,
          "dirtyDatasetIDs": ["favoriteLibrary"],
          "lastSyncedFingerprintByDatasetID": {"favoriteLibrary": "abc"},
          "lastAppliedRemoteUpdatedAtByDatasetID": {"favoriteLibrary": 900}
        }
        """.utf8
    )
    let decoded = try JSONDecoder().decode(WebDAVSyncSettings.self, from: preRevisionBlob)
    #expect(decoded.baseURLString == "https://dav.example.com")
    #expect(decoded.username == "admin")
    #expect(decoded.password == "secret")
    #expect(decoded.isAutoSyncEnabled)
    #expect(decoded.localUpdatedAt == Date(timeIntervalSinceReferenceDate: 1000))
    #expect(decoded.dirtyDatasetIDs == ["favoriteLibrary"])
    #expect(decoded.lastSyncedFingerprintByDatasetID == ["favoriteLibrary": "abc"])
    #expect(decoded.lastAppliedRemoteUpdatedAtByDatasetID == ["favoriteLibrary": Date(timeIntervalSinceReferenceDate: 900)])
    #expect(decoded.localRevisionByDatasetID.isEmpty)
    #expect(decoded.lastAppliedRemoteRevisionByDatasetID.isEmpty)

    // Even older shape: only the credential fields exist.
    let minimalBlob = Data(
        """
        {
          "baseURLString": "https://dav.example.com",
          "username": "admin",
          "password": "secret",
          "isAutoSyncEnabled": false
        }
        """.utf8
    )
    let minimal = try JSONDecoder().decode(WebDAVSyncSettings.self, from: minimalBlob)
    #expect(minimal.username == "admin")
    #expect(minimal.dirtyDatasetIDs.isEmpty)
    #expect(minimal.localRevisionByDatasetID.isEmpty)
    #expect(minimal.lastAppliedRemoteRevisionByDatasetID.isEmpty)

    // Round-trip: the revision dictionaries survive encode/decode.
    var withRevisions = decoded
    withRevisions.localRevisionByDatasetID = ["favoriteLibrary": 3]
    withRevisions.lastAppliedRemoteRevisionByDatasetID = ["favoriteLibrary": 5]
    let roundTripped = try JSONDecoder().decode(
        WebDAVSyncSettings.self,
        from: try JSONEncoder().encode(withRevisions)
    )
    #expect(roundTripped == withRevisions)
}

@Test func localFirstWebDAVPayloadsRejectLegacyOrMissingVersions() throws {
    let legacyProgress = Data(
        """
        {
          "version": 1,
          "updatedAt": 0,
          "records": [
            {
              "threadID": "1301",
              "kind": "novel",
              "updatedAt": 0
            }
          ]
        }
        """.utf8
    )
    let missingVersionLibrary = Data(
        """
        {
          "updatedAt": 0,
          "library": {}
        }
        """.utf8
    )

    #expect(throws: WebDAVSyncError.unsupportedPayloadVersion(1)) {
        _ = try JSONDecoder().decode(ReadingProgressWebDAVPayload.self, from: legacyProgress)
    }
    #expect(throws: WebDAVSyncError.unsupportedPayloadVersion(0)) {
        _ = try JSONDecoder().decode(FavoriteLibraryWebDAVPayload.self, from: missingVersionLibrary)
    }
}
