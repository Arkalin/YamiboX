import Foundation

struct NovelReaderParsedContent: Hashable, Sendable {
    var segments: [NovelReaderSegment]
    var segmentSources: [NovelReaderSegmentSource?]
    var segmentSemantics: [NovelReaderSegmentSemantics?]
    var retainedChapterCount: Int
    var filteredChapterCandidateCount: Int

    init(
        segments: [NovelReaderSegment] = [],
        segmentSources: [NovelReaderSegmentSource?] = [],
        segmentSemantics: [NovelReaderSegmentSemantics?] = [],
        retainedChapterCount: Int = 0,
        filteredChapterCandidateCount: Int = 0
    ) {
        self.segments = segments
        self.segmentSources = segmentSources
        self.segmentSemantics = segmentSemantics
        self.retainedChapterCount = retainedChapterCount
        self.filteredChapterCandidateCount = filteredChapterCandidateCount
    }
}

// String.count walks all grapheme boundaries, so polling it once per appended character is O(n^2).
// A single Character append changes the grapheme count by 0 (merges with the trailing cluster - can
// happen after DOM-node/style-run splitting hands us a base letter and its combining mark as two
// separate Characters) or 1 (starts a new cluster), never more, so this boundary-only check is
// equivalent to recomputing String.count but O(1) instead of O(n).
private func mergesWithPreviousGrapheme(of existing: String, appending next: Character) -> Bool {
    guard let last = existing.last else { return false }
    var probe = String(last)
    probe.append(next)
    return probe.count == 1
}

