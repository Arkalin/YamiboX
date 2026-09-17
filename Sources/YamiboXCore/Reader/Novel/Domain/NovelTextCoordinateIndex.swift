import Foundation

/// The two coordinate spaces deliberately cannot be implicitly interchanged.
package protocol NovelUTF16Position: RawRepresentable, Hashable, Sendable, Comparable,
    Strideable, ExpressibleByIntegerLiteral where RawValue == Int, Stride == Int, IntegerLiteralType == Int {
    init(_ rawValue: Int)
}

package extension NovelUTF16Position {
    init(integerLiteral value: Int) { self.init(value) }
    init(rawValue: Int) { self.init(rawValue) }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    func distance(to other: Self) -> Int { other.rawValue - rawValue }
    func advanced(by n: Int) -> Self { Self(rawValue + n) }
    static func + (lhs: Self, rhs: Int) -> Self { lhs.advanced(by: rhs) }
    static func - (lhs: Self, rhs: Int) -> Self { lhs.advanced(by: -rhs) }
    static func - (lhs: Self, rhs: Self) -> Int { rhs.distance(to: lhs) }
}

package struct NovelDocumentUTF16Offset: NovelUTF16Position {
    package let rawValue: Int
    package init(_ rawValue: Int) { self.rawValue = rawValue }
}

package struct NovelSegmentUTF16Offset: NovelUTF16Position {
    package let rawValue: Int
    package init(_ rawValue: Int) { self.rawValue = rawValue }
}

/// One immutable index per text value, shared by all of its rendered ranges.
/// Character ordinals are a legacy storage/user-counting boundary, not a layout coordinate.
package final class NovelTextCoordinateIndex: Sendable {
    package let utf16: [UInt16]
    package let characterBoundaries: [Int]

    package init(_ text: String) {
        utf16 = Array(text.utf16)
        var boundaries = [0]
        boundaries.reserveCapacity(utf16.count + 1)
        var offset = 0
        for character in text {
            offset += character.utf16.count
            boundaries.append(offset)
        }
        characterBoundaries = boundaries
    }

    package var characterCount: Int { characterBoundaries.count - 1 }
    package var utf16Count: Int { utf16.count }

    package func utf16Offset(forCharacterOffset offset: Int) -> Int {
        characterBoundaries[min(max(offset, 0), characterCount)]
    }

    package func characterOffset(forUTF16Offset offset: Int, roundingUp: Bool = false) -> Int {
        let offset = min(max(offset, 0), utf16Count)
        var low = 0
        var high = characterBoundaries.count
        while low < high {
            let mid = (low + high) / 2
            if characterBoundaries[mid] < offset { low = mid + 1 } else { high = mid }
        }
        if roundingUp || characterBoundaries[low] == offset { return low }
        return max(low - 1, 0)
    }

    package func alignedOffset(_ offset: Int, roundingUp: Bool = false) -> Int {
        utf16Offset(forCharacterOffset: characterOffset(forUTF16Offset: offset, roundingUp: roundingUp))
    }

    package func alignedRange(_ range: Range<Int>) -> Range<Int> {
        let start = alignedOffset(range.lowerBound)
        return start..<(range.isEmpty ? start : alignedOffset(range.upperBound, roundingUp: true))
    }

    package func utf16Range(forCharacterRange range: NovelCharacterRange) -> NSRange? {
        guard range.location >= 0, range.length >= 0,
              range.location <= characterCount, range.length <= characterCount - range.location else { return nil }
        let start = utf16Offset(forCharacterOffset: range.location)
        let end = utf16Offset(forCharacterOffset: range.location + range.length)
        return NSRange(location: start, length: end - start)
    }

    package func text(in range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= utf16Count else { return nil }
        return String(decoding: utf16[range], as: UTF16.self)
    }

    package func character(at ordinal: Int) -> Character? {
        guard ordinal >= 0, ordinal < characterCount,
              let text = text(in: characterBoundaries[ordinal]..<characterBoundaries[ordinal + 1]) else { return nil }
        return text.first
    }
}

/// Runtime styles are UTF-16; source projection styles remain Character-based Codable values.
package struct NovelRuntimeTextSemantics: Sendable {
    package var chapterIdentity: NovelChapterIdentity?
    package var textSegmentIdentity: NovelTextSegmentIdentity?
    package var chapterTitleRange: NSRange?
    package var inlineTextStyles: [NovelRuntimeInlineTextStyle]
    package var blockTextStyles: [NovelRuntimeBlockTextStyle]
}

package struct NovelRuntimeInlineTextStyle: Hashable, Sendable {
    package var style: NovelInlineTextStyle
    package var range: NSRange
}

package struct NovelRuntimeBlockTextStyle: Hashable, Sendable {
    package var style: NovelBlockTextStyle
    package var range: NSRange
}

/// A segment's extent in the composed document (not a range inside the segment).
package struct NovelDocumentTextRange: Hashable, Sendable {
    package var segmentIndex: Int
    package var startOffset: NovelDocumentUTF16Offset
    package var endOffset: NovelDocumentUTF16Offset
    package var length: Int { endOffset - startOffset }
}
