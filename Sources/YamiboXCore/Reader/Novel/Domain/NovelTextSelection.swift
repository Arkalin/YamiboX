import Foundation

package struct NovelTextSelectionAnchor: Hashable, Sendable {
    public var generation: UInt64
    public var documentOffset: NovelDocumentUTF16Offset

    public init(generation: UInt64, documentOffset: NovelDocumentUTF16Offset) {
        self.generation = generation
        self.documentOffset = max(0, documentOffset)
    }
}

package struct NovelTextSelectionRange: Hashable, Sendable {
    public var generation: UInt64
    public var lowerBound: NovelDocumentUTF16Offset
    public var upperBound: NovelDocumentUTF16Offset

    public init?(generation: UInt64, lowerBound: NovelDocumentUTF16Offset, upperBound: NovelDocumentUTF16Offset) {
        let normalizedLower = max(0, min(lowerBound, upperBound))
        let normalizedUpper = max(0, max(lowerBound, upperBound))
        guard normalizedUpper > normalizedLower else { return nil }
        self.generation = generation
        self.lowerBound = normalizedLower
        self.upperBound = normalizedUpper
    }

    public var range: Range<NovelDocumentUTF16Offset> {
        lowerBound..<upperBound
    }
}
