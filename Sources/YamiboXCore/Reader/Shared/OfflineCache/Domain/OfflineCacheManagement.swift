import Foundation

public enum OfflineCacheReaderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case manga
    case novel
}

public struct OfflineCacheWorkID: Codable, Hashable, Sendable {
    public var readerKind: OfflineCacheReaderKind
    public var rawValue: String

    public init(readerKind: OfflineCacheReaderKind, rawValue: String) {
        self.readerKind = readerKind
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct OfflineCacheGroupID: Codable, Hashable, Sendable {
    public var readerKind: OfflineCacheReaderKind
    public var ownerKey: String

    public init(readerKind: OfflineCacheReaderKind, ownerKey: String) {
        self.readerKind = readerKind
        self.ownerKey = ownerKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct OfflineCacheEntryID: Codable, Hashable, Sendable {
    public var readerKind: OfflineCacheReaderKind
    public var ownerKey: String
    public var entryKey: String

    public init(readerKind: OfflineCacheReaderKind, ownerKey: String, entryKey: String) {
        self.readerKind = readerKind
        self.ownerKey = ownerKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.entryKey = entryKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var groupID: OfflineCacheGroupID {
        OfflineCacheGroupID(readerKind: readerKind, ownerKey: ownerKey)
    }
}

public enum OfflineCacheWorkState: String, Codable, Hashable, Sendable {
    case queued
    case running
    case paused
    case failed
}

public struct OfflineCacheProgress: Codable, Hashable, Sendable {
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

public enum OfflineCacheEntryState: String, Codable, Hashable, Sendable {
    case cached
    case queued
    case running
    case paused
    case failed

    public init(workState: OfflineCacheWorkState) {
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

public struct OfflineCacheManagementEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: OfflineCacheEntryID
    public var title: String
    public var byteCount: Int
    public var state: OfflineCacheEntryState
    public var updatedAt: Date
    public var workID: OfflineCacheWorkID?

    public init(
        id: OfflineCacheEntryID,
        title: String,
        byteCount: Int,
        state: OfflineCacheEntryState,
        updatedAt: Date,
        workID: OfflineCacheWorkID? = nil
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.byteCount = max(0, byteCount)
        self.state = state
        self.updatedAt = updatedAt
        self.workID = workID
    }
}

public struct OfflineCacheManagementGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: OfflineCacheGroupID
    public var title: String
    public var byteCount: Int
    public var cachedCount: Int
    public var pendingCount: Int
    public var failedCount: Int
    public var updatedAt: Date
    public var entries: [OfflineCacheManagementEntry]

    public init(
        id: OfflineCacheGroupID,
        title: String,
        byteCount: Int,
        cachedCount: Int,
        pendingCount: Int,
        failedCount: Int,
        updatedAt: Date,
        entries: [OfflineCacheManagementEntry]
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.byteCount = max(0, byteCount)
        self.cachedCount = max(0, cachedCount)
        self.pendingCount = max(0, pendingCount)
        self.failedCount = max(0, failedCount)
        self.updatedAt = updatedAt
        self.entries = entries
    }
}

public struct OfflineCacheManagementSnapshot: Codable, Hashable, Sendable {
    public var groups: [OfflineCacheManagementGroup]

    public var totalByteCount: Int {
        groups.reduce(0) { $0 + $1.byteCount }
    }

    public var pendingCount: Int {
        groups.reduce(0) { $0 + $1.pendingCount }
    }

    public init(groups: [OfflineCacheManagementGroup]) {
        self.groups = groups
    }
}

public struct OfflineCacheQueueWorkProjection: Codable, Hashable, Identifiable, Sendable {
    public var id: OfflineCacheWorkID
    public var groupID: OfflineCacheGroupID
    public var entryID: OfflineCacheEntryID
    public var ownerTitle: String
    public var title: String
    public var progress: OfflineCacheProgress
    public var state: OfflineCacheWorkState
    public var failureMessage: String?
    public var currentBytesPerSecond: Int
    public var insertionIndex: Int

    public init(
        id: OfflineCacheWorkID,
        groupID: OfflineCacheGroupID,
        entryID: OfflineCacheEntryID,
        ownerTitle: String,
        title: String,
        progress: OfflineCacheProgress,
        state: OfflineCacheWorkState,
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

public struct OfflineCacheProcessingWork: Hashable, Identifiable, Sendable {
    public var id: OfflineCacheWorkID
    public var entryID: OfflineCacheEntryID
    public var ownerTitle: String
    public var title: String
    public var targetImageURLs: [URL]
    public var completedImageURLs: [URL]
    public var retainsInlineImages: Bool
    public var state: OfflineCacheWorkState
    public var failureMessage: String?
    public var currentBytesPerSecond: Int
    public var insertionIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: OfflineCacheWorkID,
        entryID: OfflineCacheEntryID,
        ownerTitle: String,
        title: String,
        targetImageURLs: [URL],
        completedImageURLs: [URL],
        retainsInlineImages: Bool,
        state: OfflineCacheWorkState,
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
        self.targetImageURLs = Self.uniqueURLs(targetImageURLs)
        self.completedImageURLs = Self.uniqueURLs(completedImageURLs)
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

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var output: [URL] = []
        for url in urls where seen.insert(url.absoluteString).inserted {
            output.append(url)
        }
        return output
    }
}

public struct OfflineCacheQueueGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: OfflineCacheGroupID
    public var title: String
    public var works: [OfflineCacheQueueWorkProjection]

    public var earliestInsertionIndex: Int {
        works.map(\.insertionIndex).min() ?? .max
    }

    public init(id: OfflineCacheGroupID, title: String, works: [OfflineCacheQueueWorkProjection]) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.works = works
    }
}

public struct OfflineCacheQueueProjection: Codable, Hashable, Sendable {
    public var groups: [OfflineCacheQueueGroup]

    public var unfinishedCount: Int {
        groups.reduce(0) { $0 + $1.works.count }
    }

    public init(groups: [OfflineCacheQueueGroup]) {
        self.groups = groups
    }

    public static func project(
        works: [OfflineCacheQueueWorkProjection],
        mangaDirectoriesByOwnerName: [String: MangaDirectory] = [:]
    ) -> OfflineCacheQueueProjection {
        let grouped = Dictionary(grouping: works, by: \.groupID)
        let groups = grouped.values.map { ownerWorks in
            let first = ownerWorks[0]
            let sortedWorks = sortWorks(ownerWorks, directory: mangaDirectoriesByOwnerName[first.groupID.ownerKey])
            return OfflineCacheQueueGroup(id: first.groupID, title: first.ownerTitle, works: sortedWorks)
        }
        .sorted { lhs, rhs in
            if lhs.earliestInsertionIndex != rhs.earliestInsertionIndex {
                return lhs.earliestInsertionIndex < rhs.earliestInsertionIndex
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return OfflineCacheQueueProjection(groups: groups)
    }

    private static func sortWorks(
        _ works: [OfflineCacheQueueWorkProjection],
        directory: MangaDirectory?
    ) -> [OfflineCacheQueueWorkProjection] {
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
