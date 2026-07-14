import Foundation

package struct NovelTextLikeCaptureRequest: Sendable {
    package var workKey: LikeWorkKey
    package var start: NovelTextViewportSemanticTextPosition
    package var end: NovelTextViewportSemanticTextPosition
    package var excerptText: String
    /// The forum page currently on screen when the selection was made (see
    /// `NovelTextLikeAnchor.view` for why this can't be recovered from
    /// `chapterIdentity` after the fact).
    package var view: Int
    /// The active projection's cache-key identity at selection time (see
    /// `NovelTextLikeAnchor.resolvedAuthorID`).
    package var resolvedAuthorID: String?

    package init(
        workKey: LikeWorkKey,
        start: NovelTextViewportSemanticTextPosition,
        end: NovelTextViewportSemanticTextPosition,
        excerptText: String,
        view: Int,
        resolvedAuthorID: String?
    ) {
        self.workKey = workKey
        self.start = start
        self.end = end
        self.excerptText = excerptText
        self.view = view
        self.resolvedAuthorID = resolvedAuthorID
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

    // Forwards request.excerptText verbatim even for a merge outcome; use the
    // excerptTextForRange overload when the caller can re-slice the union range.
    @discardableResult
    package func like(_ request: NovelTextLikeCaptureRequest, date: Date = .now) async throws -> LikeCaptureOutcome {
        try await like(request, excerptTextForRange: { _ in request.excerptText }, date: date)
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
        guard request.start.textSegmentIdentity == request.end.textSegmentIdentity else {
            throw YamiboError.underlying("Novel text like capture requires a single-segment selection.")
        }
        let segment = request.start.textSegmentIdentity
        let location = min(request.start.displayedTextOffset, request.end.displayedTextOffset)
        let upperBound = max(request.start.displayedTextOffset, request.end.displayedTextOffset)
        let requestAnchor = NovelTextLikeAnchor(
            chapterIdentity: chapterIdentity,
            textSegmentIdentity: segment,
            range: NovelCharacterRange(location: location, length: upperBound - location),
            view: request.view,
            resolvedAuthorID: request.resolvedAuthorID
        )

        let existing = await likeStore.likes(for: request.workKey).filter { $0.kind == .text }
        var overlapping: [(item: LikeItem, anchor: NovelTextLikeAnchor)] = []
        for item in existing {
            guard case let .novelText(anchor) = item.anchor,
                  NovelLikeTextEndpointOrdering.overlapsOrTouches(anchor, requestAnchor) else {
                continue
            }
            overlapping.append((item, anchor))
        }

        guard !overlapping.isEmpty else {
            // Unstructured: this write must land even if the calling Task (a
            // text-selection edit-menu action) is cancelled first.
            let result = try await Task {
                try await likeStore.upsertTextLike(
                    workKey: request.workKey,
                    anchor: requestAnchor,
                    excerptText: request.excerptText,
                    date: date
                )
            }.value
            return .added(result.item)
        }

        if overlapping.count == 1, overlapping[0].anchor == requestAnchor {
            return .alreadyLiked(overlapping[0].item)
        }

        var survivor = overlapping[0]
        for candidate in overlapping.dropFirst() where candidate.item.updatedAt > survivor.item.updatedAt {
            survivor = candidate
        }
        let unionLocation = overlapping.reduce(location) { min($0, $1.anchor.range.location) }
        let unionUpperBound = overlapping.reduce(upperBound) { max($0, $1.anchor.range.upperBound) }
        let unionAnchor = NovelTextLikeAnchor(
            chapterIdentity: chapterIdentity,
            textSegmentIdentity: segment,
            range: NovelCharacterRange(location: unionLocation, length: unionUpperBound - unionLocation),
            view: request.view,
            resolvedAuthorID: request.resolvedAuthorID
        )
        guard let mergedExcerpt = excerptTextForRange(unionAnchor) else {
            throw YamiboError.underlying("Novel text like capture could not recapture the merged excerpt text.")
        }

        // Unstructured: same cancellation guard as the add path above.
        let result = try await Task {
            try await likeStore.upsertTextLike(
                id: survivor.item.id,
                workKey: request.workKey,
                anchor: unionAnchor,
                excerptText: mergedExcerpt,
                date: date
            )
        }.value
        return .merged(result.item)
    }
}
