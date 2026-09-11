import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ForumComposerListTests {
    @Test func togglingListsRemovesOnlySelectedItemMarkers() throws {
        var whole = ForumComposerDocument(source: "[LIST=1][*]one[*]two[/LIST]")
        let projection = ForumComposerProjection(document: whole)
        try whole.apply(.format(.init(location: 0, length: projection.text.utf16.count), tag: .list, parameter: "1"))
        #expect(!whole.source.contains("[*]"))
        #expect(!whole.source.lowercased().contains("[list"))
        #expect(whole.source.contains("one") && whole.source.contains("two"))
        var partial = ForumComposerDocument(source: "[LIST=1][*]one[*]two[*]three[/LIST]")
        let range = (ForumComposerProjection(document: partial).text as NSString).range(of: "two")
        try partial.apply(.format(.init(range), tag: .list, parameter: "1"))
        #expect(partial.source == "[LIST=1][*]one[/LIST]\ntwo\n[LIST=1][*]three[/LIST]")
        #expect(partial.diagnostics.isEmpty)
    }

    @Test func returnContinuesFormattedListWithoutPuttingMarkerInsideInlineTag() throws {
        var document = ForumComposerDocument(source: "[list=1][*][b]abcd[/b][/list]")
        let command = try #require(document.listInput(at: 3))
        try document.apply(command)
        #expect(document.source == "[list=1][*][b]ab[/b]\n[*][b]cd[/b][/list]")
        #expect(document.diagnostics.isEmpty)
        let projection = ForumComposerProjection(document: document)
        #expect(projection.spans.filter { if case .listMarker = $0.kind { true } else { false } }.count == 2)
    }

    @Test func emptyItemExitsListAndKeepsFollowingItems() throws {
        var document = ForumComposerDocument(source: "[LIST=a][*]first[*]  [*]last[/LIST]")
        let projection = ForumComposerProjection(document: document)
        let location = try #require(projection.spans.first { document.substring($0.sourceRange) == "  " }?.range.end)
        try document.apply(try #require(document.listInput(at: location)))
        #expect(document.source == "[LIST=a][*]first[/LIST]\n[LIST=a][*]last[/LIST]")
        #expect(document.diagnostics.isEmpty)
    }

    @Test func nestedEmptyItemReturnsToParentList() throws {
        var document = ForumComposerDocument(source: "[list][*]first[list][*][/list][/list]")
        let offset = (ForumComposerProjection(document: document).text as NSString).length - 1
        let command = document.listInput(at: offset)
        try document.apply(try #require(command))
        #expect(document.source == "[list][*]first[*][/list]")
    }

    @Test func indentAndOutdentPreserveOtherItems() throws {
        let original = "[list=A][*]first[*]second[*]third[/list]"
        var document = ForumComposerDocument(source: original)
        let range = (ForumComposerProjection(document: document).text as NSString).range(of: "second")
        try document.apply(try #require(document.listIndent(at: range.location + 2, increase: true)))
        #expect(document.source == "[list=A][*]first[list=A][*]second[/list][*]third[/list]")
        let nestedRange = (ForumComposerProjection(document: document).text as NSString).range(of: "second")
        try document.apply(try #require(document.listIndent(at: nestedRange.location + 2, increase: false)))
        #expect(document.source == original)
    }

    @Test func collapsedTypingRemovesInheritedStyleButKeepsOtherStyles() throws {
        var document = ForumComposerDocument(source: "[B][i]ab[/i][/B]")
        try document.apply(.typeVisible(.init(location: 1), "X", enabled: [:], disabled: [.b]))
        #expect(document.source == "[B][i]a[/i][/B][i]X[/i][B][i]b[/i][/B]")
        let span = try #require(ForumComposerProjection(document: document).spans.first { document.substring($0.sourceRange) == "X" })
        #expect(!span.attributes.bold && span.attributes.italic)
        #expect(document.diagnostics.isEmpty)
    }

    @Test func disabledEmoticonsUseLiteralSourcePositionsForEditing() throws {
        let code = try #require(ForumEmoticonCatalog.categories.first?.items.first?.code)
        var document = ForumComposerDocument(source: code + " tail")
        let projection = ForumComposerProjection(document: document, parsesEmoticons: false)
        #expect(projection.text == code + " tail")
        try document.apply(.replaceVisible(.init(location: code.utf16.count + 1, length: 4), "changed"), parsesEmoticons: false)
        #expect(document.source == code + " changed")
    }
}