public enum NovelReaderProjectionBuilder {
    public static func build(
        from page: ForumThreadPage,
        request: NovelPageRequest,
        authorID: String,
        projectionSourceFingerprint: String = "",
        projectionSchemaVersion: Int = 0
    ) throws -> NovelReaderProjection {
        let normalizedAuthorID = authorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAuthorID.isEmpty else {
            throw YamiboError.parsingFailed(context: "小说作者范围")
        }

        let parsed = try parseContent(
            from: page,
            threadID: request.threadID,
            view: request.view
        )
        guard !parsed.segments.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("context.novel_body"))
        }

        return NovelReaderProjection(
            threadID: request.threadID,
            view: request.view,
            maxView: max(
                request.view,
                page.pageNavigation?.totalPages ?? page.pageNavigation?.currentPage ?? request.view
            ),
            resolvedAuthorID: normalizedAuthorID,
            retainedChapterCount: parsed.retainedChapterCount,
            filteredChapterCandidateCount: parsed.filteredChapterCandidateCount,
            segments: parsed.segments,
            segmentSources: parsed.segmentSources,
            segmentSemantics: parsed.segmentSemantics,
            projectionSourceFingerprint: projectionSourceFingerprint,
            projectionSchemaVersion: projectionSchemaVersion
        )
    }

    private static func parseContent(
        from page: ForumThreadPage,
        threadID: String,
        view: Int
    ) throws -> NovelReaderParsedContent {
        var result = NovelReaderParsedContent()
        var textOccurrenceByChapter: [NovelChapterIdentity: Int] = [:]
        var imageOccurrenceByChapter: [NovelChapterIdentity: Int] = [:]

        for post in page.posts {
            let projected = try projectedPost(for: post)
            guard !projected.segments.isEmpty else { continue }

            let chapterIdentity = chapterIdentity(
                ownerPostID: projected.ownerPostID,
                chapterTitle: projected.chapterTitle,
                threadID: threadID,
                view: view
            )

            result.segments.append(contentsOf: projected.segments)
            let source = NovelReaderSegmentSource(
                ownerPostID: projected.ownerPostID,
                isAuthorReplyToOther: projected.isReplyToOther
            )
            result.segmentSources.append(contentsOf: Array(repeating: source, count: projected.segments.count))
            result.segmentSemantics.append(
                contentsOf: projected.segments.indices.map { index in
                    segmentSemantics(
                        segment: projected.segments[index],
                        chapterIdentity: chapterIdentity,
                        inlineTextStyles: projected.inlineTextStyles[index],
                        blockTextStyles: projected.blockTextStyles[index],
                        textOccurrenceByChapter: &textOccurrenceByChapter,
                        imageOccurrenceByChapter: &imageOccurrenceByChapter
                    )
                }
            )
            result.retainedChapterCount += projected.chapterTitle == nil ? 0 : 1
        }

        return result
    }

    private static func projectedPost(for post: ForumThreadPost) throws -> NovelReaderProjectedPost {
        if !post.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try NovelReaderPostHTMLProjectionParser.project(post: post)
        }

        if !post.contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NovelReaderPostHTMLProjectionParser.projectPlainTextPost(post)
        }

        let blocks = try readerBlocks(for: post)
        let chapterTitle = NovelChapterTitleNormalizer.normalize(firstNonEmptyLine(in: blocks))
        let projected = NovelPostContentProjector.project(
            post: post,
            blocks: blocks,
            chapterTitle: chapterTitle
        )
        return NovelReaderProjectedPost(
            segments: projected.segments,
            inlineTextStyles: projected.inlineTextStyles,
            blockTextStyles: projected.blockTextStyles,
            chapterTitle: chapterTitle,
            ownerPostID: normalizedOwnerPostID(post.postID),
            isReplyToOther: projected.isReplyToOther
        )
    }

    private static func readerBlocks(for post: ForumThreadPost) throws -> [ForumThreadContentBlock] {
        if !post.contentBlocks.isEmpty {
            return post.contentBlocks
        }
        if !post.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let blocks = try ForumThreadHTMLBlockParser.parseBlocks(fromHTML: post.contentHTML)
            if !blocks.isEmpty {
                return blocks
            }
        }
        guard !post.contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return [
            ForumThreadContentBlock(
                id: "fallback-text",
                kind: .text(ForumThreadTextBlock(text: ForumThreadHTMLBlockParser.normalizeCommittedText(post.contentText)))
            )
        ]
    }

    private static func chapterIdentity(
        ownerPostID: String?,
        chapterTitle: String?,
        threadID: String,
        view: Int
    ) -> NovelChapterIdentity? {
        guard chapterTitle != nil else { return nil }
        if let ownerPostID, !ownerPostID.isEmpty {
            return NovelChapterIdentity(rawValue: "post:\(ownerPostID)#chapter:0")
        }
        return NovelChapterIdentity(
            rawValue: "thread:\(threadID)#view:\(max(1, view))#chapter:0"
        )
    }

    private static func segmentSemantics(
        segment: NovelReaderSegment,
        chapterIdentity: NovelChapterIdentity?,
        inlineTextStyles: [NovelInlineTextStyleRange],
        blockTextStyles: [NovelBlockTextStyleRange],
        textOccurrenceByChapter: inout [NovelChapterIdentity: Int],
        imageOccurrenceByChapter: inout [NovelChapterIdentity: Int]
    ) -> NovelReaderSegmentSemantics? {
        guard let chapterIdentity else { return nil }
        switch segment {
        case let .text(text, chapterTitle):
            let textOccurrence = textOccurrenceByChapter[chapterIdentity] ?? 0
            textOccurrenceByChapter[chapterIdentity] = textOccurrence + 1
            return NovelReaderSegmentSemantics(
                chapterIdentity: chapterIdentity,
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "\(chapterIdentity.rawValue)#text:\(textOccurrence)"),
                chapterTitleRange: chapterTitleRange(chapterTitle: chapterTitle, text: text),
                inlineTextStyles: inlineTextStyles,
                blockTextStyles: blockTextStyles
            )

        case .image:
            let occurrence = imageOccurrenceByChapter[chapterIdentity] ?? 0
            imageOccurrenceByChapter[chapterIdentity] = occurrence + 1
            return NovelReaderSegmentSemantics(
                chapterIdentity: chapterIdentity,
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "\(chapterIdentity.rawValue)#image:\(occurrence)")
            )
        }
    }

    private static func chapterTitleRange(chapterTitle: String?, text: String) -> NovelCharacterRange? {
        guard let chapterTitle = NovelChapterTitleNormalizer.normalize(chapterTitle),
              !chapterTitle.isEmpty,
              text.hasPrefix(chapterTitle) else {
            return nil
        }
        return NovelCharacterRange(location: 0, length: chapterTitle.count)
    }

    private static func firstNonEmptyLine(in blocks: [ForumThreadContentBlock]) -> String? {
        let text = NovelPostContentProjector.readableText(in: blocks, excludingDiscuzQuotes: false)
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(30)) }
    }

    fileprivate static func normalizedOwnerPostID(_ postID: String) -> String {
        let normalized = postID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "0" : normalized
    }
}

private struct NovelReaderProjectedPost {
    var segments: [NovelReaderSegment]
    var inlineTextStyles: [[NovelInlineTextStyleRange]]
    var blockTextStyles: [[NovelBlockTextStyleRange]]
    var chapterTitle: String?
    var ownerPostID: String
    var isReplyToOther: Bool
}

private enum NovelReaderPostHTMLProjectionParser {
    private struct ParsedSegment {
        var segment: NovelReaderSegment
        var inlineTextStyles: [NovelInlineTextStyleRange]
        var blockTextStyles: [NovelBlockTextStyleRange]
    }

