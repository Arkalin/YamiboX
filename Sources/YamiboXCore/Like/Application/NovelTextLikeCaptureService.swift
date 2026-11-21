import Foundation

package struct NovelTextLikeCaptureRequest: Sendable {
    package var workKey: ReadingWorkKey
    package var start: NovelTextViewportSemanticTextPosition
    package var end: NovelTextViewportSemanticTextPosition
    package var excerptText: String
    package var view: Int
    package var resolvedAuthorID: String?
    package var chapterTitle: String?
    package var style: LikeStyle
    package var excerptPrefix: String?
    package var excerptSuffix: String?

    package init(
        workKey: ReadingWorkKey,
        start: NovelTextViewportSemanticTextPosition,
        end: NovelTextViewportSemanticTextPosition,
        excerptText: String,
        view: Int,
        resolvedAuthorID: String?,
        chapterTitle: String? = nil,
        style: LikeStyle = .default,
        excerptPrefix: String? = nil,
        excerptSuffix: String? = nil
    ) {
        self.workKey = workKey
        self.start = start
        self.end = end
        self.excerptText = excerptText
        self.view = view
        self.resolvedAuthorID = resolvedAuthorID
        self.chapterTitle = chapterTitle
        self.style = style
        self.excerptPrefix = excerptPrefix
        self.excerptSuffix = excerptSuffix
    }
}

public enum LikeCaptureOutcome: Sendable {
    case added(LikeItem)
    case merged(LikeItem)
    case alreadyLiked(LikeItem)
}

public struct NovelTextLikeCaptureService: Sendable {
    let likeStore: LikeStore

    public init(likeStore: LikeStore) {
        self.likeStore = likeStore
    }

    @discardableResult
    package func like(
        _ request: NovelTextLikeCaptureRequest,
        excerptTextForRange: @Sendable (_ anchor: NovelTextLikeAnchor) -> String?,
        date: Date = .now
    ) async throws -> LikeCaptureOutcome {
        guard let chapterIdentity = request.start.chapterIdentity else {
            throw YamiboError.underlying("Novel text like capture requires a resolved chapter identity.")
        }
        guard request.end.chapterIdentity == chapterIdentity else {
            throw YamiboError.underlying("Novel text like capture requires a single-chapter selection.")
        }
        let requestedStart = NovelLikeTextEndpoint(
            segmentIdentity: request.start.textSegmentIdentity.rawValue,
            offset: request.start.displayedTextOffset
        )
        let requestedEnd = NovelLikeTextEndpoint(
            segmentIdentity: request.end.textSegmentIdentity.rawValue,
            offset: request.end.displayedTextOffset
        )
        let orderedForward = NovelLikeTextEndpointOrdering.compare(requestedStart, requestedEnd) != .orderedDescending
        let requestAnchor = NovelTextLikeAnchor(
            chapterIdentity: chapterIdentity,
            start: orderedForward ? requestedStart : requestedEnd,
            end: orderedForward ? requestedEnd : requestedStart,
            view: request.view,
            resolvedAuthorID: request.resolvedAuthorID
        )

        let existing = try await likeStore.likes(for: request.workKey).filter { $0.kind == .text }
        var overlapping: [(item: LikeItem, anchor: NovelTextLikeAnchor)] = []
        for item in existing {
            guard case let .novelText(anchor) = item.anchor,
                  NovelLikeTextEndpointOrdering.overlapsOrTouches(anchor, requestAnchor) else {
                continue
            }
            overlapping.append((item, anchor))
        }

        guard !overlapping.isEmpty else {
            let result = try await Task {
                try await likeStore.upsertTextLike(
                    workKey: request.workKey,
                    anchor: requestAnchor,
                    excerptText: request.excerptText,
                    excerptPrefix: request.excerptPrefix,
                    excerptSuffix: request.excerptSuffix,
                    style: request.style,
                    chapterTitle: request.chapterTitle,
                    date: date
                )
            }.value
            return .added(result.item)
        }

        if overlapping.count == 1, overlapping[0].anchor == requestAnchor {
            var item = overlapping[0].item
            if item.chapterTitle == nil {
                item.chapterTitle = LikeItem.normalizedChapterTitle(request.chapterTitle)
                try await likeStore.resolveChapterTitles([item])
            }
            return .alreadyLiked(item)
        }

        var survivor = overlapping[0]
        for candidate in overlapping.dropFirst() where candidate.item.updatedAt > survivor.item.updatedAt {
            survivor = candidate
        }
        let unionStart = overlapping.reduce(requestAnchor.start) { earliest, entry in
            NovelLikeTextEndpointOrdering.compare(entry.anchor.start, earliest) == .orderedAscending
                ? entry.anchor.start
                : earliest
        }
        let unionEnd = overlapping.reduce(requestAnchor.end) { latest, entry in
            NovelLikeTextEndpointOrdering.compare(entry.anchor.end, latest) == .orderedDescending
                ? entry.anchor.end
                : latest
        }
        let unionAnchor = NovelTextLikeAnchor(
            chapterIdentity: chapterIdentity,
            start: unionStart,
            end: unionEnd,
            view: request.view,
            resolvedAuthorID: request.resolvedAuthorID
        )
        guard let mergedExcerpt = unionAnchor.start == requestAnchor.start && unionAnchor.end == requestAnchor.end
                ? request.excerptText : excerptTextForRange(unionAnchor) else {
            throw YamiboError.underlying("Novel text like capture could not recapture the merged excerpt text.")
        }

        let mergedNote = overlapping
            .sorted { lhs, rhs in
                NovelLikeTextEndpointOrdering.compare(lhs.anchor.start, rhs.anchor.start) == .orderedAscending
            }
            .compactMap { entry -> String? in
                guard let note = entry.item.note?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !note.isEmpty else {
                    return nil
                }
                return note
            }
            .joined(separator: "\n\n")

        var unionPrefix = unionStart == requestAnchor.start ? request.excerptPrefix : nil
        var unionSuffix = unionEnd == requestAnchor.end ? request.excerptSuffix : nil
        for entry in overlapping {
            if entry.anchor.start == unionStart, unionPrefix == nil {
                unionPrefix = entry.item.excerptPrefix
            }
            if entry.anchor.end == unionEnd, unionSuffix == nil {
                unionSuffix = entry.item.excerptSuffix
            }
        }

        let result = try await Task {
            try await likeStore.upsertTextLike(
                id: survivor.item.id,
                workKey: request.workKey,
                anchor: unionAnchor,
                excerptText: mergedExcerpt,
                excerptPrefix: unionPrefix,
                excerptSuffix: unionSuffix,
                style: request.style,
                note: mergedNote.isEmpty ? nil : mergedNote,
                chapterTitle: request.chapterTitle,
                date: date
            )
        }.value
        return .merged(result.item)
    }
}
