import SwiftUI
import UIKit
import XCTest
import YamiboXTestSupport
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class ForumComposerDraftIntegrationTests: XCTestCase {
    func testOfflineReloadPreservesRestoredBodyWithoutRequiringAnotherEdit() async throws {
        let fixture = try await pageFixture()
        fixture.model.drafts["postform"]?["message"] = ["saved offline body"]
        _ = await fixture.model.flushLocalDraft(force: true)
        let saved = try XCTUnwrap(fixture.model.composerDraft?.current)
        await fixture.repository.setFetchFailure(true)
        await fixture.model.restoreDraft(saved)
        XCTAssertTrue(fixture.model.isOfflineDraft)
        await fixture.repository.setFetchFailure(false)
        await fixture.model.reloadComposerPreservingEdits()
        XCTAssertFalse(fixture.model.isOfflineDraft)
        XCTAssertEqual(fixture.model.drafts["postform"]?["message"], ["saved offline body"])
    }

    func testRemovingFormFileAlsoRemovesDurableAttachmentReference() async throws {
        let fixture = try await pageFixture()
        let form = fixture.model.page!.forms[0]
        let file = ForumFormFile(fieldName: "file", file: .init(name: "test.txt", data: Data([1])), mimeType: "text/plain")
        await fixture.model.stageFormFile(file, form: form)
        XCTAssertEqual(fixture.model.composerAssets.count, 1)
        fixture.model.setSelectedFiles([], form: form)
        _ = await fixture.model.flushLocalDraft(force: true)
        XCTAssertTrue(fixture.model.composerAssets.isEmpty)
        XCTAssertTrue(fixture.model.composerDraft?.current?.attachments.isEmpty == true)
        let drafts = await fixture.store.drafts(accountUID: "1")
        XCTAssertTrue(drafts.first?.attachments.isEmpty == true)
    }

    func testRemovingFileDuringResourceImportCannotRecreateAttachment() async throws {
        let fixture = try await pageFixture()
        let form = fixture.model.page!.forms[0]
        let file = ForumFormFile(fieldName: "file", file: .init(name: "test.txt", data: Data([1])), mimeType: "text/plain")
        await fixture.store.holdResourceImport()
        let importTask = Task { await fixture.model.stageFormFile(file, form: form) }
        await fixture.store.waitForResourceImport()
        fixture.model.setSelectedFiles([], form: form)
        await fixture.store.releaseResourceImport()
        await importTask.value
        XCTAssertTrue(fixture.model.composerAssets.isEmpty)
        XCTAssertTrue(fixture.model.selectedFiles[form.id]?.isEmpty == true)
    }

    func testAccountChangeWhileImportingFormFileRejectsLateReference() async throws {
        let fixture = try await pageFixture()
        let form = fixture.model.page!.forms[0]
        let file = ForumFormFile(fieldName: "file", file: .init(name: "test.txt", data: Data([1])), mimeType: "text/plain")
        await fixture.store.holdResourceImport()
        let importTask = Task { await fixture.model.stageFormFile(file, form: form) }
        await fixture.store.waitForResourceImport()
        try await fixture.sessions.save(SessionState(cookie: "EeqY_2132_auth=two", isLoggedIn: true, accountUID: "2"))
        fixture.model.composerDraft?.invalidate()
        await fixture.store.releaseResourceImport()
        await importTask.value
        XCTAssertTrue(fixture.model.composerAssets.isEmpty)
        XCTAssertTrue(fixture.model.selectedFiles.isEmpty)
        XCTAssertTrue(fixture.model.drafts.isEmpty)
    }

    func testMissingPendingResourceIsVisibleAndIsNotAutomaticallyUploaded() async throws {
        let fixture = try await pageFixture()
        let form = fixture.model.page!.forms[0]
        await fixture.repository.setUploadFailure(true)
        await fixture.model.upload(file: .init(name: "test.jpg", data: Data([1])), mimeType: "image/jpeg", configuration: draftUpload, form: form)
        _ = await fixture.model.flushLocalDraft(force: true)
        let saved = try XCTUnwrap(fixture.model.composerDraft?.current)
        await fixture.store.removeAllResources()
        await fixture.model.restoreDraft(saved)
        let id = try XCTUnwrap(fixture.model.composerAssets.first?.id)
        XCTAssertNotNil(fixture.model.assetFailures[id])
        let restoredForm = try XCTUnwrap(fixture.model.page?.forms.first)
        fixture.model.prepareSubmission(form: restoredForm, button: restoredForm.buttons[0])
        XCTAssertNil(fixture.model.pendingSubmission)
        let count = await fixture.repository.uploadCount
        XCTAssertEqual(count, 1)
    }

    func testSlowAutosaveSerializesNewerRevisionAndConcurrentFlushes() async throws {
        let sessions = try await sessionStore()
        let store = ComposerDraftMemoryStore()
        let coordinator = ForumComposerDraftCoordinator(store: store, sessionStore: sessions)
        let page = draftPage()
        let form = page.forms[0]
        await coordinator.start(form: form, context: page.composerContext!)
        coordinator.update(form: form, values: ["subject": ["title"], "message": ["first"]])
        await store.holdNextSave()
        let first = Task { await coordinator.flush() }
        await store.waitForSave()
        coordinator.update(form: form, values: ["subject": ["title"], "message": ["second"]])
        let second = Task { await coordinator.flush() }
        await store.releaseSave()
        let firstResult = await first.value, secondResult = await second.value
        XCTAssertTrue(firstResult && secondResult)
        let writes = await store.writes
        XCTAssertEqual(writes.map(\.source), ["first", "second"])
        XCTAssertEqual(writes.map(\.revision), [1, 2])
        let peak = await store.peakWriters
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(coordinator.current?.source, "second")
    }

    func testSaveFailureRemainsVisibleAndCanRetryWithoutLosingSource() async throws {
        let sessions = try await sessionStore()
        let store = ComposerDraftMemoryStore()
        let coordinator = ForumComposerDraftCoordinator(store: store, sessionStore: sessions)
        let page = draftPage(), form = draftPage().forms[0]
        await coordinator.start(form: form, context: page.composerContext!)
        coordinator.update(form: form, values: ["subject": ["title"], "message": ["[password]private[/password]"]])
        await store.setSaveFailure(true)
        let failed = await coordinator.flush()
        XCTAssertFalse(failed)
        guard case .failed = coordinator.status else { return XCTFail("A failed write must not report Saved") }
        XCTAssertTrue(coordinator.current?.source.contains("private") == true)
        await store.setSaveFailure(false)
        let succeeded = await coordinator.flush()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(coordinator.savedRevision, 1)
    }

    func testDraftsStayAccountScopedAndReturnAfterSameUIDLogsInAgain() async throws {
        let sessions = try await sessionStore()
        let store = ComposerDraftMemoryStore()
        let form = draftPage().forms[0], context = draftPage().composerContext!
        let first = ForumComposerDraftCoordinator(store: store, sessionStore: sessions)
        await first.start(form: form, context: context)
        first.update(form: form, values: ["message": ["account one"]])
        _ = await first.flush()
        try await sessions.save(SessionState())
        first.invalidate()
        try await sessions.save(SessionState(cookie: "EeqY_2132_auth=two", isLoggedIn: true, accountUID: "2"))
        let second = ForumComposerDraftCoordinator(store: store, sessionStore: sessions)
        await second.start(form: form, context: context)
        XCTAssertTrue(second.available.isEmpty)
        try await sessions.save(SessionState(cookie: "EeqY_2132_auth=one-new", isLoggedIn: true, accountUID: "1"))
        second.invalidate()
        let restored = ForumComposerDraftCoordinator(store: store, sessionStore: sessions)
        await restored.start(form: form, context: context)
        XCTAssertEqual(restored.available.map(\.source), ["account one"])
    }

    func testRestorationRefetchesTokensAndMapsFieldNamesInsteadOfOldIDs() async throws {
        let fixture = try await pageFixture()
        let model = fixture.model
        model.drafts["postform"]?["message"] = ["[b]local[/b]"]
        _ = await model.flushLocalDraft(force: true)
        let saved = try XCTUnwrap(model.composerDraft?.current)
        XCTAssertFalse(saved.fields.keys.contains("formhash"))
        await fixture.repository.setPage(draftPage(fieldSuffix: "-fresh", token: "new-token"))
        await model.restoreDraft(saved)
        let form = try XCTUnwrap(model.page?.forms.first)
        XCTAssertEqual(model.drafts[form.id]?["message-fresh"], ["[b]local[/b]"])
        XCTAssertEqual(form.hiddenValues.first?.value, "new-token")
        let submitted = await fixture.repository.submissionCount
        XCTAssertEqual(submitted, 0)
    }

    func testServerEditConflictKeepsBothVersionsWithoutAutomaticMerge() async throws {
        let page = draftPage(body: "server before", target: .init(kind: .editFirstPost, threadID: "10", postID: "20"))
        let fixture = try await pageFixture(page: page)
        fixture.model.drafts["postform"]?["message"] = ["local change"]
        _ = await fixture.model.flushLocalDraft(force: true)
        let saved = try XCTUnwrap(fixture.model.composerDraft?.current)
        await fixture.repository.setPage(draftPage(body: "server after", target: page.composerContext!.target))
        await fixture.model.restoreDraft(saved)
        XCTAssertNotNil(fixture.model.draftConflict)
        XCTAssertEqual(fixture.model.drafts["postform"]?["message"], ["local change"])
        await fixture.model.resolveDraftConflict(useLocal: false)
        XCTAssertEqual(fixture.model.drafts["postform"]?["message"], ["server after"])
        XCTAssertNotEqual(fixture.model.composerDraft?.current?.id, saved.id)
        let remaining = await fixture.store.drafts(accountUID: "1")
        XCTAssertEqual(remaining.first?.source, "local change")
    }

    func testOfflineRestoreAllowsLocalEditsButNeverSends() async throws {
        let fixture = try await pageFixture()
        fixture.model.drafts["postform"]?["message"] = ["offline draft"]
        _ = await fixture.model.flushLocalDraft(force: true)
        let saved = try XCTUnwrap(fixture.model.composerDraft?.current)
        await fixture.repository.setFetchFailure(true)
        await fixture.model.restoreDraft(saved)
        XCTAssertTrue(fixture.model.isOfflineDraft)
        let form = try XCTUnwrap(fixture.model.page?.forms.first)
        fixture.model.drafts[form.id]?["offline-message"] = ["edited offline"]
        _ = await fixture.model.flushLocalDraft()
        fixture.model.prepareSubmission(form: form, button: .init(id: "publish", title: "Publish"))
        XCTAssertNil(fixture.model.pendingSubmission)
        XCTAssertEqual(fixture.model.composerDraft?.current?.source, "edited offline")
        let count = await fixture.repository.submissionCount
        XCTAssertEqual(count, 0)
        await fixture.repository.setFetchFailure(false)
        let edited = try XCTUnwrap(fixture.model.composerDraft?.current)
        await fixture.model.restoreDraft(edited)
        XCTAssertFalse(fixture.model.isOfflineDraft)
        XCTAssertEqual(fixture.model.drafts["postform"]?["message"], ["edited offline"])
    }

    func testSubmissionUncertaintyKeepsDraftAndConfirmedPublishDeletesOnlySnapshot() async throws {
        let fixture = try await pageFixture()
        let form = fixture.model.page!.forms[0], button = fixture.model.page!.forms[0].buttons[0]
        fixture.model.drafts[form.id]?["message"] = ["retain after timeout"]
        _ = await fixture.model.flushLocalDraft(force: true)
        await fixture.repository.setSubmissionAccepted(false)
        fixture.model.prepareSubmission(form: form, button: button)
        await fixture.model.confirmSubmission()
        XCTAssertFalse(fixture.model.submissionSucceeded)
        let kept = await fixture.store.drafts(accountUID: "1")
        XCTAssertEqual(kept.count, 1)
        await fixture.repository.setSubmissionAccepted(true)
        fixture.model.prepareSubmission(form: form, button: button)
        await fixture.model.confirmSubmission()
        XCTAssertTrue(fixture.model.submissionSucceeded)
        let remaining = await fixture.store.drafts(accountUID: "1")
        XCTAssertTrue(remaining.isEmpty)
        let count = await fixture.repository.submissionCount
        XCTAssertEqual(count, 2)
    }

    func testManualServerDraftDoesNotDismissOrDeleteLocalDraft() async throws {
        let fixture = try await pageFixture()
        let form = fixture.model.page!.forms[0]
        fixture.model.drafts[form.id]?["message"] = ["server draft"]
        _ = await fixture.model.flushLocalDraft(force: true)
        fixture.model.prepareSubmission(form: form, button: form.buttons[1])
        await fixture.model.confirmSubmission()
        XCTAssertFalse(fixture.model.submissionSucceeded)
        XCTAssertTrue(fixture.model.composerDraft?.current?.serverDraftSaved == true)
        let remaining = await fixture.store.drafts(accountUID: "1")
        XCTAssertEqual(remaining.first?.source, "server draft")
    }

    func testUploadCompletesAtMovingAnchorAndRetainsResourceForRestart() async throws {
        let fixture = try await pageFixture()
        let model = fixture.model, form = fixture.model.page!.forms[0]
        model.drafts[form.id]?["message"] = ["abcd"]
        let registry = ForumEditorRegistry()
        let controller = registry.controller(for: "message")
        let view = ForumBBCodeTextView(usingTextLayoutManager: true)
        controller.usesBBCodeDocument = true; controller.view = view
        controller.bbcodeSession.attach(view)
        controller.bbcodeSession.onSourceChange = { model.drafts[form.id]?["message"] = [$0] }
        controller.bbcodeSession.load("abcd", force: true)
        model.connectEditors(registry)
        view.selectedRange = NSRange(location: 2, length: 0)
        await fixture.repository.holdUpload()
        let task = Task { await model.upload(file: .init(name: "test.jpg", data: Data([1, 2, 3])), mimeType: "image/jpeg", configuration: draftUpload, form: form, editor: controller.bbcodeSession) }
        await fixture.repository.waitForUpload()
        controller.bbcodeSession.perform(.replaceSource(.init(location: 0), "前"))
        await fixture.repository.releaseUpload()
        await task.value
        XCTAssertEqual(model.drafts[form.id]?["message"], ["前ab[attachimg]10[/attachimg]cd"])
        XCTAssertTrue(model.composerAssets.first?.inserted == true)
        XCTAssertNotNil(model.composerAssets.first?.resourceID)
        _ = await model.flushLocalDraft()
        let saved = await fixture.store.drafts(accountUID: "1")
        XCTAssertEqual(saved.first?.attachments.first?.uploadID, "10")
    }

    func testFailedPendingUploadBlocksSubmissionUntilExplicitlyRemoved() async throws {
        let fixture = try await pageFixture()
        let form = fixture.model.page!.forms[0]
        fixture.model.drafts[form.id]?["message"] = ["body"]
        await fixture.repository.setUploadFailure(true)
        await fixture.model.upload(file: .init(name: "test.jpg", data: Data([1])), mimeType: "image/jpeg", configuration: draftUpload, form: form)
        fixture.model.prepareSubmission(form: form, button: form.buttons[0])
        XCTAssertNil(fixture.model.pendingSubmission)
        let id = try XCTUnwrap(fixture.model.composerAssets.first?.id)
        XCTAssertNotNil(fixture.model.assetFailures[id])
        await fixture.model.removeAsset(id, form: form)
        fixture.model.prepareSubmission(form: form, button: form.buttons[0])
        XCTAssertNotNil(fixture.model.pendingSubmission)
    }

    func testAccountChangeRejectsLateUploadWithoutModifyingNewAccount() async throws {
        let fixture = try await pageFixture()
        let form = fixture.model.page!.forms[0]
        fixture.model.drafts[form.id]?["message"] = ["old account"]
        await fixture.repository.holdUpload()
        let task = Task { await fixture.model.upload(file: .init(name: "file.jpg", data: Data([1])), mimeType: "image/jpeg", configuration: draftUpload, form: form) }
        await fixture.repository.waitForUpload()
        try await fixture.sessions.save(SessionState(cookie: "EeqY_2132_auth=two", isLoggedIn: true, accountUID: "2"))
        fixture.model.composerDraft?.invalidate()
        await fixture.repository.releaseUpload()
        await task.value
        XCTAssertTrue(fixture.model.attachments.isEmpty)
        XCTAssertTrue(fixture.model.drafts.isEmpty)
        let wrongAccount = await fixture.store.drafts(accountUID: "2")
        XCTAssertTrue(wrongAccount.isEmpty)
    }

    private func sessionStore() async throws -> SessionStore {
        let defaults = try YamiboTestDefaults.make(suiteName: YamiboTestDefaults.suiteName(prefix: "bbcode-draft"))
        let store = SessionStore(defaults: defaults, key: "session")
        try await store.save(SessionState(cookie: "EeqY_2132_auth=one", isLoggedIn: true, accountUID: "1"))
        return store
    }
    private func pageFixture(page: ForumPageDocument = draftPage()) async throws -> DraftPageFixture {
        let sessions = try await sessionStore(), store = ComposerDraftMemoryStore(), repository = ComposerDraftPageRepository(page)
        let model = ForumPageSession(url: page.url, repository: repository, sessionStore: sessions, draftStore: store)
        await model.load()
        return .init(model: model, store: store, sessions: sessions, repository: repository)
    }
}

