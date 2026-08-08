import Foundation
@preconcurrency import GRDB

extension OfflineCacheStore {
    func offlineCachedWorks() async -> [OfflineCachedWork] {
        await ensureQueueRecoveredBestEffort()
        do {
            return try await database.read { db in
                let activeEntryIDs = Set(try Self.allRawWorks(in: db).map { work in
                    OfflineCacheEntryID(
                        readerKind: work.readerKind,
                        ownerKey: work.ownerKey,
                        entryKey: work.entryKey
                    )
                })

                let mangaMemberships = try Self.allMangaMemberships(
                    fileManager: fileManager,
                    mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                    sourcePageCache: sourcePageCache,
                    in: db
                ).filter { membership in
                    !activeEntryIDs.contains(
                        OfflineCacheEntryID(
                            readerKind: .manga,
                            ownerKey: membership.ownerName,
                            entryKey: membership.tid
                        )
                    )
                }
                let novelEntries = try Self.allNovelEntries(in: db).filter { entry in
                    !activeEntryIDs.contains(entry.id)
                }

                return Self.cachedWorks(
                    mangaMemberships: mangaMemberships,
                    novelEntries: novelEntries
                )
            }
        } catch {
            YamiboLog.offlineCache.error("Failed to build cached work projection: \(error)")
            return []
        }
    }

    private static func cachedWorks(
        mangaMemberships: [MangaOfflineCacheMembership],
        novelEntries: [NovelOfflineCacheEntry]
    ) -> [OfflineCachedWork] {
        var works: [OfflineCachedWork] = []

        for entries in Dictionary(grouping: novelEntries, by: \.id.groupID).values {
            guard let representative = entries.max(by: { $0.updatedAt < $1.updatedAt }) else { continue }
            works.append(
                OfflineCachedWork(
                    id: representative.id.groupID,
                    title: representative.ownerTitle,
                    cachedEntryCount: entries.count,
                    updatedAt: representative.updatedAt,
                    launchTarget: .novel(
                        threadID: representative.document.threadID,
                        authorID: representative.document.resolvedAuthorID,
                        cachedView: representative.document.view
                    )
                )
            )
        }

        for entries in Dictionary(grouping: mangaMemberships, by: { membership in
            OfflineCacheGroupID(readerKind: .manga, ownerKey: membership.ownerName)
        }).values {
            guard let representative = entries.max(by: { $0.createdAt < $1.createdAt }) else { continue }
            works.append(
                OfflineCachedWork(
                    id: OfflineCacheGroupID(readerKind: .manga, ownerKey: representative.ownerName),
                    title: representative.ownerName,
                    cachedEntryCount: entries.count,
                    updatedAt: representative.createdAt,
                    launchTarget: .manga(
                        threadID: representative.tid,
                        chapterTitle: representative.chapterTitle,
                        chapterView: representative.sourcePage.pageNavigation?.currentPage ?? 1,
                        forumID: representative.sourcePage.forumID
                    )
                )
            )
        }

        return works.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}
