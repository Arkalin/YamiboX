public struct MangaChapterWindowSnapshot: Hashable, Sendable {
    public var documents: [MangaReaderProjection]
    public var resolvedPosition: MangaReadingPosition?

    public init(
        documents: [MangaReaderProjection],
        resolvedPosition: MangaReadingPosition?
    ) {
        self.documents = documents
        self.resolvedPosition = resolvedPosition
    }
}

public enum MangaChapterWindowNoopReason: Hashable, Sendable {
    case duplicateChapter
    case unknownChapter
    case notAdjacent
}

public enum MangaChapterWindowMutationResult: Hashable, Sendable {
    case changed(MangaChapterWindowSnapshot)
    case unchanged(MangaChapterWindowSnapshot, reason: MangaChapterWindowNoopReason)
}

public struct MangaChapterWindow: Hashable, Sendable {
    public private(set) var directory: MangaDirectory
    public private(set) var documents: [MangaReaderProjection]
    public private(set) var position: MangaReadingPosition?
    private let maxLoadedDocuments: Int

    public init(
        directory: MangaDirectory,
        initialDocument: MangaReaderProjection,
        position: MangaReadingPosition? = nil,
        maxLoadedDocuments: Int = 10
    ) {
        self.directory = directory
        self.documents = [initialDocument]
        self.position = nil
        self.maxLoadedDocuments = max(1, maxLoadedDocuments)
        self.position = clampedPosition(position)
    }

    public init?(
        directory: MangaDirectory,
        documents: [MangaReaderProjection],
        position: MangaReadingPosition? = nil,
        maxLoadedDocuments: Int = 10
    ) {
        guard !documents.isEmpty,
              Self.hasUniqueChapterIdentities(documents) else {
            return nil
        }

        self.directory = directory
        self.documents = documents
        self.position = nil
        self.maxLoadedDocuments = max(1, maxLoadedDocuments)
        self.position = clampedPosition(position)
        trimDocuments(preserving: self.position?.tid ?? self.documents.first?.tid)
        self.position = clampedPosition(self.position)
    }

    public var snapshot: MangaChapterWindowSnapshot {
        MangaChapterWindowSnapshot(
            documents: documents,
            resolvedPosition: position
        )
    }

    public var resolvedPosition: MangaReadingPosition? {
        position
    }

    public mutating func updatePosition(_ position: MangaReadingPosition?) {
        self.position = clampedPosition(position)
    }

    public mutating func moveToLoadedPage(at pageIndex: Int) -> MangaChapterWindowSnapshot {
        guard let position = positionForLoadedPage(at: pageIndex) else {
            self.position = nil
            return snapshot
        }

        self.position = position
        return snapshot
    }

    public mutating func updateDirectory(
        _ directory: MangaDirectory,
        preserving position: MangaReadingPosition?
    ) -> MangaChapterWindowSnapshot {
        let currentPosition = self.position
        self.directory = directory
        reorderDocumentsToMatchDirectory()

        let anchorTID = clampedPosition(position)?.tid
            ?? clampedPosition(currentPosition)?.tid
            ?? documents.first?.tid
        trimDocuments(preserving: anchorTID)

        self.position = clampedPosition(position) ?? clampedPosition(currentPosition)
        return snapshot
    }

    public mutating func removeLoadedDocuments(
        withTIDs tids: Set<String>,
        preserving position: MangaReadingPosition?
    ) -> MangaChapterWindowSnapshot {
        let targetTIDs = Set(tids.compactMap(Self.trimmedNonEmpty))
        guard !targetTIDs.isEmpty else { return snapshot }

        let currentPosition = self.position
        let preservedTID = clampedPosition(position)?.tid
            ?? clampedPosition(currentPosition)?.tid
        let remainingDocuments = documents.filter { document in
            document.tid == preservedTID || !targetTIDs.contains(document.tid)
        }
        guard !remainingDocuments.isEmpty else { return snapshot }

        documents = remainingDocuments
        reorderDocumentsToMatchDirectory()
        trimDocuments(preserving: preservedTID ?? documents.first?.tid)
        self.position = clampedPosition(position) ?? clampedPosition(currentPosition)
        return snapshot
    }

    public mutating func insertAdjacentDocument(
        _ document: MangaReaderProjection
    ) -> MangaChapterWindowMutationResult {
        insertAdjacentDocument(document, preserving: nil)
    }

