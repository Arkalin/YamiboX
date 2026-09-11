import Foundation
import Observation
import YamiboXCore

protocol ForumComposerDraftPersisting: Sendable {
    func generation() async throws -> UUID
    func drafts(accountUID: String) async throws -> [ForumComposerDraft]
    func save(_ draft: ForumComposerDraft, expecting revision: Int64?, generation: UUID) async throws
    func delete(id: UUID, accountUID: String, expecting revision: Int64?, generation: UUID) async throws -> Bool
    func importResource(_ file: ForumAttachmentFile, draftID: UUID, accountUID: String, generation: UUID) async throws -> UUID
    func resource(id: UUID, accountUID: String) async throws -> ForumAttachmentFile
    func removeUnreferencedResources(draftID: UUID, accountUID: String, generation: UUID) async throws
}
extension ForumComposerDraftStore: ForumComposerDraftPersisting {}

@MainActor
@Observable
final class ForumComposerDraftCoordinator {
    enum Status: Equatable { case idle, saving, saved(Date), failed(String), unavailable }
    private(set) var status = Status.idle
    private(set) var current: ForumComposerDraft?
    private(set) var available: [ForumComposerDraft] = []
    private(set) var active = false
    private(set) var changeID: UInt64 = 0
    @ObservationIgnored private(set) var savedRevision: Int64?
    @ObservationIgnored private var savedChangeID: UInt64 = 0
    @ObservationIgnored private let store: any ForumComposerDraftPersisting
    @ObservationIgnored let sessionStore: SessionStore
    @ObservationIgnored private var accountGeneration: UUID?
    @ObservationIgnored private var databaseGeneration: UUID?
    @ObservationIgnored private var lifecycleID = UUID()
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Bool, Never>?
    @ObservationIgnored private var writerID: UUID?
    @ObservationIgnored private var resourceImports = 0
    @ObservationIgnored var onCommitEditing: (() -> Void)?
    @ObservationIgnored var onInvalidated: (() -> Void)?
    private final class WeakEntry { weak var value: ForumComposerDraftCoordinator?; init(_ value: ForumComposerDraftCoordinator) { self.value = value } }
    private static var instances: [WeakEntry] = []

    init(store: any ForumComposerDraftPersisting, sessionStore: SessionStore) {
        self.store = store; self.sessionStore = sessionStore
        Self.instances.removeAll { $0.value == nil }
        Self.instances.append(WeakEntry(self))
    }

    var statusText: String? {
        switch status {
        case .idle: nil
        case .saving: L10n.string("forum.composer.draft_saving")
        case .saved: L10n.string("forum.composer.draft_saved")
        case .failed: L10n.string("forum.composer.draft_save_failed")
        case .unavailable: L10n.string("forum.composer.draft_unavailable")
        }
    }

    func start(form: ForumForm, context: ForumComposerContext, restoring draft: ForumComposerDraft? = nil) async {
        guard form.kind == .thread else { return }
        debounce?.cancel()
        while let writer { _ = await writer.value }
        let identity = UUID(); lifecycleID = identity
        do {
            let snapshot = try await sessionStore.snapshot()
            guard snapshot.session.hasValidAuthenticationCookie, let uid = snapshot.session.accountUID, (Int(uid) ?? 0) > 0 else {
                active = false; current = nil; available = []; status = .unavailable; return
            }
            if let draft, draft.accountUID != uid { throw ForumComposerDraftError.accountMismatch }
            let generation = try await store.generation()
            guard lifecycleID == identity, await sessionStore.isCurrentGeneration(snapshot.generation) else { return }
            current = draft ?? ForumComposerDraft(accountUID: uid, target: context.target,
                                                  fields: ForumComposerDraftFields.snapshot(form: form, values: form.initialValues),
                                                  baseline: ForumComposerDraft.fingerprint(form: form))
            databaseGeneration = generation; accountGeneration = snapshot.generation
            savedRevision = draft?.revision
            changeID = 0; savedChangeID = 0
            active = true
            status = draft.map { .saved($0.updatedAt) } ?? .idle
            await reloadList()
        } catch { active = false; status = .failed(error.localizedDescription) }
    }

