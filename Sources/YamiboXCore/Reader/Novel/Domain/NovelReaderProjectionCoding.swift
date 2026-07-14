import Foundation

extension NovelReaderProjection {
    private enum CodingKeys: String, CodingKey {
        case threadID
        case view
        case maxView
        case resolvedAuthorID
        case retainedChapterCount
        case filteredChapterCandidateCount
        case segments
        case segmentSources
        case segmentSemantics
        case projectionSourceFingerprint
        case projectionSchemaVersion
        case fetchedAt
        case schemaVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [CodingKeys.schemaVersion],
                    debugDescription: "Unsupported reader projection schema version \(schemaVersion)."
                )
            )
        }
        let segments = try container.decode([NovelReaderSegment].self, forKey: .segments)
        let segmentSemantics = try container.decode([NovelReaderSegmentSemantics?].self, forKey: .segmentSemantics)
        try Self.validate(segmentSemantics: segmentSemantics, segments: segments)
        self.init(
            threadID: try container.decode(String.self, forKey: .threadID),
            view: try container.decode(Int.self, forKey: .view),
            maxView: try container.decode(Int.self, forKey: .maxView),
            resolvedAuthorID: try container.decodeIfPresent(String.self, forKey: .resolvedAuthorID),
            retainedChapterCount: try container.decode(Int.self, forKey: .retainedChapterCount),
            filteredChapterCandidateCount: try container.decode(Int.self, forKey: .filteredChapterCandidateCount),
            segments: segments,
            segmentSources: try container.decode([NovelReaderSegmentSource?].self, forKey: .segmentSources),
            segmentSemantics: segmentSemantics,
            projectionSourceFingerprint: try container.decodeIfPresent(String.self, forKey: .projectionSourceFingerprint),
            projectionSchemaVersion: try container.decodeIfPresent(Int.self, forKey: .projectionSchemaVersion),
            fetchedAt: try container.decode(Date.self, forKey: .fetchedAt)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        try Self.validate(segmentSemantics: segmentSemantics, segments: segments)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(view, forKey: .view)
        try container.encode(maxView, forKey: .maxView)
        try container.encodeIfPresent(resolvedAuthorID, forKey: .resolvedAuthorID)
        try container.encode(retainedChapterCount, forKey: .retainedChapterCount)
        try container.encode(filteredChapterCandidateCount, forKey: .filteredChapterCandidateCount)
        try container.encode(segments, forKey: .segments)
        try container.encode(segmentSources, forKey: .segmentSources)
        try container.encode(segmentSemantics, forKey: .segmentSemantics)
        try container.encodeIfPresent(projectionSourceFingerprint, forKey: .projectionSourceFingerprint)
        try container.encodeIfPresent(projectionSchemaVersion, forKey: .projectionSchemaVersion)
        try container.encode(fetchedAt, forKey: .fetchedAt)
    }

    private static func validate(
        segmentSemantics: [NovelReaderSegmentSemantics?],
        segments: [NovelReaderSegment]
    ) throws {
        guard segmentSemantics.count == segments.count else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Reader segment semantics count does not match segments.")
            )
        }

        for (index, segment) in segments.enumerated() {
            let semantics = segmentSemantics[index]
            switch segment {
            case let .text(text, chapterTitle):
                if chapterTitle != nil,
                   (semantics?.chapterIdentity == nil || semantics?.textSegmentIdentity == nil) {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(codingPath: [], debugDescription: "Text segment is missing explicit semantic identity.")
                    )
                }
                if let range = semantics?.chapterTitleRange {
                    guard range.location >= 0,
                          range.length >= 0,
                          range.upperBound <= text.count else {
                        throw DecodingError.dataCorrupted(
                            DecodingError.Context(codingPath: [], debugDescription: "Chapter title range is outside segment text.")
                        )
                    }
                }
                for inlineStyle in semantics?.inlineTextStyles ?? [] {
                    let range = inlineStyle.range
                    guard range.location >= 0,
                          range.length >= 0,
                          range.upperBound <= text.count else {
                        throw DecodingError.dataCorrupted(
                            DecodingError.Context(codingPath: [], debugDescription: "Inline text style range is outside segment text.")
                        )
                    }
                }
                for blockStyle in semantics?.blockTextStyles ?? [] {
                    let range = blockStyle.range
                    guard range.location >= 0,
                          range.length >= 0,
                          range.upperBound <= text.count else {
                        throw DecodingError.dataCorrupted(
                            DecodingError.Context(codingPath: [], debugDescription: "Block text style range is outside segment text.")
                        )
                    }
                }

            case .image:
                if semantics?.inlineTextStyles.isEmpty == false {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(codingPath: [], debugDescription: "Image segment cannot carry inline text styles.")
                    )
                }
                if semantics?.blockTextStyles.isEmpty == false {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(codingPath: [], debugDescription: "Image segment cannot carry block text styles.")
                    )
                }
            }
        }
    }
}
