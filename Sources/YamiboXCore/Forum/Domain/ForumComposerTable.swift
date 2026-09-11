import Foundation

public struct ForumComposerTable: Equatable, Sendable {
    public struct Cell: Equatable, Sendable, Identifiable {
        public let id: String
        public var source: String
        public var columnSpan: Int
        public var rowSpan: Int
        public var width: ForumComposerLength?
        public init(id: String = UUID().uuidString, source: String = "", columnSpan: Int = 1, rowSpan: Int = 1, width: ForumComposerLength? = nil) {
            self.id = id
            self.source = source
            self.columnSpan = columnSpan
            self.rowSpan = rowSpan
            self.width = width
        }
    }
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public var background: String?
        public var cells: [Cell]
        public init(id: String = UUID().uuidString, background: String? = nil, cells: [Cell]) {
            self.id = id; self.background = background; self.cells = cells
        }
    }
    public struct Placement: Equatable, Sendable {
        public var row: Int
        public var column: Int
        public var cell: Cell
    }
    public static let maximumDimension = 100
    public private(set) var rows: [Row]
    public var width: ForumComposerLength?
    public var background: String?
    private var originalSource: String?
    private var originalRows: [Row]?
    private var originalWidth: ForumComposerLength?
    private var originalBackground: String?

    public init(rows: Int = 2, columns: Int = 2) {
        self.rows = (0..<max(1, min(rows, Self.maximumDimension))).map { _ in
            Row(cells: (0..<max(1, min(columns, Self.maximumDimension))).map { _ in Cell() })
        }
    }

    public init(document: ForumComposerDocument, node: ForumComposerNode) throws {
        guard node.tag == .table else { throw ForumComposerDocumentError.invalidTable }
        if case let .table(width, background) = node.attributes { self.width = width; self.background = background }
        let explicit = node.children.contains { $0.tag == .tr }
        if explicit {
            guard node.children.allSatisfy({ $0.tag == .tr || document.substring($0.range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ForumComposerDocumentError.invalidTable
            }
            rows = try node.children.filter { $0.tag == .tr }.map { row in
                guard row.children.allSatisfy({ $0.tag == .td || document.substring($0.range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw ForumComposerDocumentError.invalidTable
                }
                let color: String? = if case let .text(value) = row.attributes { value } else { nil }
                let cells: [Cell] = try row.children.filter { $0.tag == .td }.map { cell in
                    guard case let .cell(columns, rows, width) = cell.attributes else { throw ForumComposerDocumentError.invalidTable }
                    return Cell(id: cell.id, source: document.substring(cell.contentRange), columnSpan: columns, rowSpan: rows, width: width)
                }
                return Row(id: row.id, background: color, cells: cells)
            }
        } else {
            let body = document.substring(node.contentRange)
            guard !body.lowercased().contains("[/td]"), !body.lowercased().contains("[/tr]") else { throw ForumComposerDocumentError.invalidTable }
            rows = Self.pipeRows(body).map { Row(cells: $0.map { Cell(source: $0) }) }
        }
        guard !rows.isEmpty, rows.count <= Self.maximumDimension else { throw ForumComposerDocumentError.invalidTable }
        _ = try placements()
        originalSource = document.substring(node.range)
        originalRows = rows
        originalWidth = width
        originalBackground = background
    }

    public func placements() throws -> [Placement] {
        var occupied = Set<Int>()
        var result: [Placement] = []
        for (rowIndex, row) in rows.enumerated() {
            var column = 0
            for cell in row.cells {
                while occupied.contains(rowIndex * Self.maximumDimension + column) { column += 1 }
                guard cell.rowSpan > 0, cell.columnSpan > 0,
                      column + cell.columnSpan <= Self.maximumDimension,
                      rowIndex + cell.rowSpan <= Self.maximumDimension else { throw ForumComposerDocumentError.invalidTable }
                for row in rowIndex..<(rowIndex + cell.rowSpan) {
                    for col in column..<(column + cell.columnSpan) {
                        guard occupied.insert(row * Self.maximumDimension + col).inserted else { throw ForumComposerDocumentError.invalidTable }
                    }
                }
                result.append(.init(row: rowIndex, column: column, cell: cell))
                column += cell.columnSpan
            }
        }
        return result
    }

    public var columnCount: Int { (try? placements().map { $0.column + $0.cell.columnSpan }.max()) ?? 1 }
    public var rowCount: Int { max(rows.count, (try? placements().map { $0.row + $0.cell.rowSpan }.max()) ?? 1) }

    public func cell(id: String) -> Cell? { rows.lazy.flatMap(\.cells).first { $0.id == id } }

    public mutating func updateCell(id: String, source: String, width: ForumComposerLength?) throws {
        for row in rows.indices {
            if let column = rows[row].cells.firstIndex(where: { $0.id == id }) {
                rows[row].cells[column].source = source
                rows[row].cells[column].width = width
                return
            }
        }
        throw ForumComposerDocumentError.missingNode
    }

    public mutating func setRowBackground(_ color: String?, row: Int) throws {
        guard rows.indices.contains(row) else { throw ForumComposerDocumentError.invalidRange }
        rows[row].background = color
    }

    public mutating func insertRow(at index: Int) throws {
        guard (0...rowCount).contains(index), rowCount < Self.maximumDimension else { throw ForumComposerDocumentError.invalidTable }
        let count = rowCount, columns = columnCount
        var placements = try placements()
        for item in placements.indices {
            if placements[item].row >= index { placements[item].row += 1 }
            else if placements[item].row + placements[item].cell.rowSpan > index { placements[item].cell.rowSpan += 1 }
        }
        while rows.count < count { rows.append(Row(cells: [])) }
        rows.insert(Row(cells: []), at: index)
        rebuild(placements, rowCount: count + 1, columns: columns)
    }

    public mutating func removeRow(at index: Int) throws {
        let count = rowCount
        guard count > 1, (0..<count).contains(index) else { throw ForumComposerDocumentError.invalidTable }
        var placements = try placements().filter { $0.row != index || $0.cell.rowSpan > 1 }
        for item in placements.indices {
            if placements[item].row > index { placements[item].row -= 1 }
            else if placements[item].row + placements[item].cell.rowSpan > index { placements[item].cell.rowSpan -= 1 }
        }
        let columns = columnCount
        if rows.indices.contains(index) { rows.remove(at: index) }
        rebuild(placements, rowCount: count - 1, columns: columns)
    }

    public mutating func insertColumn(at index: Int) throws {
        let columns = columnCount
        guard (0...columns).contains(index), columns < Self.maximumDimension else { throw ForumComposerDocumentError.invalidTable }
        var placements = try placements()
        for item in placements.indices {
            if placements[item].column >= index { placements[item].column += 1 }
            else if placements[item].column + placements[item].cell.columnSpan > index { placements[item].cell.columnSpan += 1 }
        }
        rebuild(placements, rowCount: rowCount, columns: columns + 1)
    }

    public mutating func removeColumn(at index: Int) throws {
        let columns = columnCount
        guard columns > 1, (0..<columns).contains(index) else { throw ForumComposerDocumentError.invalidTable }
        var placements = try placements().filter { $0.column != index || $0.cell.columnSpan > 1 }
        for item in placements.indices {
            if placements[item].column > index { placements[item].column -= 1 }
            else if placements[item].column + placements[item].cell.columnSpan > index { placements[item].cell.columnSpan -= 1 }
        }
        rebuild(placements, rowCount: rowCount, columns: columns - 1)
    }

    public mutating func merge(from firstID: String, through lastID: String) throws {
        var placements = try placements()
        guard let first = placements.first(where: { $0.cell.id == firstID }), let last = placements.first(where: { $0.cell.id == lastID }) else {
            throw ForumComposerDocumentError.missingNode
        }
        let top = min(first.row, last.row), left = min(first.column, last.column)
        let bottom = max(first.row + first.cell.rowSpan, last.row + last.cell.rowSpan)
        let right = max(first.column + first.cell.columnSpan, last.column + last.cell.columnSpan)
        let intersecting = placements.filter { $0.row < bottom && $0.row + $0.cell.rowSpan > top && $0.column < right && $0.column + $0.cell.columnSpan > left }
        guard intersecting.count > 1, intersecting.allSatisfy({ $0.row >= top && $0.column >= left && $0.row + $0.cell.rowSpan <= bottom && $0.column + $0.cell.columnSpan <= right }),
              let anchor = intersecting.first(where: { $0.row == top && $0.column == left }) else { throw ForumComposerDocumentError.invalidTable }
        var cell = anchor.cell
        cell.source = intersecting.sorted { $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row }.map(\.cell.source).filter { !$0.isEmpty }.joined(separator: "\n")
        cell.columnSpan = right - left
        cell.rowSpan = bottom - top
        let ids = Set(intersecting.map(\.cell.id))
        placements.removeAll { ids.contains($0.cell.id) }
        placements.append(.init(row: top, column: left, cell: cell))
        rebuild(placements, rowCount: rowCount, columns: columnCount)
    }

    public mutating func split(id: String) throws {
        var placements = try placements()
        guard let index = placements.firstIndex(where: { $0.cell.id == id }) else { throw ForumComposerDocumentError.missingNode }
        let columns = columnCount, count = rowCount
        placements[index].cell.columnSpan = 1
        placements[index].cell.rowSpan = 1
        rebuild(placements, rowCount: count, columns: columns)
    }

    public func source() throws -> String {
        if rows == originalRows, width == originalWidth, background == originalBackground, let originalSource { return originalSource }
        _ = try placements()
        let tableParameter = width.map(\.source) ?? (background == nil ? "" : "98%")
        let parameter = tableParameter + (background.map { "," + $0 } ?? "")
        let body = try rows.map { row in
            let body = try row.cells.map { cell in
                let parameter: String
                if cell.columnSpan != 1 || cell.rowSpan != 1 {
                    parameter = "\(cell.columnSpan),\(cell.rowSpan)" + (cell.width.map { "," + $0.source } ?? "")
                } else { parameter = cell.width?.source ?? "" }
                return try ForumComposerSyntax.markup(tag: .td, parameter: parameter, body: cell.source)
            }.joined()
            return try ForumComposerSyntax.markup(tag: .tr, parameter: row.background ?? "", body: body)
        }.joined(separator: "\n")
        return try ForumComposerSyntax.markup(tag: .table, parameter: parameter, body: "\n" + body + "\n")
    }

    private mutating func rebuild(_ placements: [Placement], rowCount: Int, columns: Int) {
        var occupied = Set<Int>()
        for placement in placements {
            for row in placement.row..<(placement.row + placement.cell.rowSpan) {
                for column in placement.column..<(placement.column + placement.cell.columnSpan) { occupied.insert(row * Self.maximumDimension + column) }
            }
        }
        var items = placements
        for row in 0..<rowCount {
            for column in 0..<columns where !occupied.contains(row * Self.maximumDimension + column) {
                items.append(.init(row: row, column: column, cell: Cell()))
            }
        }
        rows = (0..<rowCount).map { index in
            var row = rows.indices.contains(index) ? rows[index] : Row(cells: [])
            row.cells = items.filter { $0.row == index }.sorted { $0.column < $1.column }.map(\.cell)
            return row
        }
    }

    private static func pipeRows(_ source: String) -> [[String]] {
        let source = source.trimmingCharacters(in: .newlines)
        guard !source.isEmpty else { return [[""]] }
        var rows: [[String]] = [[]], cell = "", escaping = false
        for character in source {
            if escaping {
                switch character { case "|": cell += "|"; case "n": cell += "\n"; default: cell += "\\" + String(character) }
                escaping = false
            } else if character == "\\" { escaping = true }
            else if character == "|" { rows[rows.count - 1].append(cell); cell = "" }
            else if character == "\n" { rows[rows.count - 1].append(cell); cell = ""; rows.append([]) }
            else { cell.append(character) }
        }
        if escaping { cell += "\\" }
        rows[rows.count - 1].append(cell)
        return rows
    }
}
