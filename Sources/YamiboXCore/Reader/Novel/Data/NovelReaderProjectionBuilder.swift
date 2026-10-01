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
            throw YamiboError.parsingFailed(context: L10n.string("parsing_context.novel_author_scope"))
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
            if projected.chapterTitle != nil {
                if projected.isReplyToOther { result.filteredChapterCandidateCount += 1 }
                else { result.retainedChapterCount += 1 }
            }
        }

        return result
    }

    private static func projectedPost(for post: ForumThreadPost) throws -> NovelReaderProjectedPost {
        if !post.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try NovelReaderPostHTMLProjectionParser.project(post: post)
        }

        if post.contentBlocks.isEmpty, !post.contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        guard let chapterIdentity else {
            if case .text = segment {
                return NovelReaderSegmentSemantics(
                    inlineTextStyles: inlineTextStyles,
                    blockTextStyles: blockTextStyles
                )
            }
            return nil
        }
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
        var format: InlineFormat
        var isQuote: Bool
        var ruby: RubyMarker?
    }

    private struct InlineFormat: Equatable {
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
        var foregroundHex: String?
        var backgroundHex: String?
    }

    private struct RubyMarker: Equatable {
        var id: Int
        var text: String
    }

    private struct ActiveInline: Equatable {
        var colorHex: String?
        var ruby: RubyMarker?
    }

    static func project(post: ForumThreadPost) throws -> NovelReaderProjectedPost {
        let fragment = try KannaSoup.parseBodyFragment(post.contentHTML, baseURL: YamiboDomain.baseURL.absoluteString)
        let body = fragment.body() ?? fragment
        let isReplyToOther = ForumPostReplyReferenceParser.parse(in: body) != nil
        body.select("i.pstatus").remove()
        let attachmentImageURLs = NovelReaderAttachmentFilter.removeFileAttachments(from: body)

        let text = readableText(from: body)
        let chapterTitle = chapterTitle(from: text)
        var parsedSegments = orderedSegments(from: body, chapterTitle: chapterTitle)
        parsedSegments.append(contentsOf: missingAttachmentImageSegments(
            post.images,
            contentHTML: post.contentHTML,
            excluding: attachmentImageURLs,
            chapterTitle: chapterTitle
        ))

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
            guard let url = HTMLTextExtractor.absoluteURL(from: image.url),
                  !NovelReaderAttachmentFilter.isFileIcon(url) else { continue }
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

    private static func readableText(from body: Element) -> String {
        var value = ""
        for child in body.getChildNodes() {
            appendText(from: child, into: &value)
        }
        return normalizeText(value)
    }

    private static func orderedSegments(from body: Element, chapterTitle: String?) -> [ParsedSegment] {
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

        func appendText(_ value: String, format: InlineFormat, isQuote: Bool, ruby: RubyMarker?) {
            for character in value {
                text.append(StyledCharacter(character: character, format: format, isQuote: isQuote, ruby: ruby))
            }
        }

        var nextRubyID = 0
        func appendSegments(from node: Node, format: InlineFormat, isQuote: Bool, ruby: RubyMarker?) {
            if let textNode = node as? TextNode {
                appendText(
                    textNode
                        .getWholeText()
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression),
                    format: format,
                    isQuote: isQuote,
                    ruby: ruby
                )
                return
            }

            if let element = node as? Element {
                let tagName = element.tagName().lowercased()
                if tagName == "rt" || tagName == "rp" { return }
                let nextFormat = resolvedFormat(for: element, tagName: tagName, inherited: format)
                let nextQuote = isQuote || isQuoteBlock(element, tagName: tagName)
                if tagName == "ruby" {
                    // Each direct rt labels the base nodes immediately before it.
                    // One marker for the entire ruby element would misalign paired
                    // rb/rt groups such as 漢/かん and 字/じ.
                    var baseNodes: [Node] = []
                    for child in element.getChildNodes() {
                        let childTag = (child as? Element)?.tagName().lowercased()
                        if childTag == "rp" { continue }
                        if childTag == "rt" {
                            let annotation = (child as? Element)?.text()
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            let marker: RubyMarker?
                            if annotation.isEmpty {
                                marker = ruby
                            } else {
                                nextRubyID += 1
                                marker = RubyMarker(id: nextRubyID, text: annotation)
                            }
                            for base in baseNodes {
                                appendSegments(from: base, format: nextFormat, isQuote: nextQuote, ruby: marker)
                            }
                            baseNodes.removeAll(keepingCapacity: true)
                        } else {
                            baseNodes.append(child)
                        }
                    }
                    for base in baseNodes {
                        appendSegments(from: base, format: nextFormat, isQuote: nextQuote, ruby: ruby)
                    }
                    return
                }
                let nextRuby = ruby
                if tagName == "br" {
                    appendText("\n", format: nextFormat, isQuote: nextQuote, ruby: nextRuby)
                    return
                }
                if tagName == "img" {
                    guard let url = imageURL(from: element) else { return }
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
                    appendText("• ", format: nextFormat, isQuote: nextQuote, ruby: nextRuby)
                }

                for child in element.getChildNodes() {
                    appendSegments(from: child, format: nextFormat, isQuote: nextQuote, ruby: nextRuby)
                }

                if blockBreakTags.contains(tagName) {
                    appendText("\n", format: .init(), isQuote: false, ruby: nil)
                }
                return
            }

            for child in node.getChildNodes() {
                appendSegments(from: child, format: format, isQuote: isQuote, ruby: ruby)
            }
        }

        for child in body.getChildNodes() {
            appendSegments(from: child, format: .init(), isQuote: false, ruby: nil)
        }
        flushText()

        return segments
    }

    private static func appendText(from node: Node, into value: inout String) {
        if let textNode = node as? TextNode {
            value += textNode
                .getWholeText()
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return
        }

        if let element = node as? Element {
            let tagName = element.tagName().lowercased()
            if tagName == "rt" || tagName == "rp" { return }
            if tagName == "br" {
                value += "\n"
                return
            }
            if tagName == "li" {
                value += "• "
            }

            for child in element.getChildNodes() {
                appendText(from: child, into: &value)
            }

            if blockBreakTags.contains(tagName) {
                value += "\n"
            }
            return
        }

        for child in node.getChildNodes() {
            appendText(from: child, into: &value)
        }
    }

    private static func resolvedFormat(for element: Element, tagName: String, inherited: InlineFormat) -> InlineFormat {
        var result = inherited
        if tagName == "b" || tagName == "strong" { result.bold = true }
        if tagName == "i" || tagName == "em" { result.italic = true }
        if tagName == "u" { result.underline = true }
        if tagName == "s" || tagName == "strike" || tagName == "del" { result.strikethrough = true }
        if tagName == "font", let color = ForumTextStyleRules.normalizedColorHex(element.attr("color")) {
            result.foregroundHex = color
        }
        let declarations = ForumTextStyleRules.styleDeclarations(from: element.attr("style")).mapValues {
            $0.replacingOccurrences(of: "!important", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let weight = declarations["font-weight"]?.lowercased() {
            result.bold = weight == "bold" || weight == "bolder" || (Int(weight) ?? 0) >= 600
        }
        if let fontStyle = declarations["font-style"]?.lowercased() {
            result.italic = fontStyle == "italic" || fontStyle == "oblique"
        }
        if let decoration = declarations["text-decoration"] ?? declarations["text-decoration-line"] {
            // A descendant's decoration adds to the ancestor's painted line;
            // `text-decoration: none` does not remove an outer <u> or <s>.
            result.underline = result.underline || decoration.contains("underline")
            result.strikethrough = result.strikethrough || decoration.contains("line-through")
        }
        if let color = declarations["color"].flatMap(ForumTextStyleRules.normalizedColorHex) {
            result.foregroundHex = color
        }
        if let color = declarations["background-color"].flatMap(ForumTextStyleRules.normalizedColorHex) {
            result.backgroundHex = color
        }
        return result
    }

    private static func isQuoteBlock(_ element: Element, tagName: String) -> Bool {
        tagName == "blockquote" || element.hasClass("quote")
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
                var lineBreak = lineBreaks[index - 1]
                lineBreak.character = "\n"
                lineBreak.format = .init()
                normalized.append(lineBreak)
            }
            normalized.append(contentsOf: normalizeStyledLine(line))
        }

        normalized = collapseExcessNewlines(in: normalized)
        normalized = trimStyledWhitespaceAndNewlines(normalized)

        var output = ""
        var outputCount = 0
        var inlineTextStyles: [NovelInlineTextStyleRange] = []
        var blockTextStyles: [NovelBlockTextStyleRange] = []
        let inlineKinds: [NovelInlineTextStyle] = [
            .bold, .italic, .underline, .strikethrough, .foregroundColor, .backgroundColor, .ruby
        ]
        var active: [NovelInlineTextStyle: (value: ActiveInline, start: Int)] = [:]
        var quoteStart: Int?
        for character in normalized {
            let location = outputCount
            for kind in inlineKinds {
                let next = inlineValue(for: kind, character: character)
                if let previous = active[kind], previous.value != next {
                    if location > previous.start {
                        inlineTextStyles.append(.init(
                            style: kind,
                            range: NovelCharacterRange(location: previous.start, length: location - previous.start),
                            colorHex: previous.value.colorHex,
                            rubyText: previous.value.ruby?.text
                        ))
                    }
                    active[kind] = nil
                }
                if let next, active[kind] == nil {
                    active[kind] = (next, location)
                }
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
        for kind in inlineKinds {
            guard let previous = active[kind], outputCount > previous.start else { continue }
            inlineTextStyles.append(.init(
                style: kind,
                range: NovelCharacterRange(location: previous.start, length: outputCount - previous.start),
                colorHex: previous.value.colorHex,
                rubyText: previous.value.ruby?.text
            ))
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

    private static func inlineValue(for style: NovelInlineTextStyle, character: StyledCharacter) -> ActiveInline? {
        switch style {
        case .bold: character.format.bold ? ActiveInline() : nil
        case .italic: character.format.italic ? ActiveInline() : nil
        case .underline: character.format.underline ? ActiveInline() : nil
        case .strikethrough: character.format.strikethrough ? ActiveInline() : nil
        case .foregroundColor: character.format.foregroundHex.map { ActiveInline(colorHex: $0) }
        case .backgroundColor: character.format.backgroundHex.map { ActiveInline(colorHex: $0) }
        case .ruby: character.ruby.map { ActiveInline(ruby: $0) }
        }
    }

    private static func normalizeStyledLineBreaks(_ text: [StyledCharacter]) -> [StyledCharacter] {
        var result: [StyledCharacter] = []
        var index = 0
        while index < text.count {
            let character = text[index]
            if character.character == "\r" {
                var replaced = character
                replaced.character = "\n"
                result.append(replaced)
                if index + 1 < text.count, text[index + 1].character == "\n" {
                    index += 1
                }
            } else if character.character == "\u{00A0}" {
                var replaced = character
                replaced.character = " "
                result.append(replaced)
            } else {
                result.append(character)
            }
            index += 1
        }
        return result
    }

    private static func normalizeStyledLine(_ line: [StyledCharacter]) -> [StyledCharacter] {
        var result: [StyledCharacter] = []
        var pendingWhitespaceFormat = InlineFormat()
        var pendingWhitespaceIsQuote = false
        var pendingWhitespaceRuby: RubyMarker?
        var hasPendingWhitespace = false

        for character in line {
            if character.character == " " || character.character == "\t" {
                hasPendingWhitespace = true
                pendingWhitespaceFormat.bold = pendingWhitespaceFormat.bold || character.format.bold
                pendingWhitespaceFormat.italic = pendingWhitespaceFormat.italic || character.format.italic
                pendingWhitespaceFormat.underline = pendingWhitespaceFormat.underline || character.format.underline
                pendingWhitespaceFormat.strikethrough = pendingWhitespaceFormat.strikethrough || character.format.strikethrough
                pendingWhitespaceFormat.foregroundHex = character.format.foregroundHex ?? pendingWhitespaceFormat.foregroundHex
                pendingWhitespaceFormat.backgroundHex = character.format.backgroundHex ?? pendingWhitespaceFormat.backgroundHex
                pendingWhitespaceIsQuote = pendingWhitespaceIsQuote || character.isQuote
                pendingWhitespaceRuby = character.ruby ?? pendingWhitespaceRuby
                continue
            }
            if hasPendingWhitespace, !result.isEmpty {
                result.append(
                    StyledCharacter(
                        character: " ",
                        format: pendingWhitespaceFormat,
                        isQuote: pendingWhitespaceIsQuote,
                        ruby: pendingWhitespaceRuby
                    )
                )
            }
            hasPendingWhitespace = false
            pendingWhitespaceFormat = .init()
            pendingWhitespaceIsQuote = false
            pendingWhitespaceRuby = nil
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
                    var lineBreak = character
                    lineBreak.format = .init()
                    result.append(lineBreak)
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

    private static func imageURL(from image: Element) -> URL? {
        guard let url = YamiboImageReferenceExtractor.novelInline.url(from: image),
              !NovelReaderAttachmentFilter.isFileIcon(url) else { return nil }
        return url
    }

    private static func missingAttachmentImageSegments(
        _ images: [ForumThreadPostImage],
        contentHTML: String,
        excluding attachmentImageURLs: Set<URL>,
        chapterTitle: String?
    ) -> [ParsedSegment] {
        let containedReferences = NovelHTMLImageReferenceMatcher.containedReferences(
            images.map(\.url), in: contentHTML
        )
        return images.compactMap { image in
            guard !image.url.isEmpty,
                  !containedReferences.contains(image.url),
                  let url = HTMLTextExtractor.absoluteURL(from: image.url),
                  !attachmentImageURLs.contains(url),
                  !NovelReaderAttachmentFilter.isFileIcon(url) else {
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

}

/// Matches the original raw substrings, including references occurring outside
/// image attributes. Character keys retain String.contains' canonical equality
/// and grapheme boundaries; decoded/resolved URL or UTF-8 matching would not.
private enum NovelHTMLImageReferenceMatcher {
    private struct Node {
        var transitions: [Character: Int] = [:]
        var failure = 0
        var terminal: Int?
        var output: Int?
    }

    static func containedReferences(_ references: [String], in html: String) -> Set<String> {
        var seen = Set<String>()
        let patterns = references.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !patterns.isEmpty else { return [] }
        if patterns.count == 1 {
            return html.contains(patterns[0]) ? [patterns[0]] : []
        }

        var nodes = [Node()]
        for (index, pattern) in patterns.enumerated() {
            var state = 0
            for character in pattern {
                if let next = nodes[state].transitions[character] {
                    state = next
                } else {
                    let next = nodes.count
                    nodes.append(Node())
                    nodes[state].transitions[character] = next
                    state = next
                }
            }
            nodes[state].terminal = index
        }

        var queue = Array(nodes[0].transitions.values)
        var cursor = 0
        while cursor < queue.count {
            let state = queue[cursor]
            cursor += 1
            for (character, next) in nodes[state].transitions {
                queue.append(next)
                var failure = nodes[state].failure
                while failure != 0, nodes[failure].transitions[character] == nil {
                    failure = nodes[failure].failure
                }
                failure = nodes[failure].transitions[character] ?? 0
                nodes[next].failure = failure
                nodes[next].output = nodes[failure].terminal == nil ? nodes[failure].output : failure
            }
        }

        // A reference needs only one hit. Compress consumed output chains so
        // repeated/overlapping matches do not revisit every matching suffix.
        var consumed = Array(repeating: false, count: nodes.count)
        var nextOutput = nodes.map(\.output)
        func unmatchedOutput(from output: Int?) -> Int? {
            var current = output
            while let index = current, consumed[index] { current = nextOutput[index] }
            var previous = output
            while let index = previous, consumed[index] {
                let next = nextOutput[index]
                nextOutput[index] = current
                previous = next
            }
            return current
        }
        var matches = Set<String>()
        var state = 0
        for character in html {
            while state != 0, nodes[state].transitions[character] == nil {
                state = nodes[state].failure
            }
            state = nodes[state].transitions[character] ?? 0
            var output = unmatchedOutput(from: nodes[state].terminal == nil ? nodes[state].output : state)
            while let index = output {
                if let terminal = nodes[index].terminal { matches.insert(patterns[terminal]) }
                consumed[index] = true
                output = unmatchedOutput(from: index)
            }
            if matches.count == patterns.count { break }
        }
        return matches
    }
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
                        ),
                        colorHex: style.colorHex,
                        rubyText: style.rubyText
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
                range: NovelCharacterRange(location: start, length: end - start),
                colorHex: style.colorHex,
                rubyText: style.rubyText
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
        projected.isReplyToOther = ForumPostReplyReferenceParser.parse(in: blocks) != nil
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
                inlineStyles: inlineStyleRanges(in: textBlock),
                isQuote: isQuote
            )

        case let .image(image):
            guard !image.isEmoticon else { return }
            flush(&buffer, into: &projected, chapterTitle: chapterTitle)
            appendImage(image.url, to: &projected, chapterTitle: chapterTitle, emittedImageURLs: &emittedImageURLs)

        case .attachment:
            break

        case let .quote(blocks):
            buffer.ensureLineBreak(isQuote: isQuote)
            append(blocks, to: &projected, buffer: &buffer, chapterTitle: chapterTitle, isQuote: true, emittedImageURLs: &emittedImageURLs)
            buffer.ensureLineBreak(isQuote: isQuote)

        case let .indent(blocks):
            buffer.ensureLineBreak(isQuote: isQuote)
            append(blocks, to: &projected, buffer: &buffer, chapterTitle: chapterTitle, isQuote: isQuote, emittedImageURLs: &emittedImageURLs)
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
              !NovelReaderAttachmentFilter.isFileIcon(url),
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

    private static func inlineStyleRanges(in textBlock: ForumThreadTextBlock) -> [NovelInlineTextStyleRange] {
        var styles: [NovelInlineTextStyleRange] = []
        for run in textBlock.styleRuns where run.length > 0 {
            let range = NovelCharacterRange(location: run.start, length: run.length)
            if run.style.isBold { styles.append(.init(style: .bold, range: range)) }
            if run.style.isItalic { styles.append(.init(style: .italic, range: range)) }
            if run.style.isUnderline { styles.append(.init(style: .underline, range: range)) }
            if run.style.isStrikethrough { styles.append(.init(style: .strikethrough, range: range)) }
            if let color = run.style.foregroundHex {
                styles.append(.init(style: .foregroundColor, range: range, colorHex: color))
            }
            if let color = run.style.backgroundHex {
                styles.append(.init(style: .backgroundColor, range: range, colorHex: color))
            }
        }
        styles.append(contentsOf: textBlock.rubies.compactMap { ruby in
            guard ruby.length > 0, !ruby.rubyText.isEmpty else { return nil }
            return .init(style: .ruby,
                         range: NovelCharacterRange(location: ruby.start, length: ruby.length),
                         rubyText: ruby.rubyText)
        })
        return styles
    }

    private static func readableTextFragments(
        in block: ForumThreadContentBlock,
        excludingDiscuzQuotes: Bool
    ) -> [String] {
        switch block.kind {
        case let .text(text):
            return [text.text]
        case .attachment:
            return []
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
        case let .locked(_, blocks), let .indent(blocks):
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
        ForumPostReplyReferenceParser.parseHeader(text) != nil
    }
}

private enum NovelReaderAttachmentFilter {
    static func removeFileAttachments(from body: Element) -> Set<URL> {
        // Keep image attachment blocks (`.attm`); only file cards and their
        // download metadata should disappear from the novel projection.
        let attachments = body.select(".post_attlist, .attach, dl.tattl:not(.attm)").array()
        let imageURLs = Set(attachments.flatMap { attachment in
            attachment.select("img").array().flatMap { image in
                ["zoomfile", "file", "zsrc", "src"].compactMap { attribute -> URL? in
                    let reference = image.attr(attribute).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !reference.isEmpty else { return nil }
                    return HTMLTextExtractor.absoluteURL(from: reference)
                }
            }
        })
        for attachment in attachments {
            attachment.remove()
        }
        // The post's image list can contain absolute URLs while the HTML uses
        // relative ones. Exclude by resolved URL so fallback cannot restore icons.
        return imageURLs
    }

    static func isFileIcon(_ url: URL) -> Bool {
        url.path.lowercased().contains("static/image/filetype/")
    }
}
