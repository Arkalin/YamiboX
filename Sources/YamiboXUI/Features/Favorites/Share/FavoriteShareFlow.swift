import CoreTransferable
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import YamiboXCore

@MainActor
@Observable
final class FavoriteShareFlowModel {
    private let service: FavoriteShareService

    var exportCategoryIDs: Set<String> = []
    var importTargetCategoryIDs: Set<String> = []
    private(set) var preparedExport: FavoriteShareExport?
    private(set) var importPreview: FavoriteShareImportPreview?
    private(set) var pendingImportData: Data?
    var isFileImporterPresented = false
    var isFileExporterPresented = false
    var errorMessage: String?
    var transientMessage: String?

    init(service: FavoriteShareService) {
        self.service = service
    }

    func beginExport() {
        exportCategoryIDs = []
        preparedExport = nil
        errorMessage = nil
    }

    func prepareExport() async -> Bool {
        do {
            preparedExport = try await service.export(categoryIDs: exportCategoryIDs)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func cancelExport() {
        exportCategoryIDs = []
        preparedExport = nil
        isFileExporterPresented = false
    }

    func beginImport() {
        importTargetCategoryIDs = []
        importPreview = nil
        pendingImportData = nil
        errorMessage = nil
        isFileImporterPresented = true
    }

    func loadImportFile(_ url: URL) async -> Bool {
        let accessedSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let preview = try await service.previewImport(data: data)
            pendingImportData = data
            importPreview = preview
            return true
        } catch {
            errorMessage = error.localizedDescription
            pendingImportData = nil
            importPreview = nil
            return false
        }
    }

    func importFavorites(target: FavoriteShareImportTarget) async -> Bool {
        guard let pendingImportData else {
            errorMessage = L10n.string("favorites.share.error.missing_import_data")
            return false
        }
        do {
            let result = try await service.importFavorites(data: pendingImportData, target: target)
            transientMessage = L10n.string(
                "favorites.share.import_result",
                result.createdFolderCount,
                result.createdItemCount,
                result.reusedItemCount,
                result.skippedDuplicateCount,
                result.unsupportedCount,
                result.invalidCount
            )
            cancelImport()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func cancelImport() {
        importTargetCategoryIDs = []
        importPreview = nil
        pendingImportData = nil
        isFileImporterPresented = false
    }

    func handleExporterResult(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            transientMessage = L10n.string("favorites.share.saved", url.lastPathComponent)
            preparedExport = nil
            exportCategoryIDs = []
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    func handleImporterFailure(_ error: Error) {
        let cocoaError = error as NSError
        guard cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError else {
            return
        }
        errorMessage = error.localizedDescription
    }
}

struct FavoriteShareFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct FavoriteShareTransferFile: Transferable {
    let export: FavoriteShareExport

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(file.export.fileName)
            try file.export.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

struct FavoriteShareCategorySelectionSheet: View {
    let title: String
    let categories: [FavoriteCategory]
    @Binding var selectedCategoryIDs: Set<String>
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: () async -> Void

    var body: some View {
        NavigationStack {
            List(categories) { category in
                Button {
                    toggle(category.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedCategoryIDs.contains(category.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedCategoryIDs.contains(category.id) ? Color.accentColor : Color.secondary)
                        Text(category.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if categories.isEmpty {
                    ContentUnavailableView(
                        L10n.string("favorites.share.no_categories"),
                        systemImage: "folder"
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        Task { await onConfirm() }
                    }
                    .disabled(selectedCategoryIDs.isEmpty)
                }
            }
        }
    }

    private func toggle(_ categoryID: String) {
        if selectedCategoryIDs.contains(categoryID) {
            selectedCategoryIDs.remove(categoryID)
        } else {
            selectedCategoryIDs.insert(categoryID)
        }
    }
}

struct FavoriteShareExportPreviewSheet: View {
    let export: FavoriteShareExport
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(
                        L10n.string("favorites.share.folder_count"),
                        value: String(export.folderCount)
                    )
                    LabeledContent(
                        L10n.string("favorites.share.item_count"),
                        value: String(export.itemCount)
                    )
                }
                Section {
                    ShareLink(
                        item: FavoriteShareTransferFile(export: export),
                        preview: SharePreview(export.fileName)
                    ) {
                        Label(L10n.string("favorites.share.share_file"), systemImage: "square.and.arrow.up")
                    }
                    Button(action: onSave) {
                        Label(L10n.string("favorites.share.save_file"), systemImage: "square.and.arrow.down")
                    }
                } footer: {
                    Text(L10n.string("favorites.share.export_hint"))
                }
            }
            .navigationTitle(L10n.string("favorites.share.action"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel"), action: onCancel)
                }
            }
        }
    }
}

struct FavoriteShareImportPreviewSheet: View {
    let preview: FavoriteShareImportPreview
    let onCancel: () -> Void
    let onCreateFolders: () async -> Void
    let onAddToExistingFolders: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(L10n.string("favorites.share.folder_count"), value: String(preview.folderCount))
                    LabeledContent(L10n.string("favorites.share.item_count"), value: String(preview.itemCount))
                    LabeledContent(L10n.string("favorites.share.duplicate_count"), value: String(preview.duplicateCount))
                    LabeledContent(L10n.string("favorites.share.unsupported_count"), value: String(preview.unsupportedCount))
                    LabeledContent(L10n.string("favorites.share.invalid_count"), value: String(preview.invalidCount))
                }

                Section(L10n.string("favorites.share.folders")) {
                    ForEach(Array(preview.folders.prefix(4).enumerated()), id: \.offset) { _, folder in
                        LabeledContent(folder.name, value: String(folder.itemCount))
                    }
                    if preview.folders.count > 4 {
                        Text(L10n.string("favorites.share.more_folders", preview.folders.count - 4))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task { await onCreateFolders() }
                    } label: {
                        Label(L10n.string("favorites.share.create_folders"), systemImage: "folder.badge.plus")
                    }
                    Button(action: onAddToExistingFolders) {
                        Label(L10n.string("favorites.share.add_existing"), systemImage: "folder.badge.gearshape")
                    }
                }
            }
            .navigationTitle(L10n.string("favorites.share.load"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel"), action: onCancel)
                }
            }
        }
    }
}
