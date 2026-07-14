import Foundation
import Testing
@testable import YamiboXCore

@Test func threadFavoriteImportProbesBeforeCreatingNormalThreadItem() async throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "420")
    var document = FavoriteLibraryDocument()
    var probedThreadID: String?

    let item = try await document.importThreadFavorite(threadID: "420") { threadID in
        probedThreadID = threadID
        return FavoriteThreadProbeResult(
            target: target,
            title: "普通主题",
            sourceGroup: .forumBoard(id: "fid-regular", label: "综合讨论")
        )
    }

    #expect(probedThreadID == "420")
    #expect(item.target == target)
    #expect(item.locations == [.category(FavoriteCategory.defaultID)])
    #expect(item.sourceGroup == .forumBoard(id: "fid-regular", label: "综合讨论"))
    #expect(item.forumID == "fid-regular")
    #expect(item.forumName == "综合讨论")
}

@Test func threadFavoriteNormalizesExplicitForumMetadataIntoSourceGroup() throws {
    var document = FavoriteLibraryDocument()

    let item = try document.importThreadFavorite(
        probeResult: FavoriteThreadProbeResult(
            target: FavoriteItemTarget(kind: .normalThread, threadID: "426"),
            title: "普通主题"
        ),
        displayName: nil
    )
    var stored = item
    stored.forumID = "  fid-explicit  "
    stored.forumName = "  版块显式名  "
    document.upsertItem(stored)

    let normalized = try #require(document.items.first)
    #expect(normalized.forumID == "fid-explicit")
    #expect(normalized.forumName == "版块显式名")
    #expect(normalized.sourceGroup == .forumBoard(id: "fid-explicit", label: "版块显式名"))
}

@Test func threadFavoriteProbeResultCarriesExplicitForumMetadata() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "428")
    let probe = FavoriteThreadProbeResult(
        target: target,
        title: "普通主题",
        forumID: " fid-probe ",
        forumName: " 探测版块 "
    )

    #expect(probe.forumID == "fid-probe")
    #expect(probe.forumName == "探测版块")
    #expect(probe.sourceGroup == .forumBoard(id: "fid-probe", label: "探测版块"))
}

@Test func favoriteContentUpdateDateResolverParsesEditedAndPostedTimes() throws {
    let edited = try #require(FavoriteContentUpdateDateResolver.date(
        lastEditedText: "本帖最后由 楼主 于 2026-6-2 12:00 编辑",
        postedAtText: "2026-6-1 10:00"
    ))
    let posted = try #require(FavoriteContentUpdateDateResolver.date(
        lastEditedText: nil,
        postedAtText: "2026-06-01 10:00"
    ))
    // The resolver always parses forum text as Asia/Shanghai (bbs.yamibo.com
    // posts Beijing time regardless of reader location), so components must
    // be read back in that same zone rather than the host's local zone.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))

    #expect(calendar.component(.year, from: edited) == 2026)
    #expect(calendar.component(.month, from: edited) == 6)
    #expect(calendar.component(.day, from: edited) == 2)
    #expect(calendar.component(.hour, from: edited) == 12)
    #expect(calendar.component(.day, from: posted) == 1)
}

@Test func threadFavoriteImportDoesNotEraseExistingForumMetadataWhenProbeSourceIsUnknown() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "427")
    var document = FavoriteLibraryDocument()
    let existing = try FavoriteItem(
        target: target,
        title: "旧标题",
        sourceGroup: .forumBoard(id: "fid-old", label: "旧版块"),
        locations: [.category(document.defaultCategory.id)]
    )
    document.upsertItem(existing)

    let imported = try document.importThreadFavorite(
        probeResult: FavoriteThreadProbeResult(
            target: target,
            title: "新标题",
            contentUpdatedAt: Date(timeIntervalSince1970: 200)
        )
    )

    #expect(imported.title == "新标题")
    #expect(imported.sourceGroup == .forumBoard(id: "fid-old", label: "旧版块"))
    #expect(imported.forumID == "fid-old")
    #expect(imported.forumName == "旧版块")
    #expect(imported.contentUpdatedAt == Date(timeIntervalSince1970: 200))
}

@Test func threadFavoriteImportFailureSkipsPlaceholderCreation() async throws {
    var document = FavoriteLibraryDocument()

    await #expect(throws: FavoriteThreadImportFailure.self) {
        _ = try await document.importThreadFavorite(threadID: "421") { _ in
            throw FavoriteThreadImportFailure.probeFailed("missing thread")
        }
    }

    #expect(document.items.isEmpty)
}

@Test func threadFavoriteImportRetargetsExistingItemWhenThreadKindChanges() async throws {
    let normalTarget = FavoriteItemTarget(kind: .normalThread, threadID: "422")
    let novelTarget = FavoriteItemTarget(kind: .novelThread, threadID: "422")
    var document = FavoriteLibraryDocument()
    let tag = document.createTag(name: "保留标签", color: .purple)
    let existing = try FavoriteItem(
        target: normalTarget,
        title: "旧普通主题",
        displayName: "本地标题",
        locations: [.category(document.defaultCategory.id)],
        tagIDs: [tag.id]
    )
    document.upsertItem(existing)

    let imported = try await document.importThreadFavorite(threadID: "422") { _ in
        FavoriteThreadProbeResult(target: novelTarget, title: "轻小说主题")
    }

    #expect(imported.target == novelTarget)
    #expect(document.items.count == 1)
    let stored = try #require(document.items.first)
    #expect(stored.id == novelTarget.id)
    #expect(stored.displayName == "本地标题")
    #expect(stored.tagIDs == [tag.id])
}

@Test func threadFavoriteDisplayNameStaysLocalMetadata() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "423")
    var document = FavoriteLibraryDocument()

    let item = try document.importThreadFavorite(
        probeResult: FavoriteThreadProbeResult(target: target, title: "远端标题"),
        displayName: " 本地展示名 ",
        remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "remote-423")
    )

    #expect(item.title == "远端标题")
    #expect(item.displayName == "本地展示名")
    #expect(item.remoteMapping?.yamiboFavoriteID == "remote-423")
}

@Test func threadFavoriteOpenRoutesUseNormalAndNovelNativeTargets() throws {
    var document = FavoriteLibraryDocument()
    let normal = try document.importThreadFavorite(
        probeResult: FavoriteThreadProbeResult(
            target: FavoriteItemTarget(kind: .normalThread, threadID: "424"),
            title: "普通主题"
        )
    )
    let novel = try document.importThreadFavorite(
        probeResult: FavoriteThreadProbeResult(
            target: FavoriteItemTarget(kind: .novelThread, threadID: "425"),
            title: "小说主题"
        )
    )

    #expect(document.openRoute(for: normal) == .nativeThread(threadID: "424"))
    #expect(document.openRoute(for: novel) == .novelDetail(threadID: "425"))
}