    private struct StyledCharacter {
        var character: Character
        var isBold: Bool
        var isQuote: Bool
    }

    static func project(post: ForumThreadPost) throws -> NovelReaderProjectedPost {
        let fragment = try KannaSoup.parseBodyFragment(post.contentHTML, baseURL: YamiboDomain.baseURL.absoluteString)
        let body = fragment.body() ?? fragment
        let isReplyToOther = try isReplyToOther(in: body)
        try body.select("i").remove()

        let text = try readableText(from: body)
        let chapterTitle = chapterTitle(from: text)
        var parsedSegments = try orderedSegments(from: body, chapterTitle: chapterTitle)
        parsedSegments.append(contentsOf: missingAttachmentImageSegments(post.images, contentHTML: post.contentHTML, chapterTitle: chapterTitle))

        return NovelReaderProjectedPost(
            segments: parsedSegments.map(\.segment),
            inlineTextStyles: parsedSegments.map(\.inlineTextStyles),
            blockTextStyles: parsedSegments.map(\.blockTextStyles),
            chapterTitle: chapterTitle,
            ownerPostID: NovelReaderProjectionBuilder.normalizedOwnerPostID(post.postID),
            isReplyToOther: isReplyToOther
        )
    }

    static func projectPlainTextPost(_ post: ForumThreadPost) -> NovelReaderProjectedPost {
        let text = normalizeText(post.contentText)
        let chapterTitle = chapterTitle(from: text)
        var segments: [NovelReaderSegment] = []
        var inlineTextStyles: [[NovelInlineTextStyleRange]] = []
        var blockTextStyles: [[NovelBlockTextStyleRange]] = []
        if !text.isEmpty {
            segments.append(.text(text, chapterTitle: chapterTitle))
            inlineTextStyles.append([])
            blockTextStyles.append([])
        }
        for image in post.images where !image.url.isEmpty {
            guard let url = HTMLTextExtractor.absoluteURL(from: image.url) else { continue }
            segments.append(.image(url, chapterTitle: chapterTitle))
            inlineTextStyles.append([])
            blockTextStyles.append([])
        }
        return NovelReaderProjectedPost(
            segments: segments,
            inlineTextStyles: inlineTextStyles,
            blockTextStyles: blockTextStyles,
            chapterTitle: chapterTitle,
            ownerPostID: NovelReaderProjectionBuilder.normalizedOwnerPostID(post.postID),
            isReplyToOther: false
        )
    }

    private static func chapterTitle(from text: String) -> String? {
        NovelChapterTitleNormalizer.normalize(
            text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
                .map { String($0.prefix(30)) }
        )
    }

    private static func isReplyToOther(in body: Element) throws -> Bool {
        let quoteCandidates = try body.select(".quote, blockquote").array()
        guard quoteCandidates.contains(where: isDiscuzReplyQuote) else {
            return false
        }

        let remainingFragment = try KannaSoup.parseBodyFragment(try body.html(), baseURL: YamiboDomain.baseURL.absoluteString)
        let remainingBody = remainingFragment.body() ?? remainingFragment
        try remainingBody.select(".quote").remove()
        for blockquote in try remainingBody.select("blockquote") where isDiscuzReplyQuote(blockquote) {
            try blockquote.remove()
        }
        try remainingBody.select("i, .pstatus").remove()
        return !normalizeText(try remainingBody.text()).isEmpty
    }

    private static func isDiscuzReplyQuote(_ element: Element) -> Bool {
        if element.hasClass("quote") {
            return true
        }
        let text = normalizeText((try? element.text()) ?? "")
        return containsDiscuzQuoteHeader(text)
    }

    private static func readableText(from body: Element) throws -> String {
        var value = ""
        for child in body.getChildNodes() {
            try appendText(from: child, into: &value)
        }
        return normalizeText(value)
    }