private struct DraftPageFixture {
    let model: ForumPageSession
    let store: ComposerDraftMemoryStore
    let sessions: SessionStore
    let repository: ComposerDraftPageRepository
}

private let draftUpload = ForumUploadConfiguration(id: "image", url: URL(string: "https://bbs.yamibo.com/misc.php?mod=swfupload&operation=upload")!, kind: .threadImage, values: [], maximumBytes: 1000, extensions: ["jpg"])

private func draftPage(body: String = "", fieldSuffix: String = "", token: String = "old-token", target: ForumComposerTarget = .init(kind: .reply, threadID: "10")) -> ForumPageDocument {
    let url = target.editorURL!
    let form = ForumForm(id: "postform", title: "Post", actionURL: url, kind: .thread,
                         fields: [.init(id: "subject" + fieldSuffix, name: "subject", label: "Subject", initialValues: ["title"]),
                                  .init(id: "message" + fieldSuffix, name: "message", label: "Message", kind: .multiline, initialValues: [body], isRequired: true)],
                         hiddenValues: [.init(name: "formhash", value: token)],
                         buttons: [.init(id: "publish", title: "Publish"), .init(id: "save", title: "Save", values: [.init(name: "save", value: "1")])])
    return .init(url: url, title: "Post", forms: [form], uploads: [draftUpload], composerContext: .init(target: target, bbcode: .allowed))
}

