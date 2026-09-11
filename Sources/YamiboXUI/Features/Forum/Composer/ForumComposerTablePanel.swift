import Observation
import SwiftUI
import YamiboXCore

@MainActor
@Observable
final class ForumComposerTablePanelModel {
    var table = ForumComposerTable() { didSet { refreshPlacements() } }
    var selectedID: String?
    var endID: String?
    var cellSource = ""
    var cellWidth = ""
    var tableWidth = ""
    var tableBackground = ""
    var rowBackground = ""
    var rawSource = ""
    var sourceMode = false
    var error: String?
    @ObservationIgnored let controller = ForumEditorController()
    @ObservationIgnored private var cachedPlacements: [ForumComposerTable.Placement] = []
    @ObservationIgnored private var cellPreviews: [String: (source: String, text: String)] = [:]

    init(source: String?) {
        if let source {
            rawSource = source
            let document = ForumComposerDocument(source: source)
            if let node = document.nodes.first, let parsed = try? ForumComposerTable(document: document, node: node) { table = parsed }
            else { sourceMode = true; error = L10n.string("forum.composer.table_invalid") }
        }
        refreshPlacements()
        tableWidth = table.width?.source ?? ""
        tableBackground = table.background ?? ""
        select(table.rows.first?.cells.first?.id)
    }
    var selectedPlacement: ForumComposerTable.Placement? { placements.first { $0.cell.id == selectedID } }
    var placements: [ForumComposerTable.Placement] { _ = table; return cachedPlacements }

    private func refreshPlacements() {
        cachedPlacements = (try? table.placements()) ?? []
        let live = Set(cachedPlacements.map(\.cell.id))
        cellPreviews = cellPreviews.filter { live.contains($0.key) }
    }

    func preview(_ placement: ForumComposerTable.Placement) -> String {
        let source = placement.cell.id == selectedID ? cellSource : placement.cell.source
        if let cached = cellPreviews[placement.cell.id], cached.source == source { return cached.text }
        let text = ForumComposerDocument(source: source).plainText()
        cellPreviews[placement.cell.id] = (source, text)
        return text
    }

    func select(_ id: String?) {
        guard commitCell() else { return }
        selectedID = id; endID = nil
        cellSource = id.flatMap { table.cell(id: $0)?.source } ?? ""
        cellWidth = id.flatMap { table.cell(id: $0)?.width?.source } ?? ""
        rowBackground = selectedPlacement.flatMap { table.rows.indices.contains($0.row) ? table.rows[$0.row].background : nil } ?? ""
    }

    @discardableResult
    func commitCell() -> Bool {
        controller.pauseEditing()
        guard let selectedID else { return true }
        guard cellWidth.isEmpty || ForumComposerLength(cellWidth) != nil else { error = L10n.string("forum.composer.invalid_parameters"); return false }
        do {
            try table.updateCell(id: selectedID, source: cellSource, width: ForumComposerLength(cellWidth))
            if let row = selectedPlacement?.row {
                guard rowBackground.isEmpty || ForumComposerSyntax.normalizedColor(rowBackground) != nil else { throw ForumComposerDocumentError.invalidParameter }
                try table.setRowBackground(rowBackground.isEmpty ? nil : rowBackground, row: row)
            }
            return true
        } catch { self.error = L10n.string("forum.composer.invalid_parameters"); return false }
    }

    func change(_ operation: (inout ForumComposerTable) throws -> Void) {
        guard commitCell() else { return }
        do {
            try operation(&table)
            if selectedID.flatMap({ table.cell(id: $0) }) == nil { selectedID = nil }
            let id = selectedID ?? table.rows.first?.cells.first?.id
            selectedID = nil
            select(id)
            error = nil
        } catch { self.error = L10n.string("forum.composer.table_operation_failed") }
    }

    func source() throws -> String {
        if sourceMode { return rawSource }
        guard commitCell(), tableWidth.isEmpty || ForumComposerLength(tableWidth) != nil,
              tableBackground.isEmpty || ForumComposerSyntax.normalizedColor(tableBackground) != nil else { throw ForumComposerDocumentError.invalidParameter }
        table.width = ForumComposerLength(tableWidth)
        table.background = tableBackground.isEmpty ? nil : tableBackground
        return try table.source()
    }

