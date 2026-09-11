import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ForumComposerDocumentTests {
    @Test func aliasesAndSystemMarkersRetainOriginalSpellingAndProtection() throws {
        var document = ForumComposerDocument(source: "[STRONG]one[/STRONG][Em]two[/Em][strike]three[/strike][blockquote]four[/blockquote][i=s]system[/i]")
        let original = document.source
        #expect(document.nodes.map(\.tag) == [.b, .i, .s, .quote, .i])
        #expect(document.nodes.last?.isSystem == true)
        let system = try #require(document.nodes.last)
        #expect(throws: ForumComposerDocumentError.protectedNode) {
            try document.apply(.updateNode(id: system.id, parameter: "", body: "changed"))
        }
        #expect(document.source == original)
    }
    @Test func directoryEntriesEditTheirWholeLineWithoutDuplicatingTitles() throws {
        var document = ForumComposerDocument(source: "[index]\n[#1]First\n*[#42,7]Second\n[/index]")
        let entry = try #require(document.nodes.first?.children.first { $0.tag == .indexEntry })
        #expect(document.substring(entry.contentRange) == "First")
        try document.apply(.updateNode(id: entry.id, parameter: "2", body: "Changed"))
        #expect(document.source == "[index]\n[#2]Changed\n*[#42,7]Second\n[/index]")
    }

    @Test func previewsMaskPasswordsInsideUnknownOrTruncatedSource() {
        let unknown = ForumComposerDocument(source: "[custom][password]secret[/password][/custom]")
        #expect(!unknown.plainText().contains("secret"))
        let damaged = ForumComposerDocument(source: "[password]secret without closing tag")
        #expect(!damaged.plainText().contains("secret"))
        #expect(damaged.source.contains("secret"))
    }

    static let examples: [(ForumComposerTag, String, String)] = [
        (.b, "", "bold"), (.i, "", "italic"), (.u, "", "u"), (.s, "", "s"), (.font, "Arial", "font"),
        (.size, "7", "large"), (.size, "18px", "pixels"), (.size, "12pt", "points"),
        (.color, "red", "red"), (.backcolor, "#eeeeee", "background"), (.sup, "", "2"), (.sub, "", "2"),
        (.align, "center", "aligned"), (.p, "30, 2, left", "paragraph"), (.indent, "", "indent"),
        (.float, "right", "float"), (.lineh, "1.7", "line height"), (.list, "A", "[*]one[*]two"),
        (.hr, "", ""), (.quote, "", "[b]quoted[/b]"), (.code, "", "[b]literal[/b]"),
        (.table, "80%,#eeeeee", "[tr][td=2,3,120]cell[/td][/tr]"), (.tr, "#ff0000", "[td]cell[/td]"), (.td, "2,3", "cell"),
        (.ruby, "reading", "base"), (.collapse, "0,title", "[img]https://example.com/a.png[/img]"),
        (.hide, "d7,100", "secret"), (.free, "", "free"), (.url, "home.php?mod=space&uid=1", "user"),
        (.email, "user@example.com", "email"), (.img, "640,480", "https://example.com/a.png"),
        (.attach, "", "123"), (.attachimg, "", "124"), (.audio, "1", "https://example.com/a.mp3"),
        (.media, "mp4,80%,auto", "https://example.com/v.mp4"), (.flash, "640,480", "https://example.com/a.swf"),
        (.swf, "", "https://example.com/a.swf"), (.password, "", "secret"), (.postbg, "", "bg1.png"),
        (.page, "", ""), (.index, "", "[#1]one\n*[#12,34]two\n"), (.indexEntry, "12,34", ""),
        (.begin, "https://example.com/,900,500,2,5", "https://example.com/a.png"),
        (.fly, "", "moving"), (.qq, "", "123456"), (.groupid, "123", "group"), (.item, "", "")
    ]

    @Test(arguments: examples) func everyDocumentTagIsRecognizedAndLossless(_ example: (ForumComposerTag, String, String)) throws {
        let markup = try ForumComposerSyntax.markup(tag: example.0, parameter: example.1, body: example.2)
        let document = ForumComposerDocument(source: markup)
        #expect(document.source == markup)
        #expect(document.nodes.first?.tag == example.0)
        #expect(document.diagnostics.isEmpty)
        #expect(document.nodes.map { document.substring($0.range) }.joined() == markup)
    }

    @Test(arguments: ["[b]", "[b][/b]", "[b][i]cross[/b][/i]", "[x][b]unknown[/b][/x]", "[size=no]text[/size]", "[p=30,2,left]text[/p]"])
    func malformedAndUnknownInputIsNeverRepaired(_ source: String) {
        let document = ForumComposerDocument(source: source)
        #expect(document.source == source)
        #expect(document.nodes.map { document.substring($0.range) }.joined() == source)
    }

    @Test func ordinaryTypingSplicesOnlyItsLeafAndRetainsIDs() throws {
        var document = ForumComposerDocument(source: "[B]one[/B]two[hide]secret[/hide]")
        let before = document.nodes
        try document.replaceSource(in: .init(location: 6), with: "!")
        #expect(document.source == "[B]one![/B]two[hide]secret[/hide]")
        #expect(document.nodes.map(\.id) == before.map(\.id))
        #expect(document.nodes[0].children[0].id == before[0].children[0].id)
        #expect(document.nodes[1].range.location == before[1].range.location + 1)
        #expect(document.substring(document.nodes[1].range) == "two")
        #expect(document.substring(document.nodes[2].contentRange) == "secret")
    }

    @Test func sourceSelectionUsesUTF16AndDoesNotSplitSurrogates() throws {
        var document = ForumComposerDocument(source: "[b]a\u{1F642}e\u{301}[/b]")
        let projection = ForumComposerProjection(document: document)
        #expect(projection.text == "a\u{1F642}e\u{301}")
        #expect(projection.sourceOffset(forVisibleOffset: 3) == 6)
        #expect(throws: ForumComposerDocumentError.invalidRange) {
            try document.replaceSource(in: .init(location: 5), with: "x")
        }
        try document.apply(.replaceVisible(.init(location: 1, length: 2), "emoji"))
        #expect(document.source == "[b]aemojie\u{301}[/b]")
    }

    @Test func replacementAcrossFormattingStaysBalanced() throws {
        var document = ForumComposerDocument(source: "[B]ab[/B]cd[i]ef[/i]")
        try document.apply(.replaceVisible(.init(location: 1, length: 4), "X"))
        #expect(document.source == "[B]aX[/B][i]f[/i]")
        #expect(document.diagnostics.isEmpty)
    }

    @Test func partialFormattingRemovalPreservesUnselectedStyles() throws {
        var document = ForumComposerDocument(source: "[B][i]abc[/i][/B][hide=d7,100]unchanged[/hide]")
        try document.apply(.format(.init(location: 1, length: 1), tag: .b, parameter: ""))
        #expect(document.source == "[B][i]a[/i][/B][i]b[/i][B][i]c[/i][/B][hide=d7,100]unchanged[/hide]")
        #expect(document.diagnostics.isEmpty)
        #expect(ForumComposerProjection(document: document).spans.first { document.substring($0.sourceRange) == "b" }?.attributes.bold == false)
    }

    @Test func removingWholeFormattingPreservesUnknownSourceAndLinkTargets() throws {
        var document = ForumComposerDocument(source: "[B][url=https://example.com/]abc[/url][/B][unknown]keep[/unknown]")
        try document.apply(.removeFormatting(.init(location: 0, length: 3)))
        #expect(document.source == "[url=https://example.com/]abc[/url][unknown]keep[/unknown]")
        try document.apply(.removeLink(.init(location: 0, length: 3)))
        #expect(document.source == "abc[unknown]keep[/unknown]")
    }

    @Test func literalCodeDoesNotParseNestedTagsAndPasswordsAreMaskedInPlainText() {
        let document = ForumComposerDocument(source: "[code][b]literal[/b][/code][password]secret[/password]")
        #expect(document.nodes.first?.children.first?.kind == .text)
        #expect(document.plainText() == "[b]literal[/b][password]")
        #expect(!ForumComposerProjection(document: document).text.contains("secret"))
    }

    @Test func nativeSizesAndParagraphUnitsRemainDistinct() throws {
        let document = ForumComposerDocument(source: "[size=7]a[/size][size=18px]b[/size][size=12pt]c[/size][p=30, 2, left][lineh=1.7]d[/lineh][/p]")
        let spans = ForumComposerProjection(document: document).spans.filter { $0.kind == .text }
        #expect(spans[0].attributes.relativeSize == 3)
        #expect(spans[1].attributes.pointSize == 18)
        #expect(spans[2].attributes.pointSize == 16)
        #expect(spans[3].attributes.lineHeight == 30)
        #expect(spans[3].attributes.lineHeightMultiple == 1.7)
    }

    @Test func deepDocumentsRemainLosslessAndBounded() {
        let source = String(repeating: "[b]", count: 200) + "text" + String(repeating: "[/b]", count: 200)
        let document = ForumComposerDocument(source: source)
        #expect(document.diagnostics.contains { $0.reason == .depthLimit })
        #expect(document.source == source)
        #expect(ForumComposerProjection(document: document).text.contains("[b]"))
    }

    @Test func unsafeLinksNeverActivateButTheirSourceSurvives() {
        for address in ["javascript:alert(1)", "file:///private/a", "data:text/html,x", "https://user:pass@example.com/"] {
            let source = "[url=\(address)]link[/url]"
            let document = ForumComposerDocument(source: source)
            #expect(document.source == source)
            #expect(ForumComposerProjection(document: document).spans.first?.attributes.link == nil)
        }
        #expect(ForumComposerSyntax.safeURL("home.php?mod=space&uid=1")?.host == "bbs.yamibo.com")
    }
}
