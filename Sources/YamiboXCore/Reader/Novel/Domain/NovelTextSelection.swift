import Foundation

package struct NovelTextSelectionAnchor: Hashable, Sendable {
    public var generation: UInt64
    public var documentOffset: Int

    public init(generation: UInt64, documentOffset: Int) {
        self.generation = generation
        self.documentOffset = max(0, documentOffset)
    }
}

package struct NovelTextSelectionRange: Hashable, Sendable {
    public var generation: UInt64
    public var lowerBound: Int
    public var upperBound: Int

    public init?(generation: UInt64, lowerBound: Int, upperBound: Int) {
        let normalizedLower = max(0, min(lowerBound, upperBound))
        let normalizedUpper = max(0, max(lowerBound, upperBound))
        guard normalizedUpper > normalizedLower else { return nil }
        self.generation = generation
        self.lowerBound = normalizedLower
        self.upperBound = normalizedUpper
    }

    public var range: Range<Int> {
        lowerBound..<upperBound
    }
}