    func setSourceMode(_ value: Bool) {
        if value { guard let source = try? source() else { return }; rawSource = source; sourceMode = true }
        else {
            let document = ForumComposerDocument(source: rawSource)
            guard document.nodes.count == 1, let node = document.nodes.first, let parsed = try? ForumComposerTable(document: document, node: node) else { error = L10n.string("forum.composer.table_invalid"); return }
            table = parsed; selectedID = nil
            tableWidth = table.width?.source ?? ""; tableBackground = table.background ?? ""
            select(table.rows.first?.cells.first?.id)
            sourceMode = false; error = nil
        }
    }
}

struct ForumComposerTablePanel: View {
    let request: ForumComposerNodeEditRequest
    let session: ForumBBCodeSession
    @State private var model: ForumComposerTablePanelModel?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let model { ForumComposerTablePanelContent(model: model, context: session.context) }
            else { ProgressView() }
        }
        .navigationTitle(ForumComposerLabels.title(.table)).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L10n.string("common.cancel")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.string("common.done")) {
                    guard let model else { return }
                    do {
                        let source = try model.source()
                        if session.saveNode(request, parameter: request.parameter, body: request.body, replacement: source) { dismiss() }
                        else { model.error = session.errorMessage }
                    } catch { model.error = L10n.string("forum.composer.invalid_parameters") }
                }.accessibilityIdentifier("composer-table-confirm")
            }
        }
        .interactiveDismissDisabled()
        .task {
            if model == nil {
                let created = ForumComposerTablePanelModel(source: request.originalSource)
                created.controller.bbcodeSession.localImages = session.localImages
                created.controller.bbcodeSession.refererURL = session.refererURL
                created.controller.bbcodeSession.onURLTap = session.onURLTap
                model = created
            }
        }
    }
}

private struct ForumComposerTablePanelContent: View {
    @Bindable var model: ForumComposerTablePanelModel
    let context: ForumComposerContext
    @State private var selectingRange = false
    var body: some View {
        Form {
            Section {
                Toggle(L10n.string("forum.composer.source"), isOn: Binding(get: { model.sourceMode }, set: { model.setSourceMode($0) }))
            }
            if model.sourceMode {
                Section {
                    TextEditor(text: $model.rawSource).font(.system(.body, design: .monospaced)).frame(minHeight: 340)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } else {
                Section {
                    ForumComposerTableGrid(model: model, selectingRange: selectingRange)
                        .frame(height: min(360, CGFloat(model.table.rowCount) * 72 + 8))
                    Toggle(L10n.string("forum.composer.table_range"), isOn: $selectingRange)
                    ForumComposerTableActions(model: model)
                }
                if let cell = model.selectedID.flatMap({ model.table.cell(id: $0) }) {
                    Section(L10n.string("forum.composer.cell")) {
                        AnyView(ForumBBCodeEditor(text: $model.cellSource, controller: model.controller, composerContext: context.nestedContent, compact: true))
                        LabeledContent(L10n.string("forum.composer.width")) { TextField(L10n.string("forum.composer.automatic"), text: $model.cellWidth).multilineTextAlignment(.trailing) }
                        LabeledContent(L10n.string("forum.composer.cell_span"), value: "\(cell.columnSpan) × \(cell.rowSpan)")
                        DisclosureGroup(L10n.string("forum.composer.row_background")) { ForumComposerColorField(value: $model.rowBackground) }
                    }
                }
                Section(L10n.string("forum.composer.properties")) {
                    LabeledContent(L10n.string("forum.composer.width")) { TextField(L10n.string("forum.composer.automatic"), text: $model.tableWidth).multilineTextAlignment(.trailing) }
                    DisclosureGroup(ForumComposerLabels.title(.backcolor)) { ForumComposerColorField(value: $model.tableBackground) }
                }
            }
            if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
        }
    }
}

private struct ForumComposerTableGrid: View {
    let model: ForumComposerTablePanelModel
    let selectingRange: Bool
    @State private var viewport = CGRect(x: 0, y: 0, width: 360, height: 360)
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                ForEach(model.placements.filter { frame($0).intersects(viewport.insetBy(dx: -112, dy: -144)) }, id: \.cell.id) { placement in
                    Button {
                        if selectingRange, model.selectedID != nil { model.endID = placement.cell.id }
                        else { model.select(placement.cell.id) }
                    } label: {
                        Text(model.preview(placement))
                            .font(.subheadline).lineLimit(3).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
                            .frame(width: CGFloat(placement.cell.columnSpan) * 112, height: CGFloat(placement.cell.rowSpan) * 72)
                            .background(isSelected(placement) ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground))
                            .border(isSelected(placement) ? Color.accentColor : Color.secondary.opacity(0.4), width: isSelected(placement) ? 2 : 0.5)
                    }
                    .buttonStyle(.borderless)
                    .offset(x: CGFloat(placement.column) * 112, y: CGFloat(placement.row) * 72)
                    .accessibilityLabel(L10n.string("forum.composer.cell_position", placement.row + 1, placement.column + 1))
                    .accessibilityValue(model.preview(placement))
                    .accessibilityIdentifier("composer-cell-\(placement.row)-\(placement.column)")
                }
            }.frame(width: CGFloat(model.table.columnCount) * 112, height: CGFloat(model.table.rowCount) * 72, alignment: .topLeading)
        }
        .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in viewport = rect }
    }
    private func frame(_ placement: ForumComposerTable.Placement) -> CGRect {
        CGRect(x: CGFloat(placement.column) * 112, y: CGFloat(placement.row) * 72,
               width: CGFloat(placement.cell.columnSpan) * 112, height: CGFloat(placement.cell.rowSpan) * 72)
    }
    private func isSelected(_ placement: ForumComposerTable.Placement) -> Bool {
        guard let start = model.selectedPlacement else { return false }
        guard let end = model.placements.first(where: { $0.cell.id == model.endID }) else { return placement.cell.id == start.cell.id }
        return placement.row >= min(start.row, end.row) && placement.row <= max(start.row, end.row) && placement.column >= min(start.column, end.column) && placement.column <= max(start.column, end.column)
    }
}

