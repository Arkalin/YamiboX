import Foundation
import Testing
@testable import YamiboXCore

@MainActor
@Suite("AppTests: Directory Rename Wiring")
struct YamiboAppContextDirectoryRenameTests {
    @Test func directoryRenameNotifiesTheContextProgressStoreWithoutUIFollowUp() async throws {
        let suiteName = "directory-rename-context-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let context = YamiboAppContext(
            sessionStore: SessionStore(defaults: defaults),
            grdbRootDirectory: root.appendingPathComponent("data", isDirectory: true),
            cachesRootDirectory: root.appendingPathComponent("caches", isDirectory: true),
            clearsWebDataOnReset: false
        )
        let original = MangaDirectory(
            cleanBookName: "Original", strategy: .links, sourceKey: "chapter:100",
            chapters: [MangaChapter(tid: "100", rawTitle: "Chapter", chapterNumber: 1, view: 2)]
        )
        try await context.mangaDirectoryStore.saveDirectory(original)
        _ = try await context.readingProgressStore.saveMangaTitle(
            cleanBookName: original.cleanBookName, chapterThreadID: "100",
            chapterTitle: "Chapter", pageIndex: 7, mangaID: original.favoriteIdentity
        )
        let changes = context.readingProgressStore.changes()
        var observedChangeID: String?
        let observation = Task {
            for await changeID in changes {
                observedChangeID = changeID
                break
            }
        }
        defer { observation.cancel() }
        var renamed = original
        renamed.cleanBookName = "Renamed"
        try await context.mangaDirectoryStore.renameDirectory(from: original.cleanBookName, to: renamed)
        for _ in 0..<200 where observedChangeID == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        observation.cancel()
        await observation.value

        #expect(observedChangeID == context.readingProgressStore.changeID)
        let migrated = await context.readingProgressStore.load(for: FavoriteContentTarget(
            mangaID: renamed.favoriteIdentity, mangaCleanBookName: renamed.cleanBookName
        ))
        #expect(migrated?.manga?.mangaPageIndex == 7)
        #expect(migrated?.manga?.chapterThreadID == "100")
        #expect(try await context.mangaDirectoryStore.directory(named: original.cleanBookName) == nil)
    }
}
