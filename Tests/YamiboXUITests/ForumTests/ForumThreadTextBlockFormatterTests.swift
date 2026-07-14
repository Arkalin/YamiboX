import Foundation
import SwiftUI
import Testing
import UIKit
@testable import YamiboXCore
@testable import YamiboXUI

/// Styled runs scale their 17pt base through the body text style's metrics
/// (Dynamic Type); at the test host's default content size this resolves to
/// exactly 17, but the expectation mirrors the production computation so the
/// tests stay valid under any category.
private var expectedBaseBodyFontSize: CGFloat {
    UIFontMetrics(forTextStyle: .body).scaledValue(for: 17)
}

@Test func textBlockFormatterAppliesStyleRunsToCharacterRanges() throws {
    let block = ForumThreadTextBlock(
        text: "abcdef",
        styleRuns: [
            ForumThreadTextStyleRun(
                start: 1,
                length: 2,
                style: ForumThreadTextStyle(isBold: true, foregroundHex: "#FF0000")
            ),
            ForumThreadTextStyleRun(
                start: 4,
                length: 10,
                style: ForumThreadTextStyle(isUnderline: true, isStrikethrough: true)
            )
        ]
    )

    let attributed = ForumThreadTextBlockFormatter(block: block).attributedText

    #expect(String(attributed.characters) == "abcdef")
    let boldRange = try #require(attributed.range(of: "bc"))
    #expect(attributed[boldRange].runs.allSatisfy { $0.font == Font.system(size: expectedBaseBodyFontSize).bold() })
    #expect(attributed[boldRange].runs.allSatisfy { $0.foregroundColor == Color(red: 1, green: 0, blue: 0) })

    // The second run is clamped to the end of the text.
    let decoratedRange = try #require(attributed.range(of: "ef"))
    #expect(attributed[decoratedRange].runs.allSatisfy { $0.underlineStyle == .single })
    #expect(attributed[decoratedRange].runs.allSatisfy { $0.strikethroughStyle == .single })

    let plainRange = try #require(attributed.range(of: "a"))
    #expect(attributed[plainRange].runs.allSatisfy { $0.font == nil })
}

@Test func textBlockFormatterIgnoresOutOfRangeRunsAndLinks() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/thread-1-1-1.html"))
    let block = ForumThreadTextBlock(
        text: "abc",
        links: [ForumThreadTextLink(start: 3, length: 2, url: url)],
        styleRuns: [
            ForumThreadTextStyleRun(start: -1, length: 2, style: ForumThreadTextStyle(isBold: true)),
            ForumThreadTextStyleRun(start: 5, length: 1, style: ForumThreadTextStyle(isBold: true)),
            ForumThreadTextStyleRun(start: 1, length: 0, style: ForumThreadTextStyle(isBold: true))
        ]
    )

    let attributed = ForumThreadTextBlockFormatter(block: block).attributedText

    #expect(attributed.runs.allSatisfy { $0.font == nil })
    #expect(attributed.runs.allSatisfy { $0.link == nil })
}

@Test func textBlockFormatterAppliesLinkStyleOverStyleRuns() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/thread-2-1-1.html"))
    let block = ForumThreadTextBlock(
        text: "tap here",
        links: [ForumThreadTextLink(start: 4, length: 4, url: url)],
        styleRuns: [
            ForumThreadTextStyleRun(start: 4, length: 4, style: ForumThreadTextStyle(foregroundHex: "00FF00"))
        ]
    )

    let attributed = ForumThreadTextBlockFormatter(block: block).attributedText

    let linkRange = try #require(attributed.range(of: "here"))
    #expect(attributed[linkRange].runs.allSatisfy { $0.link == url })
    #expect(attributed[linkRange].runs.allSatisfy { $0.foregroundColor == ForumColors.brownPrimary })
    #expect(attributed[linkRange].runs.allSatisfy { $0.underlineStyle == .single })
}

@Test func textBlockFormatterSplitsRubySegmentsAndKeepsStyles() {
    let block = ForumThreadTextBlock(
        text: "前漢字後",
        styleRuns: [
            ForumThreadTextStyleRun(start: 1, length: 2, style: ForumThreadTextStyle(isBold: true))
        ],
        rubies: [
            ForumThreadRubyText(start: 1, length: 2, baseText: "漢字", rubyText: "かんじ")
        ]
    )

    let segments = ForumThreadTextBlockFormatter(block: block).rubySegments

    #expect(segments.map { String($0.attributedText.characters) } == ["前", "漢字", "後"])
    #expect(segments.map(\.rubyText) == [nil, "かんじ", nil])
    let rubySegment = segments[1]
    #expect(rubySegment.attributedText.runs.allSatisfy { $0.font == Font.system(size: expectedBaseBodyFontSize).bold() })
}

@Test func textBlockFormatterDropsInvalidAndOverlappingRubies() {
    let block = ForumThreadTextBlock(
        text: "一二三四",
        rubies: [
            ForumThreadRubyText(start: 0, length: 2, baseText: "一二", rubyText: "首"),
            ForumThreadRubyText(start: 1, length: 2, baseText: "二三", rubyText: "重叠"),
            ForumThreadRubyText(start: 3, length: 5, baseText: "四", rubyText: "越界"),
            ForumThreadRubyText(start: -1, length: 1, baseText: "一", rubyText: "负")
        ]
    )

    let segments = ForumThreadTextBlockFormatter(block: block).rubySegments

    #expect(segments.map { String($0.attributedText.characters) } == ["一二", "三四"])
    #expect(segments.map(\.rubyText) == ["首", nil])
}