private struct ForumComposerTableActions: View {
    let model: ForumComposerTablePanelModel
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                Menu {
                    Button(L10n.string("forum.composer.row_before")) { let index = model.selectedPlacement?.row ?? 0; model.change { try $0.insertRow(at: index) } }
                    Button(L10n.string("forum.composer.row_after")) { let index = (model.selectedPlacement?.row ?? 0) + 1; model.change { try $0.insertRow(at: index) } }
                    Button(L10n.string("forum.composer.remove_row"), role: .destructive) { let index = model.selectedPlacement?.row ?? 0; model.change { try $0.removeRow(at: index) } }.disabled(model.table.rowCount <= 1)
                } label: { Image(systemName: "rectangle.split.1x2").frame(width: 44, height: 44) }.accessibilityLabel(L10n.string("forum.composer.rows"))
                Menu {
                    Button(L10n.string("forum.composer.column_before")) { let index = model.selectedPlacement?.column ?? 0; model.change { try $0.insertColumn(at: index) } }
                    Button(L10n.string("forum.composer.column_after")) { let index = (model.selectedPlacement?.column ?? 0) + 1; model.change { try $0.insertColumn(at: index) } }
                    Button(L10n.string("forum.composer.remove_column"), role: .destructive) { let index = model.selectedPlacement?.column ?? 0; model.change { try $0.removeColumn(at: index) } }.disabled(model.table.columnCount <= 1)
                } label: { Image(systemName: "rectangle.split.2x1").frame(width: 44, height: 44) }.accessibilityLabel(L10n.string("forum.composer.columns"))
                ForumComposerIconButton(symbol: "rectangle.compress.vertical", title: L10n.string("forum.composer.merge_cells")) {
                    guard let first = model.selectedID, let last = model.endID else { return }; model.change { try $0.merge(from: first, through: last) }
                }.disabled(model.endID == nil || model.endID == model.selectedID)
                ForumComposerIconButton(symbol: "rectangle.expand.vertical", title: L10n.string("forum.composer.split_cell")) {
                    guard let id = model.selectedID else { return }; model.change { try $0.split(id: id) }
                }.disabled(model.selectedPlacement.map { $0.cell.columnSpan == 1 && $0.cell.rowSpan == 1 } ?? true)
            }
        }.scrollIndicators(.hidden)
    }
}