    private static func orderedSegments(from body: Element, chapterTitle: String?) throws -> [ParsedSegment] {
        var segments: [ParsedSegment] = []
        var text: [StyledCharacter] = []

        func flushText() {
            let normalized = normalizeStyledText(text)
            guard !normalized.text.isEmpty else {
                text = []
                return
            }
            segments.append(
                ParsedSegment(
                    segment: .text(normalized.text, chapterTitle: chapterTitle),
                    inlineTextStyles: normalized.inlineTextStyles,
                    blockTextStyles: normalized.blockTextStyles
                )
            )
            text = []
        }

        func appendText(_ value: String, isBold: Bool, isQuote: Bool) {
            for character in value {
                text.append(StyledCharacter(character: character, isBold: isBold, isQuote: isQuote))
            }
        }

        func appendInlineBoundarySpace(isBold: Bool, isQuote: Bool) {
            guard let last = text.last, !last.character.isWhitespace else { return }
            text.append(StyledCharacter(character: " ", isBold: isBold, isQuote: isQuote))
        }

        func appendSegments(from node: Node, isBold: Bool, isQuote: Bool) throws {
            if let textNode = node as? TextNode {
                appendText(
                    textNode
                        .getWholeText()
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression),
                    isBold: isBold,
                    isQuote: isQuote
                )
                return
            }

            if let element = node as? Element {
                let tagName = element.tagName().lowercased()
                let nextBold = resolvedBoldState(for: element, tagName: tagName, inheritedBold: isBold)
                let nextQuote = isQuote || isQuoteBlock(element, tagName: tagName)
                if tagName == "br" {
                    appendText("\n", isBold: nextBold, isQuote: nextQuote)
                    return
                }
                if tagName == "img" {
                    guard let url = try imageURL(from: element) else { return }
                    flushText()
                    segments.append(
                        ParsedSegment(
                            segment: .image(url, chapterTitle: chapterTitle),
                            inlineTextStyles: [],
                            blockTextStyles: []
                        )
                    )
                    return
                }
                if tagName == "li" {
                    appendText("• ", isBold: nextBold, isQuote: nextQuote)
                }
                let usesInlineBoundarySpacing = inlineBoundarySpacingTags.contains(tagName)
                if usesInlineBoundarySpacing {
                    appendInlineBoundarySpace(isBold: isBold, isQuote: isQuote)
                }

                for child in element.getChildNodes() {
                    try appendSegments(from: child, isBold: nextBold, isQuote: nextQuote)
                }
                if usesInlineBoundarySpacing {
                    appendInlineBoundarySpace(isBold: isBold, isQuote: isQuote)
                }

                if blockBreakTags.contains(tagName) {
                    appendText("\n", isBold: nextBold, isQuote: false)
                }
                return
            }

            for child in node.getChildNodes() {
                try appendSegments(from: child, isBold: isBold, isQuote: isQuote)
            }
        }

        for child in body.getChildNodes() {
            try appendSegments(from: child, isBold: false, isQuote: false)
        }
        flushText()

