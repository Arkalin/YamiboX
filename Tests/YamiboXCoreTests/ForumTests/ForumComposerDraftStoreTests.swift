import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

@Suite struct ForumComposerDraftStoreTests {
    private struct Fixture {
        let root: URL
        let pool: DatabasePool
        let store: ForumComposerDraftStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("composer-drafts-\(UUID().uuidString)")
            pool = try YamiboDatabase.openPool(rootDirectory: root)
            store = ForumComposerDraftStore(databasePool: pool, baseDirectory: root.appendingPathComponent("resources"))
        }
        func cleanup() { try? pool.close(); try? FileManager.default.removeItem(at: root) }
    }

    @Test func cancelledImportBeforeFirstSaveDoesNotLeaveAnOrphanResource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let generation = try await fixture.store.generation()
        let id = UUID()
        let resource = try await fixture.store.importResource(.init(name: "cancelled.png", data: Data([1])), draftID: id, accountUID: "100", generation: generation)
        try await fixture.store.removeUnreferencedResources(draftID: id, accountUID: "100", generation: generation)
        await #expect(throws: ForumComposerDraftError.missingResource) { _ = try await fixture.store.resource(id: resource, accountUID: "100") }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("resources").appendingPathComponent(resource.uuidString).path))
    }

    @Test func draftsSurviveReopeningAndStayAccountIsolated() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let generation = try await fixture.store.generation()
        let draft = ForumComposerDraft(accountUID: "100", target: .init(kind: .reply, threadID: "42"), fields: ["message": ["[B]exact[/B]"], "formhash": ["never"]])
        try await fixture.store.save(draft, expecting: nil, generation: generation)
        let other = ForumComposerDraft(accountUID: "101", target: draft.target, fields: ["message": ["other"]])
        try await fixture.store.save(other, expecting: nil, generation: generation)
        let reopened = ForumComposerDraftStore(databasePool: fixture.pool, baseDirectory: fixture.root.appendingPathComponent("resources"))
        #expect(try await reopened.drafts(accountUID: "100") == [draft])
        #expect(try await reopened.draft(id: draft.id, accountUID: "101") == nil)
        #expect(draft.fields["formhash"] == nil)
    }

    @Test func compareAndSwapAndTombstonesRejectStaleSaves() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let generation = try await fixture.store.generation()
        var draft = ForumComposerDraft(accountUID: "100", target: .init(kind: .newThread, forumID: "5"), fields: ["message": ["first"]])
        try await fixture.store.save(draft, expecting: nil, generation: generation)
        draft.revision = 2
        draft.fields["message"] = ["second"]
        try await fixture.store.save(draft, expecting: 1, generation: generation)
        await #expect(throws: ForumComposerDraftError.conflict) { try await fixture.store.save(draft, expecting: 1, generation: generation) }
        #expect(try await fixture.store.delete(id: draft.id, accountUID: "100", expecting: 1, generation: generation) == false)
        #expect(try await fixture.store.draft(id: draft.id, accountUID: "100")?.source == "second")
        try await fixture.store.delete(id: draft.id, accountUID: "100", generation: generation)
        draft.revision = 3
        await #expect(throws: ForumComposerDraftError.deleted) { try await fixture.store.save(draft, expecting: 2, generation: generation) }
    }

    @Test func resetRejectsOldGenerationsAcrossStoreInstances() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let oldGeneration = try await fixture.store.generation()
        let draft = ForumComposerDraft(accountUID: "100", target: .init(), fields: ["message": ["late"]])
        let other = ForumComposerDraftStore(databasePool: fixture.pool, baseDirectory: fixture.root.appendingPathComponent("resources"))
        try await other.clearAll()
        await #expect(throws: ForumComposerDraftError.reset) { try await fixture.store.save(draft, expecting: nil, generation: oldGeneration) }
        #expect(try await fixture.store.drafts(accountUID: "100").isEmpty)
    }

    @Test func resourcesAreOwnedAndRemovedOnlyWithTheirDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let generation = try await fixture.store.generation()
        var draft = ForumComposerDraft(accountUID: "100", target: .init(kind: .reply, threadID: "42"), fields: ["message": ["image"]])
        let file = ForumAttachmentFile(name: "../picture.png", data: Data([1, 2, 3]))
        let resource = try await fixture.store.importResource(file, draftID: draft.id, accountUID: draft.accountUID, generation: generation)
        draft.attachments = [.init(name: file.name, mimeType: "image/png", isImage: true, resourceID: resource)]
        try await fixture.store.save(draft, expecting: nil, generation: generation)
        #expect(try await fixture.store.resource(id: resource, accountUID: "100").data == file.data)
        await #expect(throws: ForumComposerDraftError.missingResource) { _ = try await fixture.store.resource(id: resource, accountUID: "101") }
        try await fixture.store.delete(id: draft.id, accountUID: "100", generation: generation)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("resources").appendingPathComponent(resource.uuidString).path))
    }

    @Test func fieldSnapshotsUseNamesAndNeverRestoreAuthenticationOrReadOnlyValues() {
        let form = ForumForm(id: "old", title: "", actionURL: YamiboDomain.baseURL, kind: .thread, fields: [
            .init(id: "s1", name: "subject", label: "", initialValues: ["subject"]),
            .init(id: "m1", name: "message", label: "", kind: .multiline, initialValues: ["old"]),
            .init(id: "p1", name: "password", label: "", kind: .password, initialValues: ["never"]),
            .init(id: "h1", name: "formhash", label: "", initialValues: ["token"])
        ])
        let snapshot = ForumComposerDraftFields.snapshot(form: form, values: ["m1": ["draft"]])
        let fresh = ForumForm(id: "fresh", title: "", actionURL: YamiboDomain.baseURL, kind: .thread, fields: [
            .init(id: "m2", name: "message", label: "", kind: .multiline, initialValues: ["server"]),
            .init(id: "s2", name: "subject", label: "", initialValues: ["locked"], isReadOnly: true),
            .init(id: "h2", name: "formhash", label: "", initialValues: ["fresh-token"])
        ])
        #expect(snapshot.keys.sorted() == ["message", "subject"])
        let restored = ForumComposerDraftFields.restoring(snapshot, into: fresh)
        #expect(restored["m2"] == ["draft"])
        #expect(restored["s2"] == ["locked"])
        #expect(restored["h2"] == ["fresh-token"])
    }
}