    public mutating func insertAdjacentDocument(
        _ document: MangaReaderProjection,
        preserving position: MangaReadingPosition?
    ) -> MangaChapterWindowMutationResult {
        let unchangedSnapshot = snapshot
        guard !documents.contains(where: { $0.tid == document.tid }) else {
            return .unchanged(unchangedSnapshot, reason: .duplicateChapter)
        }
        guard chapterOrder()[document.tid] != nil else {
            return .unchanged(unchangedSnapshot, reason: .unknownChapter)
        }
        guard isAdjacentToLoadedRange(document.tid) else {
            return .unchanged(unchangedSnapshot, reason: .notAdjacent)
        }

        let requestedPosition = position ?? self.position
        documents.append(document)
        reorderDocumentsToMatchDirectory()

        let anchorTID = clampedPosition(requestedPosition)?.tid ?? document.tid
        trimDocuments(preserving: anchorTID)

        self.position = clampedPosition(requestedPosition)
        return .changed(snapshot)
    }

    public mutating func reset(
        to document: MangaReaderProjection,
        position: MangaReadingPosition?
    ) -> MangaChapterWindowSnapshot {
        documents = [document]
        self.position = clampedPosition(position)
        return snapshot
    }

    public func adjacentChapter(
        from position: MangaReadingPosition,
        delta: Int
    ) -> MangaChapter? {
        guard abs(delta) == 1,
              let index = directory.chapters.firstIndex(where: { $0.tid == position.tid }) else {
            return nil
        }

        let target = index + delta
        guard directory.chapters.indices.contains(target) else { return nil }
        return directory.chapters[target]
    }

    public func adjacentChapterForLoadedRange(delta: Int) -> MangaChapter? {
        guard abs(delta) == 1 else { return nil }
        let anchorTID = delta < 0 ? documents.first?.tid : documents.last?.tid
        guard let anchorTID,
              let index = directory.chapters.firstIndex(where: { $0.tid == anchorTID }) else {
            return nil
        }

        let target = index + delta
        guard directory.chapters.indices.contains(target) else { return nil }
        return directory.chapters[target]
    }

    public func clampedPosition(_ position: MangaReadingPosition?) -> MangaReadingPosition? {
        guard let position,
              let document = documents.first(where: { $0.tid == position.tid }),
              !document.imageURLs.isEmpty else {
            return nil
        }

        return MangaReadingPosition(
            tid: position.tid,
            localIndex: min(max(position.localIndex, 0), document.imageURLs.count - 1)
        )
    }

    private func positionForLoadedPage(at pageIndex: Int) -> MangaReadingPosition? {
        var positions: [MangaReadingPosition] = []
        positions.reserveCapacity(documents.reduce(0) { $0 + $1.imageURLs.count })

        for document in documents {
            for localIndex in document.imageURLs.indices {
                positions.append(MangaReadingPosition(tid: document.tid, localIndex: localIndex))
            }
        }

        guard !positions.isEmpty else { return nil }
        let clampedIndex = min(max(pageIndex, 0), positions.count - 1)
        return positions[clampedIndex]
    }

    private func isAdjacentToLoadedRange(_ tid: String) -> Bool {
        let order = chapterOrder()
        guard let targetIndex = order[tid] else { return false }

        if let firstTID = documents.first?.tid,
           let firstIndex = order[firstTID],
           targetIndex == firstIndex - 1 {
            return true
        }

        if let lastTID = documents.last?.tid,
           let lastIndex = order[lastTID],
           targetIndex == lastIndex + 1 {
            return true
        }

        return false
    }

    private mutating func reorderDocumentsToMatchDirectory() {
        let order = chapterOrder()
        documents = documents.enumerated()
            .sorted { lhs, rhs in
                let lhsOrder = order[lhs.element.tid]
                let rhsOrder = order[rhs.element.tid]

                switch (lhsOrder, rhsOrder) {
                case let (lhsOrder?, rhsOrder?):
                    if lhsOrder != rhsOrder {
                        return lhsOrder < rhsOrder
                    }
                    return lhs.offset < rhs.offset
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    private mutating func trimDocuments(preserving tid: String?) {
        guard let tid else { return }

        while documents.count > maxLoadedDocuments {
            if documents.first?.tid != tid {
                documents.removeFirst()
            } else if documents.last?.tid != tid {
                documents.removeLast()
            } else {
                return
            }
        }
    }

    private func chapterOrder() -> [String: Int] {
        var order: [String: Int] = [:]
        order.reserveCapacity(directory.chapters.count)

        for (index, chapter) in directory.chapters.enumerated() where order[chapter.tid] == nil {
            order[chapter.tid] = index
        }

        return order
    }

    private static func hasUniqueChapterIdentities(_ documents: [MangaReaderProjection]) -> Bool {
        var tids: Set<String> = []
        for document in documents {
            guard tids.insert(document.tid).inserted else { return false }
        }
        return true
    }

    private static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