        return segments
    }

    private static func appendText(from node: Node, into value: inout String) throws {
        if let textNode = node as? TextNode {
            value += textNode
                .getWholeText()
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return
        }

        if let element = node as? Element {
            let tagName = element.tagName().lowercased()
            if tagName == "br" {
                value += "\n"
                return
            }
            if tagName == "li" {
                value += "• "
            }

            for child in element.getChildNodes() {
                try appendText(from: child, into: &value)
            }

            if blockBreakTags.contains(tagName) {
                value += "\n"
            }
            return
        }

        for child in node.getChildNodes() {
            try appendText(from: child, into: &value)
        }
    }

    private static func resolvedBoldState(
        for element: Element,
        tagName: String,
        inheritedBold: Bool
    ) -> Bool {
        var isBold = inheritedBold
        if tagName == "b" || tagName == "strong" {
            isBold = true
        }
        if let styleBold = inlineFontWeightBoldState(for: element) {
            isBold = styleBold
        }
        return isBold
    }

    private static func isQuoteBlock(_ element: Element, tagName: String) -> Bool {
        tagName == "blockquote" || element.hasClass("quote")
    }

    private static func inlineFontWeightBoldState(for element: Element) -> Bool? {
        let style = (try? element.attr("style"))?.lowercased() ?? ""
        guard !style.isEmpty else { return nil }

        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, parts[0] == "font-weight" else { continue }
            let value = parts[1]
                .replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "bold" || value == "bolder" {
                return true
            }
            if value == "normal" || value == "lighter" {
                return false
            }
            let numericPrefix = value.prefix { $0.isNumber }
            if let weight = Int(numericPrefix) {
                return weight >= 600
            }
        }
        return nil
    }

    private static func normalizeStyledText(
        _ text: [StyledCharacter]
    ) -> (
        text: String,
        inlineTextStyles: [NovelInlineTextStyleRange],
        blockTextStyles: [NovelBlockTextStyleRange]
    ) {
        let normalizedLineBreaks = normalizeStyledLineBreaks(text)
        var lines: [[StyledCharacter]] = [[]]
        var lineBreaks: [StyledCharacter] = []
        for character in normalizedLineBreaks {
            if character.character == "\n" {
                lineBreaks.append(character)
                lines.append([])
            } else {
                lines[lines.count - 1].append(character)
            }
        }

        var normalized: [StyledCharacter] = []
        for (index, line) in lines.enumerated() {
            if index > 0 {
                let lineBreak = lineBreaks[index - 1]
                normalized.append(
                    StyledCharacter(
                        character: "\n",
                        isBold: false,
                        isQuote: lineBreak.isQuote
                    )
                )
            }
            normalized.append(contentsOf: normalizeStyledLine(line))
        }

        normalized = collapseExcessNewlines(in: normalized)
        normalized = trimStyledWhitespaceAndNewlines(normalized)

        var output = ""
        var outputCount = 0
        var inlineTextStyles: [NovelInlineTextStyleRange] = []
        var blockTextStyles: [NovelBlockTextStyleRange] = []
        var boldStart: Int?
        var quoteStart: Int?
        for character in normalized {
            let location = outputCount
            if character.isBold {
                if boldStart == nil {
                    boldStart = location
                }
            } else if let start = boldStart {
                if location > start {
                    inlineTextStyles.append(
                        NovelInlineTextStyleRange(
                            style: .bold,
                            range: NovelCharacterRange(location: start, length: location - start)
                        )
                    )
                }
                boldStart = nil
            }
            if character.isQuote {
                if quoteStart == nil {
                    quoteStart = location
                }
            } else if let start = quoteStart {
                if location > start {
                    blockTextStyles.append(
                        NovelBlockTextStyleRange(
                            style: .quote,
                            range: NovelCharacterRange(location: start, length: location - start)
                        )
                    )
                }
                quoteStart = nil
            }
            if !mergesWithPreviousGrapheme(of: output, appending: character.character) {
                outputCount += 1
            }
            output.append(character.character)
        }
        if let start = boldStart, outputCount > start {
            inlineTextStyles.append(
                NovelInlineTextStyleRange(
                    style: .bold,
                    range: NovelCharacterRange(location: start, length: outputCount - start)
                )
            )
        }
        if let start = quoteStart, outputCount > start {
            blockTextStyles.append(
                NovelBlockTextStyleRange(
                    style: .quote,
                    range: NovelCharacterRange(location: start, length: outputCount - start)
                )
            )
        }
        return (output, inlineTextStyles, blockTextStyles)
    }

    private static func normalizeStyledLineBreaks(_ text: [StyledCharacter]) -> [StyledCharacter] {
        var result: [StyledCharacter] = []
        var index = 0
        while index < text.count {
            let character = text[index]
            if character.character == "\r" {
                result.append(
                    StyledCharacter(
                        character: "\n",
                        isBold: character.isBold,
                        isQuote: character.isQuote
                    )
                )
                if index + 1 < text.count, text[index + 1].character == "\n" {
                    index += 1
                }
            } else if character.character == "\u{00A0}" {
                result.append(
                    StyledCharacter(
                        character: " ",
                        isBold: character.isBold,
                        isQuote: character.isQuote
                    )
                )
            } else {
                result.append(character)
            }
            index += 1
        }
        return result
    }

    private static func normalizeStyledLine(_ line: [StyledCharacter]) -> [StyledCharacter] {
        var result: [StyledCharacter] = []
        var pendingWhitespaceIsBold = false
        var pendingWhitespaceIsQuote = false
        var hasPendingWhitespace = false

        for character in line {
            if character.character == " " || character.character == "\t" {
                hasPendingWhitespace = true
                pendingWhitespaceIsBold = pendingWhitespaceIsBold || character.isBold
                pendingWhitespaceIsQuote = pendingWhitespaceIsQuote || character.isQuote
                continue
            }
            if hasPendingWhitespace, !result.isEmpty {
                result.append(
                    StyledCharacter(
                        character: " ",
                        isBold: pendingWhitespaceIsBold,
                        isQuote: pendingWhitespaceIsQuote
                    )
                )
            }
            hasPendingWhitespace = false
            pendingWhitespaceIsBold = false
            pendingWhitespaceIsQuote = false
            result.append(character)
        }

        return result
    }

    private static func collapseExcessNewlines(in text: [StyledCharacter]) -> [StyledCharacter] {
        var result: [StyledCharacter] = []
        var newlineCount = 0
        for character in text {
            if character.character == "\n" {
                newlineCount += 1
                if newlineCount <= 2 {
                    result.append(
                        StyledCharacter(
                            character: "\n",
                            isBold: false,
                            isQuote: character.isQuote
                        )
                    )
                }
            } else {
                newlineCount = 0
                result.append(character)
            }
        }
        return result
    }

    private static func trimStyledWhitespaceAndNewlines(_ text: [StyledCharacter]) -> [StyledCharacter] {
        var start = text.startIndex
        var end = text.endIndex
        while start < end, isTrimmable(text[start].character) {
            start += 1
        }
        while end > start, isTrimmable(text[text.index(before: end)].character) {
            end -= 1
        }
        return Array(text[start ..< end])
    }

    private static func imageURL(from image: Element) throws -> URL? {
        YamiboImageReferenceExtractor.novelInline.url(from: image)
    }

    private static func missingAttachmentImageSegments(
        _ images: [ForumThreadPostImage],
        contentHTML: String,
        chapterTitle: String?
    ) -> [ParsedSegment] {
        images.compactMap { image in
            guard !image.url.isEmpty,
                  !contentHTML.contains(image.url),
                  let url = HTMLTextExtractor.absoluteURL(from: image.url) else {
                return nil
            }
            return ParsedSegment(
                segment: .image(url, chapterTitle: chapterTitle),
                inlineTextStyles: [],
                blockTextStyles: []
            )
        }
    }

    private static func normalizeText(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        value = value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map {
                $0.replacingOccurrences(
                    of: #"[ \t]+"#,
                    with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")

        value = value.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsDiscuzQuoteHeader(_ text: String) -> Bool {
        let markers = ["发表于", "發表於", "發表于", "发表於"]
        return markers.contains { text.contains($0) }
    }

    private static func isTrimmable(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r"
    }

    private static let blockBreakTags: Set<String> = [
        "div",
        "p",
        "li",
        "tr",
        "dd",
        "blockquote"
    ]

    private static let inlineBoundarySpacingTags: Set<String> = [
        "b",
        "strong",
        "span",
        "font"
    ]
}

private enum NovelPostContentProjector {
    fileprivate struct ProjectedPost {
        var segments: [NovelReaderSegment] = []
        var inlineTextStyles: [[NovelInlineTextStyleRange]] = []
        var blockTextStyles: [[NovelBlockTextStyleRange]] = []
        var isReplyToOther = false
    }

    private struct TextBuffer {
        var text = ""
        var textCount = 0
        var inlineTextStyles: [NovelInlineTextStyleRange] = []
        var blockTextStyles: [NovelBlockTextStyleRange] = []

        var isEmpty: Bool {
            text.isEmpty
        }

        mutating func append(_ value: String, inlineStyles: [NovelInlineTextStyleRange], isQuote: Bool) {
            guard !value.isEmpty else { return }
            let start = textCount
            let mergesAtBoundary = value.first.map { mergesWithPreviousGrapheme(of: text, appending: $0) } ?? false
            text += value
            textCount = start + value.count - (mergesAtBoundary ? 1 : 0)
            inlineTextStyles.append(
                contentsOf: inlineStyles.map { style in
                    NovelInlineTextStyleRange(
                        style: style.style,
                        range: NovelCharacterRange(
                            location: start + style.range.location,
                            length: style.range.length
                        )
                    )
                }
            )
            if isQuote {
                blockTextStyles.append(
                    NovelBlockTextStyleRange(
                        style: .quote,
                        range: NovelCharacterRange(location: start, length: value.count)
                    )
                )
            }
        }

        mutating func appendPlain(_ value: String, isQuote: Bool) {
            append(value, inlineStyles: [], isQuote: isQuote)
        }

        mutating func ensureLineBreak(isQuote: Bool) {
            guard !text.isEmpty, text.last != "\n" else { return }
            appendPlain("\n", isQuote: isQuote)
        }

        mutating func normalizeAndDrain() -> (text: String, inlineTextStyles: [NovelInlineTextStyleRange], blockTextStyles: [NovelBlockTextStyleRange])? {
            let characters = Array(text)
            let start = characters.firstIndex { !isTrimmable($0) } ?? characters.count
            let end = characters.lastIndex { !isTrimmable($0) }.map { $0 + 1 } ?? start
            guard start < end else {
                text = ""
                textCount = 0
                inlineTextStyles = []
                blockTextStyles = []
                return nil
            }
            let trimmed = String(characters[start ..< end])
            let maxLength = trimmed.count
            let inline = inlineTextStyles.compactMap { adjustedRange($0, trimStart: start, maxLength: maxLength) }
            let block = blockTextStyles.compactMap { adjustedRange($0, trimStart: start, maxLength: maxLength) }
            text = ""
            textCount = 0
            inlineTextStyles = []
            blockTextStyles = []
            return (trimmed, inline, block)
        }

        private func adjustedRange(
            _ style: NovelInlineTextStyleRange,
            trimStart: Int,
            maxLength: Int
        ) -> NovelInlineTextStyleRange? {
            let start = max(style.range.location - trimStart, 0)
            let end = min(style.range.upperBound - trimStart, maxLength)
            guard end > start else { return nil }
            return NovelInlineTextStyleRange(
                style: style.style,
                range: NovelCharacterRange(location: start, length: end - start)
            )
        }

        private func adjustedRange(
            _ style: NovelBlockTextStyleRange,
            trimStart: Int,
            maxLength: Int
        ) -> NovelBlockTextStyleRange? {
            let start = max(style.range.location - trimStart, 0)
            let end = min(style.range.upperBound - trimStart, maxLength)
            guard end > start else { return nil }
            return NovelBlockTextStyleRange(
                style: style.style,
                range: NovelCharacterRange(location: start, length: end - start)
            )
        }

        private func isTrimmable(_ character: Character) -> Bool {
            character == " " || character == "\t" || character == "\n" || character == "\r"
        }
    }

    static func project(
        post: ForumThreadPost,
        blocks: [ForumThreadContentBlock],
        chapterTitle: String?
    ) -> ProjectedPost {
        var projected = ProjectedPost()
        var buffer = TextBuffer()
        var emittedImageURLs = Set<String>()
        append(blocks, to: &projected, buffer: &buffer, chapterTitle: chapterTitle, isQuote: false, emittedImageURLs: &emittedImageURLs)
        flush(&buffer, into: &projected, chapterTitle: chapterTitle)
        appendMissingAttachmentImages(
            post.images,
            contentHTML: post.contentHTML,
            to: &projected,
            chapterTitle: chapterTitle,
            emittedImageURLs: &emittedImageURLs
        )
        projected.isReplyToOther = isReplyToOther(blocks)
        return projected
    }

    fileprivate static func readableText(
        in blocks: [ForumThreadContentBlock],
        excludingDiscuzQuotes: Bool
    ) -> String {
        let text = blocks.flatMap { readableTextFragments(in: $0, excludingDiscuzQuotes: excludingDiscuzQuotes) }
            .joined(separator: "\n")
        return ForumThreadHTMLBlockParser.normalizeCommittedText(text)
    }

    private static func append(
        _ blocks: [ForumThreadContentBlock],
        to projected: inout ProjectedPost,
        buffer: inout TextBuffer,
        chapterTitle: String?,
        isQuote: Bool,
        emittedImageURLs: inout Set<String>
    ) {
        for block in blocks {
            append(
                block,
                to: &projected,
                buffer: &buffer,
                chapterTitle: chapterTitle,
                isQuote: isQuote,
                emittedImageURLs: &emittedImageURLs
            )
        }
    }

    private static func append(
        _ block: ForumThreadContentBlock,
        to projected: inout ProjectedPost,
        buffer: inout TextBuffer,
        chapterTitle: String?,
        isQuote: Bool,
        emittedImageURLs: inout Set<String>
    ) {
        switch block.kind {
        case let .text(textBlock):
            buffer.append(
                textBlock.text,
                inlineStyles: boldRanges(in: textBlock),
                isQuote: isQuote
            )

        case let .image(image):
            guard !image.isEmoticon else { return }
            flush(&buffer, into: &projected, chapterTitle: chapterTitle)
            appendImage(image.url, to: &projected, chapterTitle: chapterTitle, emittedImageURLs: &emittedImageURLs)

        case let .attachment(attachment):
            buffer.appendPlain(attachment.fileName, isQuote: isQuote)

        case let .quote(blocks):
            buffer.ensureLineBreak(isQuote: isQuote)
            append(blocks, to: &projected, buffer: &buffer, chapterTitle: chapterTitle, isQuote: true, emittedImageURLs: &emittedImageURLs)
            buffer.ensureLineBreak(isQuote: isQuote)

        case let .code(text):
            buffer.appendPlain(text, isQuote: isQuote)

        case .horizontalRule:
            break

        case let .collapse(title, contentBlocks):
            if let title {
                buffer.ensureLineBreak(isQuote: isQuote)
                buffer.appendPlain(title, isQuote: isQuote)
                buffer.ensureLineBreak(isQuote: isQuote)
            }
            append(contentBlocks, to: &projected, buffer: &buffer, chapterTitle: chapterTitle, isQuote: isQuote, emittedImageURLs: &emittedImageURLs)

        case let .locked(_, contentBlocks):
            append(contentBlocks, to: &projected, buffer: &buffer, chapterTitle: chapterTitle, isQuote: isQuote, emittedImageURLs: &emittedImageURLs)

        case let .table(rows):
            let text = rows.map { row in
                row.map { cell in readableText(in: cell.blocks, excludingDiscuzQuotes: false) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            buffer.ensureLineBreak(isQuote: isQuote)
            buffer.appendPlain(text, isQuote: isQuote)
            buffer.ensureLineBreak(isQuote: isQuote)
        }
    }

    private static func flush(
        _ buffer: inout TextBuffer,
        into projected: inout ProjectedPost,
        chapterTitle: String?
    ) {
        guard let normalized = buffer.normalizeAndDrain() else { return }
        projected.segments.append(.text(normalized.text, chapterTitle: chapterTitle))
        projected.inlineTextStyles.append(normalized.inlineTextStyles)
        projected.blockTextStyles.append(normalized.blockTextStyles)
    }

    private static func appendImage(
        _ url: URL,
        to projected: inout ProjectedPost,
        chapterTitle: String?,
        emittedImageURLs: inout Set<String>
    ) {
        guard !YamiboImageReferenceExtractor.isEmoticonURL(url),
              emittedImageURLs.insert(url.absoluteString).inserted else {
            return
        }
        projected.segments.append(.image(url, chapterTitle: chapterTitle))
        projected.inlineTextStyles.append([])
        projected.blockTextStyles.append([])
    }

    private static func appendMissingAttachmentImages(
        _ images: [ForumThreadPostImage],
        contentHTML: String,
        to projected: inout ProjectedPost,
        chapterTitle: String?,
        emittedImageURLs: inout Set<String>
    ) {
        for image in images {
            guard !contentHTML.contains(image.url) else { continue }
            guard let url = HTMLTextExtractor.absoluteURL(from: image.url) else { continue }
            appendImage(url, to: &projected, chapterTitle: chapterTitle, emittedImageURLs: &emittedImageURLs)
        }
    }

    private static func boldRanges(in textBlock: ForumThreadTextBlock) -> [NovelInlineTextStyleRange] {
        textBlock.styleRuns.compactMap { run in
            guard run.style.isBold, run.length > 0 else { return nil }
            return NovelInlineTextStyleRange(
                style: .bold,
                range: NovelCharacterRange(location: run.start, length: run.length)
            )
        }
    }

    private static func isReplyToOther(_ blocks: [ForumThreadContentBlock]) -> Bool {
        guard blocks.contains(where: containsDiscuzReplyQuote) else { return false }
        return !readableText(in: blocks, excludingDiscuzQuotes: true).isEmpty
    }

    private static func containsDiscuzReplyQuote(_ block: ForumThreadContentBlock) -> Bool {
        switch block.kind {
        case let .quote(blocks):
            return containsDiscuzQuoteHeader(readableText(in: blocks, excludingDiscuzQuotes: false))
                || blocks.contains(where: containsDiscuzReplyQuote)
        case let .collapse(_, blocks), let .locked(_, blocks):
            return blocks.contains(where: containsDiscuzReplyQuote)
        case let .table(rows):
            return rows.flatMap { $0 }.contains { $0.blocks.contains(where: containsDiscuzReplyQuote) }
        default:
            return false
        }
    }

    private static func readableTextFragments(
        in block: ForumThreadContentBlock,
        excludingDiscuzQuotes: Bool
    ) -> [String] {
        switch block.kind {
        case let .text(text):
            return [text.text]
        case let .attachment(attachment):
            return [attachment.fileName]
        case let .quote(blocks):
            if excludingDiscuzQuotes,
               containsDiscuzQuoteHeader(readableText(in: blocks, excludingDiscuzQuotes: false)) {
                return []
            }
            return blocks.flatMap { readableTextFragments(in: $0, excludingDiscuzQuotes: excludingDiscuzQuotes) }
        case let .code(text):
            return [text]
        case let .collapse(title, blocks):
            return [title].compactMap { $0 }
                + blocks.flatMap { readableTextFragments(in: $0, excludingDiscuzQuotes: excludingDiscuzQuotes) }
        case let .locked(_, blocks):
            return blocks.flatMap { readableTextFragments(in: $0, excludingDiscuzQuotes: excludingDiscuzQuotes) }
        case let .table(rows):
            return rows.flatMap { row in
                row.flatMap { cell in
                    cell.blocks.flatMap { readableTextFragments(in: $0, excludingDiscuzQuotes: excludingDiscuzQuotes) }
                }
            }
        case .image, .horizontalRule:
            return []
        }
    }

    private static func containsDiscuzQuoteHeader(_ text: String) -> Bool {
        let markers = ["发表于", "發表於", "發表于", "发表於"]
        return markers.contains { text.contains($0) }
    }
}
