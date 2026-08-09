import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
@Test func favoriteShareFlowModelHandlesExportImportCancellationAndErrors() async throws {
    let defaults = try YamiboTestDefaults.make(prefix: "favorite-share-flow")
    let libraryStore = FavoriteLibraryStore(defaults: defaults, key: "library")
    let coverStore = ContentCoverStore(defaults: defaults, key: "covers")
    let settingsStore = SettingsStore(defaults: defaults, key: "settings")
    let service = FavoriteShareService(
        libraryStore: libraryStore,
        contentCoverStore: coverStore,
        settingsStore: settingsStore
    )
    let model = FavoriteShareFlowModel(service: service)

    var document = FavoriteLibraryDocument()
    let category = document.createCategory(name: "本地收藏")
    document.upsertItem(try FavoriteItem(
        target: .normalThread(threadID: "901"),
        title: "主题",
        locations: [.category(category.id)]
    ))
    try await libraryStore.save(document)

    model.beginExport()
    #expect(await model.prepareExport() == false)
    #expect(model.errorMessage != nil)
    model.errorMessage = nil
    model.exportCategoryIDs = [category.id]
    #expect(await model.prepareExport())
    #expect(model.preparedExport?.folderCount == 1)
    #expect(model.preparedExport?.itemCount == 1)
    model.cancelExport()
    #expect(model.preparedExport == nil)
    #expect(model.exportCategoryIDs.isEmpty)

    let package = FavoriteSharePackage(
        exportedAt: 1,
        folders: [.init(name: "Android", items: [
            .init(targetType: "ThreadNovel", targetId: 902, title: "导入小说")
        ])]
    )
    let packageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("favorite-share-flow-\(UUID().uuidString).json")
    try FavoriteShareCodec.encode(package).write(to: packageURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: packageURL) }

    model.beginImport()
    #expect(await model.loadImportFile(packageURL))
    #expect(model.importPreview?.folderCount == 1)
    #expect(await model.importFavorites(target: .createFolders))
    #expect(model.importPreview == nil)
    #expect(model.transientMessage != nil)
    #expect(try await libraryStore.load().items.contains { $0.target.threadID == "902" })

    let invalidURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("favorite-share-invalid-\(UUID().uuidString).json")
    try Data("not-json".utf8).write(to: invalidURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: invalidURL) }
    model.beginImport()
    #expect(await model.loadImportFile(invalidURL) == false)
    #expect(model.errorMessage != nil)

    model.errorMessage = nil
    model.handleImporterFailure(CocoaError(.userCancelled))
    #expect(model.errorMessage == nil)
}
