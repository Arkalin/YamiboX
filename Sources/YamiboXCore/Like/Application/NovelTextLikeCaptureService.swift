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
    /// The style to paint the new (or merged) annotation with — the reader's
    /// sticky "last colour I chose". On a merge it overwrites every subsumed
    /// item's style, because the merged range is one annotation.
    package var style: LikeStyle
    /// Clause context around the selection, sliced by the caller while it
    /// still has the laid-out document in hand (see `LikeItem.excerptPrefix`).
    package var excerptPrefix: String?
    package var excerptSuffix: String?

    package init(
        workKey: LikeWorkKey,
        start: NovelTextViewportSemanticTextPosition,
        end: NovelTextViewportSemanticTextPosition,
        excerptText: String,
        view: Int,
        resolvedAuthorID: String?,
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
        // Both endpoints must live in the same chapter — nothing below this
        // layer enforces it, and a cross-chapter range would render happily
        // while being unorderable and unresolvable after a page change.
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
        // The drag may have run backwards, and the two endpoints may be in
        // different segments, so document order — not raw offsets — decides
        // which is which.
        let orderedForward = NovelLikeTextEndpointOrdering.compare(requestedStart, requestedEnd) != .orderedDescending
        let requestAnchor = NovelTextLikeAnchor(
            chapterIdentity: chapterIdentity,
            start: orderedForward ? requestedStart : requestedEnd,
            end: orderedForward ? requestedEnd : requestedStart,
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
                    excerptPrefix: request.excerptPrefix,
                    excerptSuffix: request.excerptSuffix,
                    style: request.style,
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
        // The union spans from the earliest start to the latest end in
        // document order, which `compare` resolves across segments as well as
        // within one.
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
        guard let mergedExcerpt = excerptTextForRange(unionAnchor) else {
            throw YamiboError.underlying("Novel text like capture could not recapture the merged excerpt text.")
        }

        // Every note the merge subsumes is carried into the survivor, in
        // document order. Losing a note the user typed is not recoverable; a
        // slightly long concatenated note is.
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

        // The context fields belong to whichever contributor's endpoint became
        // the union's — a prefix describes the text before one specific start,
        // so any other contributor's prefix would describe the middle of the
        // merged range.
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

        // Unstructured: same cancellation guard as the add path above.
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
                date: date
            )
        }.value
        return .merged(result.item)
    }
}