    func update(form: ForumForm, values: [String: [String]], sourceMode: Bool? = nil, selection: ForumComposerSelection? = nil,
                attachments: [ForumComposerDraftAttachment]? = nil, retainingMissingFields: Bool = false) {
        guard active, var draft = current else { return }
        let before = draft
        let fields = ForumComposerDraftFields.snapshot(form: form, values: values)
        draft.fields = retainingMissingFields ? draft.fields.merging(fields, uniquingKeysWith: { _, new in new }) : fields
        if let sourceMode { draft.sourceMode = sourceMode }
        if let selection { draft.selection = selection }
        if let attachments { draft.attachments = attachments }
        guard draft != before else { return }
        draft.updatedAt = .now
        current = draft
        changeID &+= 1
        status = .saving
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            _ = await self.flush()
        }
    }

    @discardableResult
    func flush(allowTransition: Bool = false, force: Bool = false) async -> Bool {
        debounce?.cancel(); debounce = nil
        while let writer { _ = await writer.value }
        guard active, current != nil else { return false }
        if changeID == savedChangeID && !(force && savedRevision == nil) { return true }
        let identity = lifecycleID
        let id = UUID()
        writerID = id
        let task = Task { [weak self] in
            guard let self else { return false }
            let result = await writePending(identity: identity, allowTransition: allowTransition, force: force)
            if writerID == id { writer = nil; writerID = nil }
            return result
        }
        writer = task
        return await task.value
    }

    private func writePending(identity: UUID, allowTransition: Bool, force: Bool) async -> Bool {
        repeat {
            guard active, lifecycleID == identity, var draft = current, let generation = databaseGeneration else { return false }
            let expected = savedRevision
            let capturedChange = changeID
            guard capturedChange != savedChangeID || force && expected == nil else { return true }
            do {
                try await checkAccount(allowTransition: allowTransition)
                guard lifecycleID == identity else { return false }
                draft.revision = (expected ?? 0) + 1
                draft.updatedAt = .now
                status = .saving
                try await store.save(draft, expecting: expected, generation: generation)
                guard lifecycleID == identity, current?.id == draft.id else { return false }
                savedRevision = draft.revision
                savedChangeID = capturedChange
                current?.revision = draft.revision
                status = changeID == capturedChange ? .saved(draft.updatedAt) : .saving
            } catch {
                if lifecycleID == identity { status = .failed(error.localizedDescription) }
                return false
            }
        } while changeID != savedChangeID
        return true
    }

    func reloadList() async {
        do {
            try await checkAccount()
            guard let uid = current?.accountUID else { return }
            let identity = lifecycleID
            let drafts = try await store.drafts(accountUID: uid)
            try await checkAccount()
            guard lifecycleID == identity else { return }
            available = drafts
        } catch { available = []; if active { status = .failed(error.localizedDescription) } }
    }

    func delete(_ draft: ForumComposerDraft) async -> Bool {
        let identity = lifecycleID
        do {
            try await checkAccount()
            guard let current, draft.accountUID == current.accountUID, let generation = databaseGeneration else { return false }
            if draft.id == current.id {
                debounce?.cancel()
                if let writer { _ = await writer.value }
            }
            try await checkAccount()
            guard lifecycleID == identity else { return false }
            let expected = draft.id == current.id ? savedRevision : draft.revision
            let deleted = try await store.delete(id: draft.id, accountUID: draft.accountUID, expecting: expected, generation: generation)
            guard lifecycleID == identity else { return false }
            guard deleted else { throw ForumComposerDraftError.conflict }
            if draft.id == self.current?.id {
                lifecycleID = UUID(); active = false; self.current = nil; savedRevision = nil; status = .idle
            }
            available.removeAll { $0.id == draft.id }
            return true
        } catch { if lifecycleID == identity { status = .failed(error.localizedDescription) }; return false }
    }

    func removeSubmitted(id: UUID, changeID: UInt64, serverDraft: Bool) async {
        guard current?.id == id, self.changeID == changeID else { return }
        if serverDraft {
            current?.serverDraftSaved = true
            self.changeID &+= 1
            _ = await flush(force: true)
        } else if let draft = current {
            _ = await delete(draft)
        }
    }

    func importResource(_ file: ForumAttachmentFile) async throws -> UUID {
        resourceImports += 1
        defer { resourceImports -= 1 }
        try await checkAccount()
        guard let draft = current, let generation = databaseGeneration else { throw ForumComposerDraftError.invalidDraft }
        let identity = lifecycleID
        let id = try await store.importResource(file, draftID: draft.id, accountUID: draft.accountUID, generation: generation)
        try await checkAccount()
        guard lifecycleID == identity else { throw ForumComposerDraftError.deleted }
        return id
    }

    func resource(_ id: UUID) async throws -> ForumAttachmentFile {
        try await checkAccount()
        guard let uid = current?.accountUID else { throw ForumComposerDraftError.accountMismatch }
        let identity = lifecycleID
        let file = try await store.resource(id: id, accountUID: uid)
        try await checkAccount()
        guard lifecycleID == identity else { throw ForumComposerDraftError.accountMismatch }
        return file
    }

    func cleanResources() async {
        guard await flush(), resourceImports == 0, let draft = current, let generation = databaseGeneration else { return }
        try? await store.removeUnreferencedResources(draftID: draft.id, accountUID: draft.accountUID, generation: generation)
    }

    func checkAccount(allowTransition: Bool = false) async throws {
        guard active, let uid = current?.accountUID, let accountGeneration else { throw ForumComposerDraftError.accountMismatch }
        let snapshot = try await sessionStore.snapshot()
        let isCurrent = if allowTransition { true } else { await sessionStore.isCurrentGeneration(accountGeneration) }
        guard snapshot.session.accountUID == uid, snapshot.session.hasValidAuthenticationCookie,
              isCurrent, allowTransition || snapshot.generation == accountGeneration else {
            throw ForumComposerDraftError.accountMismatch
        }
    }

    func observeIdentity() async {
        for await _ in sessionStore.changes() {
            guard !Task.isCancelled else { return }
            guard active else { continue }
            do { try await checkAccount() }
            catch { invalidate() }
        }
    }

    func invalidate() {
        debounce?.cancel(); debounce = nil
        lifecycleID = UUID(); active = false; available = []; current = nil
        status = .unavailable
        onInvalidated?()
    }

    static func prepareForAccountChange(sessionStore: SessionStore) async throws {
        instances.removeAll { $0.value == nil }
        for instance in instances.compactMap(\.value) where instance.sessionStore === sessionStore && instance.active {
            instance.onCommitEditing?()
            guard await instance.flush(allowTransition: true) else {
                throw YamiboError.underlying(L10n.string("forum.composer.draft_save_failed"))
            }
        }
    }

    static func finishAccountChange(sessionStore: SessionStore) {
        for instance in instances.compactMap(\.value) where instance.sessionStore === sessionStore { instance.invalidate() }
    }
}
