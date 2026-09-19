import Foundation

/// Immutable, session-local data shared by every position in one committed layout.
/// Identity is deliberately independent of the presentation's progress revision.
package final class NovelReaderPresentationStructure: Equatable, Sendable {
    package let id = UUID()
    package let generation: UInt64
    package let resolvedAuthorID: String?
    package let surfaces: [NovelReaderSurface]
    package let spreads: [NovelReaderPresentationSpread]
    package let chapters: [NovelReaderChapter]
    package let surfaceIndexByOrdinal: [Int: Int]
    package let spreadIndexBySurfaceIndex: [Int: Int]
    package let surfaceIndexesByView: [Int: [Int]]
    package let localPageNumbers: [Int]
    package let chapterIndexes: [Int?]
    package let chapterEndIndexes: [Int]
    package let chapterTitlesBySurfaceIndex: [Int: String]

    package init(
        generation: UInt64,
        resolvedAuthorID: String?,
        surfaces: [NovelReaderSurface],
        spreads: [NovelReaderPresentationSpread],
        chapters: [NovelReaderChapter]
    ) {
        self.generation = generation
        self.resolvedAuthorID = resolvedAuthorID
        self.surfaces = surfaces
        self.spreads = spreads
        self.chapters = chapters
        surfaceIndexByOrdinal = Dictionary(uniqueKeysWithValues: surfaces.enumerated().map {
            ($0.element.identity.ordinal, $0.offset)
        })
        var spreadIndexes: [Int: Int] = [:]
        for (index, spread) in spreads.enumerated() {
            spreadIndexes[spread.leftSurfaceIndex] = index
            if let right = spread.rightSurfaceIndex { spreadIndexes[right] = index }
        }
        spreadIndexBySurfaceIndex = spreadIndexes
        var indexesByView: [Int: [Int]] = [:]
        var numbers: [Int] = []
        for (index, surface) in surfaces.enumerated() {
            indexesByView[surface.documentView, default: []].append(index)
            numbers.append(indexesByView[surface.documentView, default: []].count)
        }
        surfaceIndexesByView = indexesByView
        localPageNumbers = numbers

        // Preserve original chapter order (including duplicate start pages).
        // Sorting events once lets the page walk avoid a per-page chapter scan.
        let events = chapters.enumerated().sorted {
            if $0.element.startIndex != $1.element.startIndex {
                return $0.element.startIndex < $1.element.startIndex
            }
            return $0.offset < $1.offset
        }
        var remaining = Array(repeating: Int.max, count: events.count + 1)
        for index in events.indices.reversed() {
            remaining[index] = min(events[index].offset, remaining[index + 1])
        }
        var cursor = 0
        var currentChapter: Int?
        var chapterIndexes: [Int?] = []
        var ends: [Int] = []
        var titles: [Int: String] = [:]
        for index in surfaces.indices {
            while cursor < events.count, events[cursor].element.startIndex <= index {
                currentChapter = max(currentChapter ?? -1, events[cursor].offset)
                cursor += 1
            }
            chapterIndexes.append(currentChapter)
            let next = remaining[cursor]
            ends.append(next == Int.max ? surfaces.count : chapters[next].startIndex)
            if let title = surfaces[index].chapterTitle {
                titles[index] = title
            } else if cursor > 0 {
                titles[index] = events[cursor - 1].element.title
            }
        }
        self.chapterIndexes = chapterIndexes
        chapterEndIndexes = ends
        chapterTitlesBySurfaceIndex = titles
    }

    package func spread(containing surfaceIndex: Int) -> NovelReaderPresentationSpread? {
        spreadIndexBySurfaceIndex[surfaceIndex].map { spreads[$0] }
    }

    package static func == (lhs: NovelReaderPresentationStructure, rhs: NovelReaderPresentationStructure) -> Bool {
        lhs === rhs
    }
}
