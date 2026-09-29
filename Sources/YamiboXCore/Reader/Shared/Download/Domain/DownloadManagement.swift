import Foundation

public enum DownloadReaderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case manga
    case novel
}

public struct DownloadWorkID: Codable, Hashable, Sendable {
    public var readerKind: DownloadReaderKind
    public var rawValue: String

    public init(readerKind: DownloadReaderKind, rawValue: String) {
        self.readerKind = readerKind
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct DownloadGroupID: Codable, Hashable, Sendable {
    public var readerKind: DownloadReaderKind
    public var ownerKey: String

    public init(readerKind: DownloadReaderKind, ownerKey: String) {
        self.readerKind = readerKind
        self.ownerKey = ownerKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct DownloadEntryID: Codable, Hashable, Sendable {
    public var readerKind: DownloadReaderKind
    public var ownerKey: String
    public var entryKey: String

    public init(readerKind: DownloadReaderKind, ownerKey: String, entryKey: String) {
        self.readerKind = readerKind
        self.ownerKey = ownerKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.entryKey = entryKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var groupID: DownloadGroupID {
        DownloadGroupID(readerKind: readerKind, ownerKey: ownerKey)
    }
}

public enum DownloadWorkState: String, Codable, Hashable, Sendable {
    case queued
    case running
    case paused
    case failed
}

public struct DownloadProgress: Codable, Hashable, Sendable {
    public var completedUnitCount: Int
    public var targetUnitCount: Int

    public var fractionCompleted: Double {
        guard targetUnitCount > 0 else { return 0 }
        return min(1, Double(completedUnitCount) / Double(targetUnitCount))
    }

    public init(completedUnitCount: Int, targetUnitCount: Int) {
        self.targetUnitCount = max(0, targetUnitCount)
        self.completedUnitCount = min(max(0, completedUnitCount), self.targetUnitCount)
    }
}

public enum DownloadEntryState: String, Codable, Hashable, Sendable {
    case downloaded
    case queued
    case running
    case paused
    case failed

    public init(workState: DownloadWorkState) {
        switch workState {
        case .queued:
            self = .queued
        case .running:
            self = .running
        case .paused:
            self = .paused
        case .failed:
            self = .failed
        }
    }
}

public struct DownloadManagementEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: DownloadEntryID
    public var title: String
    public var byteCount: Int
    public var state: DownloadEntryState
    public var updatedAt: Date
    public var workID: DownloadWorkID?

    public init(
        id: DownloadEntryID,
        title: String,
        byteCount: Int,
        state: DownloadEntryState,
        updatedAt: Date,
        workID: DownloadWorkID? = nil
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.byteCount = max(0, byteCount)
        self.state = state
        self.updatedAt = updatedAt
        self.workID = workID
    }
}

public struct DownloadManagementGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: DownloadGroupID
    public var title: String
    public var byteCount: Int
    public var downloadedCount: Int
    public var pendingCount: Int
    public var failedCount: Int
    public var updatedAt: Date
    public var entries: [DownloadManagementEntry]

    public init(
        id: DownloadGroupID,
        title: String,
        byteCount: Int,
        downloadedCount: Int,
        pendingCount: Int,
        failedCount: Int,
        updatedAt: Date,
        entries: [DownloadManagementEntry]
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.byteCount = max(0, byteCount)
        self.downloadedCount = max(0, downloadedCount)
        self.pendingCount = max(0, pendingCount)
        self.failedCount = max(0, failedCount)
        self.updatedAt = updatedAt
        self.entries = entries
    }
}

public struct DownloadManagementSnapshot: Codable, Hashable, Sendable {
    public var groups: [DownloadManagementGroup]

    public var totalByteCount: Int {
        groups.reduce(0) { $0 + $1.byteCount }
    }

    public var pendingCount: Int {
        groups.reduce(0) { $0 + $1.pendingCount }
    }

    public init(groups: [DownloadManagementGroup]) {
        self.groups = groups
    }
}

/// The concrete reader route that can be reconstructed from an on-disk download
/// entry when no newer reading-progress record exists.
public enum DownloadedWorkLaunchTarget: Codable, Hashable, Sendable {
    case novel(threadID: String, authorID: String?, downloadedView: Int)
    case manga(threadID: String, chapterTitle: String, chapterView: Int, forumID: String?)
}

/// One work with at least one fully downloaded source entry. This is intentionally
/// narrower than ``DownloadManagementGroup``: it has no queue state or
/// destructive-management concerns, so reading surfaces can safely use it as
/// a gallery data source.
public struct DownloadedWork: Codable, Hashable, Identifiable, Sendable {
    public var id: DownloadGroupID
    public var title: String
    public var downloadedEntryCount: Int
    public var updatedAt: Date
    public var launchTarget: DownloadedWorkLaunchTarget

    public init(
        id: DownloadGroupID,
        title: String,
        downloadedEntryCount: Int,
        updatedAt: Date,
        launchTarget: DownloadedWorkLaunchTarget
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.downloadedEntryCount = max(0, downloadedEntryCount)
        self.updatedAt = updatedAt
        self.launchTarget = launchTarget
    }
}

public struct DownloadQueueWorkProjection: Codable, Hashable, Identifiable, Sendable {
    public var id: DownloadWorkID
    public var groupID: DownloadGroupID
    public var entryID: DownloadEntryID
    public var ownerTitle: String
    public var title: String
    public var progress: DownloadProgress
    public var state: DownloadWorkState
    public var failureMessage: String?
    public var currentBytesPerSecond: Int
    public var insertionIndex: Int

    public init(
        id: DownloadWorkID,
        groupID: DownloadGroupID,
        entryID: DownloadEntryID,
        ownerTitle: String,
        title: String,
        progress: DownloadProgress,
        state: DownloadWorkState,
        failureMessage: String?,
        currentBytesPerSecond: Int,
        insertionIndex: Int
    ) {
        self.id = id
        self.groupID = groupID
        self.entryID = entryID
        self.ownerTitle = ownerTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.progress = progress
        self.state = state
        self.failureMessage = failureMessage
        self.currentBytesPerSecond = max(0, currentBytesPerSecond)
        self.insertionIndex = max(1, insertionIndex)
    }
}

public struct DownloadProcessingWork: Hashable, Identifiable, Sendable {
    public var id: DownloadWorkID
    public var entryID: DownloadEntryID
    public var ownerTitle: String
    public var title: String
    public var targetImageURLs: [URL]
    public var completedImageURLs: [URL]
    public var retainsInlineImages: Bool
    public var state: DownloadWorkState
    public var failureMessage: String?
    public var currentBytesPerSecond: Int
    public var insertionIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: DownloadWorkID,
        entryID: DownloadEntryID,
        ownerTitle: String,
        title: String,
        targetImageURLs: [URL],
        completedImageURLs: [URL],
        retainsInlineImages: Bool,
        state: DownloadWorkState,
        failureMessage: String?,
        currentBytesPerSecond: Int,
        insertionIndex: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.entryID = entryID
        self.ownerTitle = ownerTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetImageURLs = targetImageURLs.removingDuplicateURLs()
        self.completedImageURLs = completedImageURLs.removingDuplicateURLs()
        self.retainsInlineImages = retainsInlineImages
        self.state = state
        self.failureMessage = failureMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.failureMessage?.isEmpty == true {
            self.failureMessage = nil
        }
        self.currentBytesPerSecond = max(0, currentBytesPerSecond)
        self.insertionIndex = max(1, insertionIndex)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DownloadQueueGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: DownloadGroupID
    public var title: String
    public var works: [DownloadQueueWorkProjection]

    public var earliestInsertionIndex: Int {
        works.map(\.insertionIndex).min() ?? .max
    }

    public init(id: DownloadGroupID, title: String, works: [DownloadQueueWorkProjection]) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.works = works
    }
}

public struct DownloadQueueProjection: Codable, Hashable, Sendable {
    public var groups: [DownloadQueueGroup]

    public var unfinishedCount: Int {
        groups.reduce(0) { $0 + $1.works.count }
    }

    public init(groups: [DownloadQueueGroup]) {
        self.groups = groups
    }

    public static func project(
        works: [DownloadQueueWorkProjection],
        mangaDirectoriesByOwnerName: [String: MangaDirectory] = [:]
    ) -> DownloadQueueProjection {
        let grouped = Dictionary(grouping: works, by: \.groupID)
        let groups = grouped.values.map { ownerWorks in
            let first = ownerWorks[0]
            let sortedWorks = sortWorks(ownerWorks, directory: mangaDirectoriesByOwnerName[first.groupID.ownerKey])
            return DownloadQueueGroup(id: first.groupID, title: first.ownerTitle, works: sortedWorks)
        }
        .sorted { lhs, rhs in
            if lhs.earliestInsertionIndex != rhs.earliestInsertionIndex {
                return lhs.earliestInsertionIndex < rhs.earliestInsertionIndex
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return DownloadQueueProjection(groups: groups)
    }

    private static func sortWorks(
        _ works: [DownloadQueueWorkProjection],
        directory: MangaDirectory?
    ) -> [DownloadQueueWorkProjection] {
        guard works.first?.groupID.readerKind == .manga else {
            return works.sorted { lhs, rhs in
                if lhs.insertionIndex != rhs.insertionIndex {
                    return lhs.insertionIndex < rhs.insertionIndex
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }

        let directoryOrder = Dictionary(
            uniqueKeysWithValues: (directory?.chapters ?? []).enumerated().map { ($0.element.tid, $0.offset) }
        )
        return works.sorted { lhs, rhs in
            let lhsDirectoryIndex = directoryOrder[lhs.entryID.entryKey]
            let rhsDirectoryIndex = directoryOrder[rhs.entryID.entryKey]
            if let lhsDirectoryIndex, let rhsDirectoryIndex, lhsDirectoryIndex != rhsDirectoryIndex {
                return lhsDirectoryIndex < rhsDirectoryIndex
            }
            if lhsDirectoryIndex != nil, rhsDirectoryIndex == nil {
                return true
            }
            if lhsDirectoryIndex == nil, rhsDirectoryIndex != nil {
                return false
            }
            if lhs.insertionIndex != rhs.insertionIndex {
                return lhs.insertionIndex < rhs.insertionIndex
            }
            return lhs.entryID.entryKey.localizedStandardCompare(rhs.entryID.entryKey) == .orderedAscending
        }
    }
}