private actor ComposerDraftMemoryStore: ForumComposerDraftPersisting {
    let identity = UUID()
    var values: [UUID: ForumComposerDraft] = [:]
    var deleted: Set<UUID> = []
    var writes: [ForumComposerDraft] = []
    var peakWriters = 0
    var inFlight = 0
    var fails = false
    var holdsSave = false
    var saveStarted = false
    var saveGate: CheckedContinuation<Void, Never>?
    var resources: [UUID: (String, ForumAttachmentFile)] = [:]
    var holdsResource = false
    var resourceStarted = false
    var resourceGate: CheckedContinuation<Void, Never>?
    func holdResourceImport() { holdsResource = true; resourceStarted = false }
    func waitForResourceImport() async { while !resourceStarted { await Task.yield() } }
    func releaseResourceImport() { resourceGate?.resume(); resourceGate = nil }
    func removeAllResources() { resources = [:] }
    func generation() -> UUID { identity }
    func drafts(accountUID: String) -> [ForumComposerDraft] { values.values.filter { $0.accountUID == accountUID }.sorted { $0.updatedAt > $1.updatedAt } }
    func holdNextSave() { holdsSave = true; saveStarted = false }
    func waitForSave() async { while !saveStarted { await Task.yield() } }
    func releaseSave() { saveGate?.resume(); saveGate = nil }
    func setSaveFailure(_ value: Bool) { fails = value }
    func save(_ draft: ForumComposerDraft, expecting revision: Int64?, generation: UUID) async throws {
        inFlight += 1; peakWriters = max(peakWriters, inFlight); defer { inFlight -= 1 }
        if holdsSave { holdsSave = false; saveStarted = true; await withCheckedContinuation { saveGate = $0 } }
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
        guard identity == generation, !deleted.contains(draft.id), values[draft.id]?.revision == revision else { throw ForumComposerDraftError.conflict }
        values[draft.id] = draft; writes.append(draft)
    }
    func delete(id: UUID, accountUID: String, expecting revision: Int64?, generation: UUID) throws -> Bool {
        if let old = values[id], old.accountUID != accountUID { throw ForumComposerDraftError.accountMismatch }
        if let revision, values[id]?.revision != revision { return false }
        values[id] = nil; deleted.insert(id); return true
    }
    func importResource(_ file: ForumAttachmentFile, draftID: UUID, accountUID: String, generation: UUID) async -> UUID {
        if holdsResource { holdsResource = false; resourceStarted = true; await withCheckedContinuation { resourceGate = $0 } }
        let id = UUID(); resources[id] = (accountUID, file); return id
    }
    func resource(id: UUID, accountUID: String) throws -> ForumAttachmentFile {
        guard let resource = resources[id], resource.0 == accountUID else { throw ForumComposerDraftError.missingResource }; return resource.1
    }
    func removeUnreferencedResources(draftID: UUID, accountUID: String, generation: UUID) {}
}

