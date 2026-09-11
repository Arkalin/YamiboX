import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ForumComposerTableTests {
    @Test func readingExplicitAndPipeTablesDoesNotCanonicalizeThem() throws {
        for source in ["[TABLE=80%,#eeeeee]\n[tr][td=2,1]a[/td][/tr]\n[/TABLE]", "[table]a|b\\|c\nd|e\\nf[/table]"] {
            let document = ForumComposerDocument(source: source)
            let table = try ForumComposerTable(document: document, node: #require(document.nodes.first))
            #expect(try table.source() == source)
            #expect(table.columnCount == 2)
        }
    }

    @Test func structuralEditCanonicalizesOnlyTheEditedTable() throws {
        let source = "[B]before[/B][table]a|b\nc|d[/table][unknown]after[/unknown]"
        var document = ForumComposerDocument(source: source)
        let node = try #require(document.nodes.first { $0.tag == .table })
        var table = try ForumComposerTable(document: document, node: node)
        try table.insertColumn(at: 1)
        #expect(table.columnCount == 3)
        try document.apply(.replaceNode(id: node.id, markup: table.source()))
        #expect(document.source.hasPrefix("[B]before[/B][table]"))
        #expect(document.source.hasSuffix("[/table][unknown]after[/unknown]"))
        #expect(document.source.contains("[td]a[/td][td][/td][td]b[/td]"))
    }

    @Test func mergeAndSplitPreserveCellContentAndGrid() throws {
        var table = ForumComposerTable(rows: 2, columns: 2)
        let first = table.rows[0].cells[0].id, last = table.rows[1].cells[1].id
        try table.updateCell(id: first, source: "[b]a[/b]", width: nil)
        try table.updateCell(id: last, source: "d", width: nil)
        try table.merge(from: first, through: last)
        #expect(try table.placements().count == 1)
        #expect(table.cell(id: first)?.source == "[b]a[/b]\nd")
        #expect(table.cell(id: first)?.rowSpan == 2)
        try table.split(id: first)
        #expect(try table.placements().count == 4)
        #expect(table.rowCount == 2)
        #expect(table.columnCount == 2)
        #expect(table.cell(id: first)?.source == "[b]a[/b]\nd")
    }

    @Test func insertingAndRemovingThroughMergedCellsAdjustsSpans() throws {
        var table = ForumComposerTable(rows: 2, columns: 2)
        let first = table.rows[0].cells[0].id, last = table.rows[1].cells[1].id
        try table.merge(from: first, through: last)
        try table.insertRow(at: 1)
        try table.insertColumn(at: 1)
        #expect(table.cell(id: first)?.columnSpan == 3)
        #expect(table.cell(id: first)?.rowSpan == 3)
        try table.removeRow(at: 0)
        try table.removeColumn(at: 0)
        #expect(table.cell(id: first)?.columnSpan == 2)
        #expect(table.cell(id: first)?.rowSpan == 2)
        #expect(try table.placements().count == 1)
    }

    @Test func invalidAndExcessiveTablesCannotLoseUnknownContents() throws {
        for source in ["[table]outside[tr][td]cell[/td][/tr][/table]", "[table][tr][td=1000,1000]huge[/td][/tr][/table]"] {
            let document = ForumComposerDocument(source: source)
            #expect(throws: ForumComposerDocumentError.invalidTable) {
                _ = try ForumComposerTable(document: document, node: #require(document.nodes.first))
            }
            #expect(document.source == source)
        }
    }
}
