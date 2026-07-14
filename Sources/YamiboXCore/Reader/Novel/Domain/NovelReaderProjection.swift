import Foundation

public enum NovelReaderProjectionLoadSource: Hashable, Sendable {
    case online
    case offlineFallback(updatedAt: Date?)

    public var isOfflineFallback: Bool {
        if case .offlineFallback = self {
            return true
        }
        return false
    }
}

public struct NovelReaderProjectionLoad: Hashable, Sendable {
    public var projection: NovelReaderProjection
    public var source: NovelReaderProjectionLoadSource

    public init(
        projection: NovelReaderProjection,
        source: NovelReaderProjectionLoadSource = .online
    ) {
        self.projection = projection
        self.source = source
    }
}

public struct NovelReaderProjection: Codable, Hashable, Sendable {
    public static let schemaVersion = 7

    public var threadID: String
    public var view: Int
    public var maxView: Int
    public var resolvedAuthorID: String?
    public var retainedChapterCount: Int
    public var filteredChapterCandidateCount: Int
    public var segments: [NovelReaderSegment]
    public var segmentSources: [NovelReaderSegmentSource?]
    public var segmentSemantics: [NovelReaderSegmentSemantics?]
    public var projectionSourceFingerprint: String?
    public var projectionSchemaVersion: Int?
    public var fetchedAt: Date

    public init(
        threadID: String,
        view: Int,
        maxView: Int,
        resolvedAuthorID: String? = nil,
        retainedChapterCount: Int = 0,
        filteredChapterCandidateCount: Int = 0,
        segments: [NovelReaderSegment],
        segmentSources: [NovelReaderSegmentSource?]? = nil,
        segmentSemantics: [NovelReaderSegmentSemantics?]? = nil,
        projectionSourceFingerprint: String? = nil,
        projectionSchemaVersion: Int? = nil,
        fetchedAt: Date = .now
    ) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!normalizedThreadID.isEmpty, "NovelReaderProjection requires a Yamibo thread tid")
        self.threadID = normalizedThreadID
        self.view = max(1, view)
        self.maxView = max(self.view, maxView)
        self.resolvedAuthorID = resolvedAuthorID
        self.retainedChapterCount = retainedChapterCount
        self.filteredChapterCandidateCount = filteredChapterCandidateCount
        self.segments = segments
        self.segmentSources = segmentSources ?? Array(repeating: nil, count: segments.count)
        self.segmentSemantics = segmentSemantics ?? Self.defaultSegmentSemantics(
            segments: segments,
            segmentSources: self.segmentSources,
            threadID: self.threadID,
            view: self.view
        )
        self.projectionSourceFingerprint = projectionSourceFingerprint
        self.projectionSchemaVersion = projectionSchemaVersion
        self.fetchedAt = fetchedAt
    }

    func source(forSegmentIndex index: Int) -> NovelReaderSegmentSource? {
        guard segmentSources.indices.contains(index) else { return nil }
        return segmentSources[index]
    }

    func semantics(forSegmentIndex index: Int) -> NovelReaderSegmentSemantics? {
        guard segmentSemantics.indices.contains(index) else { return nil }
        return segmentSemantics[index]
    }
}

extension NovelReaderProjection {
    static func defaultSegmentSemantics(
        segments: [NovelReaderSegment],
        segmentSources: [NovelReaderSegmentSource?],
        threadID: String,
        view: Int
    ) -> [NovelReaderSegmentSemantics?] {
        var occurrenceByPostID: [String: Int] = [:]
        var sourceOccurrence = 0
        var textOccurrenceByChapter: [NovelChapterIdentity: Int] = [:]

        return segments.enumerated().map { index, segment in
            guard let chapterTitle = segment.chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !chapterTitle.isEmpty else {
                return nil
            }
            let source = segmentSources.indices.contains(index) ? segmentSources[index] : nil
            let chapterIdentity: NovelChapterIdentity
            if let ownerPostID = source?.ownerPostID, !ownerPostID.isEmpty {
                let postOccurrence = occurrenceByPostID[ownerPostID] ?? 0
                occurrenceByPostID[ownerPostID] = postOccurrence + 1
                chapterIdentity = NovelChapterIdentity(rawValue: "post:\(ownerPostID)#chapter:\(postOccurrence)")
            } else {
                chapterIdentity = NovelChapterIdentity(
                    rawValue: "thread:\(threadID)#view:\(max(1, view))#chapter:\(sourceOccurrence)"
                )
                sourceOccurrence += 1
            }

            switch segment {
            case let .text(text, _):
                let textOccurrence = textOccurrenceByChapter[chapterIdentity] ?? 0
                textOccurrenceByChapter[chapterIdentity] = textOccurrence + 1
                return NovelReaderSegmentSemantics(
                    chapterIdentity: chapterIdentity,
                    textSegmentIdentity: NovelTextSegmentIdentity(
                        rawValue: "\(chapterIdentity.rawValue)#text:\(textOccurrence)"
                    ),
                    chapterTitleRange: defaultChapterTitleRange(chapterTitle: chapterTitle, text: text)
                )
            case .image:
                return NovelReaderSegmentSemantics(chapterIdentity: chapterIdentity)
            }
        }
    }

    private static func defaultChapterTitleRange(chapterTitle: String, text: String) -> NovelCharacterRange? {
        let normalizedTitle = NovelChapterTitleNormalizer.normalize(chapterTitle)
        guard let normalizedTitle,
              !normalizedTitle.isEmpty,
              text.hasPrefix(normalizedTitle) else {
            return nil
        }
        return NovelCharacterRange(location: 0, length: normalizedTitle.count)
    }
}

package extension NovelReaderProjection {
    func previewSourceText(from position: NovelTextViewportSemanticTextPosition) -> String {
        guard let startSegmentIndex = segmentSemantics.firstIndex(where: {
            $0?.textSegmentIdentity == position.textSegmentIdentity
        }), segments.indices.contains(startSegmentIndex) else {
            return ""
        }

        let fragments = segments[startSegmentIndex...].enumerated().compactMap { offset, segment -> String? in
            guard case let .text(text, _) = segment else { return nil }
            let previewText = offset == 0
                ? String(text.dropFirst(min(max(position.displayedTextOffset, 0), text.count)))
                : text
            let trimmed = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return fragments.joined(separator: "\n\n")
    }
}

public struct NovelReaderChapter: Codable, Hashable, Sendable {
    public var ordinal: Int
    public var title: String
    public var startIndex: Int
    public var chapterCommentTarget: ReaderChapterCommentTarget?

    public init(
        ordinal: Int,
        title: String,
        startIndex: Int,
        chapterCommentTarget: ReaderChapterCommentTarget? = nil
    ) {
        self.ordinal = max(0, ordinal)
        self.title = title
        self.startIndex = startIndex
        self.chapterCommentTarget = chapterCommentTarget
    }
}
