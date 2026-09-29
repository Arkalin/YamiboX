import SwiftUI
import UniformTypeIdentifiers
import YamiboXCore

struct NovelReaderFontLibraryView: View {
    let library: ReaderFontLibrary
    let selection: ReaderFontSelection
    let currentSelection: ReaderFontSelection
    let onSelect: (ReaderFontSelection) -> Void
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var sampleSize = 20.0
    @State private var showsImporter = false
    @State private var report: String?
    @State private var pendingDeletion: String?
    @State private var protectionID = UUID()

    var body: some View {
        NavigationStack {
            List {
                if library.resolve(selection).isFallback {
                    Text(L10n.string("reader.font.fallback"))
                        .foregroundStyle(.secondary)
                }
                if let issue = library.issue {
                    Text(issue).foregroundStyle(.secondary)
                }
                Section(L10n.string("reader.font.built_in")) {
                    ForEach(library.entries.filter { $0.selection.fileID == nil }) { entry in
                        fontRow(entry)
                    }
                }
                Section {
                    Button { showsImporter = true } label: {
                        Label(L10n.string("reader.font.import"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(library.isWorking)
                    if library.isWorking { ProgressView(L10n.string("reader.font.processing")) }
                    ForEach(library.entries.filter { $0.selection.fileID != nil }) { entry in
                        fontRow(entry)
                            .swipeActions {
                                Button(role: .destructive) { pendingDeletion = entry.selection.fileID } label: {
                                    Label(L10n.string("common.delete"), systemImage: "trash")
                                }
                                .disabled(library.isWorking)
                            }
                    }
                } header: {
                    Text(L10n.string("reader.font.imported"))
                } footer: {
                    Text(L10n.string("reader.font.import_help"))
                }
            }
            .navigationTitle(L10n.string("reader.font.library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done")) { dismiss() }
                }
            }
            .task {
                library.protect(selection, owner: protectionID)
                await library.prepare()
                library.refreshEntries()
            }
            .onChange(of: selection) { _, selection in library.protect(selection, owner: protectionID) }
            .onDisappear {
                library.protect(nil, owner: protectionID)
            }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: ["ttf", "otf", "ttc", "otc"].compactMap {
                UTType(filenameExtension: $0)
            }, allowsMultipleSelection: true) { result in
                switch result {
                case let .success(urls):
                    Task { report = await library.importFiles(urls).joined(separator: "\n") }
                case let .failure(error): report = error.localizedDescription
                }
            }
            .alert(L10n.string("reader.font.library"), isPresented: Binding(
                get: { report != nil }, set: { if !$0 { report = nil } }
            )) {
                Button(L10n.string("common.done")) { report = nil }
            } message: { Text(report ?? "") }
            .confirmationDialog(L10n.string("reader.font.delete_file"), isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
            ), titleVisibility: .visible) {
                if let fileID = pendingDeletion {
                    Button(L10n.string("common.delete"), role: .destructive) {
                        Task {
                            do { try await library.deleteFile(fileID, protecting: [selection, currentSelection]) }
                            catch { report = error.localizedDescription }
                        }
                    }
                }
            }
        }
    }

    private func fontRow(_ entry: ReaderFontEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { select(entry) } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.title).font(.headline)
                        if entry.availability == .available {
                            let font = library.resolve(entry.selection)
                            Text(L10n.string("reader.font.sample"))
                                .font(.custom(font.bodyName, fixedSize: sampleSize))
                                .foregroundStyle(.secondary)
                        }
                        Text(statusText(entry.availability)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if selection == entry.selection {
                        Image(systemName: "checkmark").accessibilityLabel(L10n.string("reader.font.selected"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(entry.availability == .unavailable || library.isWorking)
            if entry.hasMissingSampleGlyphs {
                Text(L10n.string("reader.font.missing_glyphs")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func select(_ entry: ReaderFontEntry) {
        guard entry.availability == .available else { return }
        guard !library.resolve(entry.selection).isFallback else { library.refreshEntries(); return }
        onSelect(entry.selection)
    }

    private func statusText(_ status: ReaderFontAvailability) -> String {
        switch status {
        case .available: L10n.string("reader.font.available")
        case .unavailable: L10n.string("reader.font.unavailable")
        }
    }
}