private actor ComposerDraftPageRepository: ForumPageLoading {
    var page: ForumPageDocument
    var failsFetch = false
    var accepted = true
    var failsUpload = false
    var holdsUpload = false
    var uploadStarted = false
    var uploadGate: CheckedContinuation<Void, Never>?
    var submissionCount = 0
    var uploadCount = 0
    init(_ page: ForumPageDocument) { self.page = page }
    func setPage(_ page: ForumPageDocument) { self.page = page }
    func setFetchFailure(_ value: Bool) { failsFetch = value }
    func setSubmissionAccepted(_ value: Bool) { accepted = value }
    func setUploadFailure(_ value: Bool) { failsUpload = value }
    func holdUpload() { holdsUpload = true; uploadStarted = false }
    func waitForUpload() async { while !uploadStarted { await Task.yield() } }
    func releaseUpload() { uploadGate?.resume(); uploadGate = nil }
    func fetchPage(url: URL, confirmedAction: Bool) throws -> ForumPageLoadResult { if failsFetch { throw URLError(.notConnectedToInternet) }; return .page(page) }
    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) -> ForumPageLoadResult {
        submissionCount += 1
        return .page(.init(url: page.url, title: "Result", message: accepted ? "发表成功" : "结果不明"))
    }
    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment {
        uploadCount += 1
        uploadStarted = true
        if holdsUpload { holdsUpload = false; await withCheckedContinuation { uploadGate = $0 } }
        if failsUpload { throw ForumPageError.uploadFailed }
        return .init(id: "10", name: file.name, markup: "[attachimg]10[/attachimg]", values: [])
    }
}
