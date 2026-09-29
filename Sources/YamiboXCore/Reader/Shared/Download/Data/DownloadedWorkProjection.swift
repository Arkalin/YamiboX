import Foundation
@preconcurrency import GRDB

extension DownloadStore {
    func downloadedWorks() async -> [DownloadedWork] {
        await ensureQueueRecoveredBestEffort()
        do {
            return try await database.read { db in
                let activeEntryIDs = Set(try Self.allRawWorks(in: db).map { work in
                    DownloadEntryID(
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
                        DownloadEntryID(
                            readerKind: .manga,
                            ownerKey: membership.ownerName,
                            entryKey: membership.tid
                        )
                    )
                }
                let novelEntries = try Self.allNovelEntries(in: db).filter { entry in
                    !activeEntryIDs.contains(entry.id)
                }

                let ownerNames = try Dictionary(uniqueKeysWithValues: Set(mangaMemberships.map(\.ownerName)).map {
                    ($0, try Self.mangaOwnerTitle($0, in: db))
                })
                return Self.downloadedWorks(
                    mangaMemberships: mangaMemberships,
                    novelEntries: novelEntries,
                    mangaOwnerNames: ownerNames
                )
            }
        } catch {
            YamiboLog.download.error("Failed to build downloaded work projection: \(error)")
            return []
        }
    }

    private static func downloadedWorks(
        mangaMemberships: [MangaDownloadMembership],
        novelEntries: [NovelDownloadEntry],
        mangaOwnerNames: [String: String]
    ) -> [DownloadedWork] {
        var works: [DownloadedWork] = []

        for entries in Dictionary(grouping: novelEntries, by: \.id.groupID).values {
            guard let representative = entries.max(by: { $0.updatedAt < $1.updatedAt }) else { continue }
            works.append(
                DownloadedWork(
                    id: representative.id.groupID,
                    title: representative.ownerTitle,
                    downloadedEntryCount: entries.count,
                    updatedAt: representative.updatedAt,
                    launchTarget: .novel(
                        threadID: representative.document.threadID,
                        authorID: representative.document.resolvedAuthorID,
                        downloadedView: representative.document.view
                    )
                )
            )
        }

        for entries in Dictionary(grouping: mangaMemberships, by: { membership in
            DownloadGroupID(readerKind: .manga, ownerKey: membership.ownerName)
        }).values {
            guard let representative = entries.max(by: { $0.createdAt < $1.createdAt }) else { continue }
            works.append(
                DownloadedWork(
                    id: DownloadGroupID(readerKind: .manga, ownerKey: representative.ownerName),
                    title: mangaOwnerNames[representative.ownerName] ?? representative.ownerName,
                    downloadedEntryCount: entries.count,
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
