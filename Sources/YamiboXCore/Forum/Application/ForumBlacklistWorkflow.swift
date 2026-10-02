import Foundation
import Observation

@MainActor
@Observable
public final class ForumBlacklistWorkflow {
    public private(set) var entries: [ForumBlacklistEntry] = []
    public private(set) var blockedUIDs: Set<String> = []
    public private(set) var accountUID: String?
    public private(set) var isLoggedIn = false
    public private(set) var isRefreshing = false
    public private(set) var isWorking = false
    public private(set) var replyDisplay: ForumBlockedReplyDisplay = .placeholder

    @ObservationIgnored private let sessionStore: SessionStore
    @ObservationIgnored private let store: ForumBlacklistStore
    @ObservationIgnored private let makeRepository: @Sendable (AccountSessionSnapshot, Bool) -> any ForumBlacklistRemoteOperating
    @ObservationIgnored private var sessionGeneration: UUID?
    @ObservationIgnored private var authentication: String?
    @ObservationIgnored private var accountKey: String?
    @ObservationIgnored private var isAppActive = false
    @ObservationIgnored private var refreshID: UUID?
    @ObservationIgnored private var refreshTask: Task<Void, any Error>?
    @ObservationIgnored private var operationID: UUID?

    public nonisolated init(
        sessionStore: SessionStore,
        store: ForumBlacklistStore,
        makeRepository: @escaping @Sendable (AccountSessionSnapshot, Bool) -> any ForumBlacklistRemoteOperating
    ) {
        self.sessionStore = sessionStore
        self.store = store
        self.makeRepository = makeRepository
    }

    public func contains(_ uid: String?) -> Bool {
        guard let uid else { return false }
        return blockedUIDs.contains(uid.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func setReplyDisplay(_ display: ForumBlockedReplyDisplay) async throws {
        try await store.saveReplyDisplay(display)
        replyDisplay = display
    }

    public func appDidBecomeActive() async {
        isAppActive = true
        await refreshSilently()
    }

    public func appDidEnterBackground() {
        isAppActive = false
        cancelRefresh()
    }

    public func prepareForAccountChange() {
        invalidateSession()
    }

    public func finishAccountChange() {
        if isAppActive { Task { await refreshSilently() } }
    }

    public func reset() async {
        invalidateSession()
        await store.clearAll()
        replyDisplay = .placeholder
    }

    public func observeSessionChanges() async {
        let changes = sessionStore.changes()
        await sessionDidChange()
        for await _ in changes {
            guard !Task.isCancelled else { return }
            await sessionDidChange()
        }
    }

    public func refresh(interactive: Bool = true) async throws {
        guard interactive || isAppActive else { return }
        let snapshot = try await prepareSession(interactive: interactive)
        guard interactive || isAppActive else { return }
        guard !isWorking else { return }
        if let refreshTask {
            try await refreshTask.value
            return
        }
        let id = UUID()
        refreshID = id
        isRefreshing = true
        let repository = makeRepository(snapshot, interactive)
        let task = Task {
            let result = try await Self.fetchAll(repository)
            try await validate(snapshot)
            guard refreshID == id, let accountKey else { throw CancellationError() }
            try await store.save(result.entries, accountKey: accountKey)
            try await validate(snapshot)
            guard refreshID == id else { throw CancellationError() }
            apply(result.entries)
        }
        refreshTask = task
        defer {
            if refreshID == id {
                refreshTask = nil
                refreshID = nil
                isRefreshing = false
            }
        }
        try await task.value
    }

    public func setBlocked(_ blocked: Bool, uid: String) async throws {
        // Share the exclusive lease with account transitions. The client also
        // checks the snapshot before every request.
        try await sessionStore.accountOperations.run { [self] in
            try await changeBlockState(blocked, uid: uid)
        }
    }

    private func changeBlockState(_ blocked: Bool, uid: String) async throws {
        guard Int(uid).map({ $0 > 0 }) == true else {
            throw YamiboError.parsingFailed(context: L10n.string("blacklist.title"))
        }
        let snapshot = try await prepareSession(interactive: true)
        guard !isWorking else { return }
        guard uid != accountUID else { throw YamiboError.underlying(L10n.string("blacklist.cannot_block_self")) }
        cancelRefresh()
        let id = UUID()
        operationID = id
        isWorking = true
        defer {
            if operationID == id {
                operationID = nil
                isWorking = false
            }
        }

        let repository = makeRepository(snapshot, true)
        let current = try await Self.fetchAll(repository)
        try await validate(snapshot)
        guard operationID == id else { throw CancellationError() }
        let entry = current.entries.first { $0.uid == uid }
        if blocked, entry == nil {
            let profile = try await repository.fetchUser(uid: uid)
            try await validate(snapshot)
            guard operationID == id, profile.uid == uid, uid != accountUID else { throw CancellationError() }
            try await repository.add(username: profile.username, formHash: current.formHash)
        } else if !blocked, let entry {
            try await repository.remove(entry)
        }

        // Discuz's general action parser accepts plain confirmation text.
        // Verify membership so an unfamiliar error page cannot report success.
        let updated = try await Self.fetchAll(repository)
        try await validate(snapshot)
        guard operationID == id, let accountKey else { throw CancellationError() }
        guard updated.entries.contains(where: { $0.uid == uid }) == blocked else {
            throw YamiboError.underlying(L10n.string("blacklist.verification_failed"))
        }
        try await store.save(updated.entries, accountKey: accountKey)
        try await validate(snapshot)
        guard operationID == id else { throw CancellationError() }
        apply(updated.entries)
    }

    private func prepareSession(interactive: Bool) async throws -> AccountSessionSnapshot {
        let snapshot = try await sessionStore.snapshot()
        guard await sessionStore.isCurrentGeneration(snapshot.generation) else { throw CancellationError() }
        let session = snapshot.session
        let nextAuthentication = session.isLoggedIn ? session.authenticationCookie?.value : nil
        if sessionGeneration != snapshot.generation || authentication != nextAuthentication
            || (session.accountUID != nil && accountUID != nil && session.accountUID != accountUID) {
            invalidateSession()
            sessionGeneration = snapshot.generation
            authentication = nextAuthentication
            isLoggedIn = nextAuthentication != nil
        }
        replyDisplay = await store.replyDisplay()
        try await validate(snapshot)
        guard nextAuthentication != nil else { throw YamiboError.notAuthenticated }
        var uid = session.accountUID ?? accountUID
        if uid == nil {
            uid = try await makeRepository(snapshot, interactive).fetchUser(uid: nil).uid
            try await validate(snapshot)
        }
        guard let uid, Int(uid).map({ $0 > 0 }) == true else {
            throw YamiboError.parsingFailed(context: L10n.string("blacklist.title"))
        }
        let key = "\(YamiboDomain.baseURL.absoluteString)#\(uid)"
        if accountKey != key {
            let cached = await store.entries(accountKey: key)
            try await validate(snapshot)
            if accountKey != key {
                accountUID = uid
                accountKey = key
                apply(cached)
            }
        }
        return snapshot
    }

    private func validate(_ snapshot: AccountSessionSnapshot) async throws {
        try Task.checkCancellation()
        guard sessionGeneration == snapshot.generation,
              authentication == (snapshot.session.isLoggedIn ? snapshot.session.authenticationCookie?.value : nil),
              await sessionStore.isCurrentGeneration(snapshot.generation) else { throw CancellationError() }
    }

    private func sessionDidChange() async {
        let snapshot = try? await sessionStore.snapshot()
        guard !Task.isCancelled else { return }
        let nextAuthentication = snapshot?.session.isLoggedIn == true ? snapshot?.session.authenticationCookie?.value : nil
        let changed = sessionGeneration != snapshot?.generation || authentication != nextAuthentication
            || (snapshot?.session.accountUID != nil && accountUID != nil && snapshot?.session.accountUID != accountUID)
        if changed {
            invalidateSession()
            sessionGeneration = snapshot?.generation
            authentication = nextAuthentication
            isLoggedIn = nextAuthentication != nil
            // Do not hold up logout observation while a network request runs.
            if isAppActive { Task { await refreshSilently() } }
        }
    }

    private func refreshSilently() async {
        do { try await refresh(interactive: false) }
        catch {
            if !LoadDiagnosticError.isCancellation(error),
               LoadDiagnosticError.classificationError(error) as? YamiboError != .notAuthenticated {
                YamiboLog.forum.warning("Blacklist synchronization failed: \(error.localizedDescription)")
            }
        }
    }

    private func apply(_ entries: [ForumBlacklistEntry]) {
        self.entries = entries
        blockedUIDs = Set(entries.map(\.uid))
    }

    private func invalidateSession() {
        cancelRefresh()
        operationID = nil
        isWorking = false
        isLoggedIn = false
        sessionGeneration = nil
        authentication = nil
        accountUID = nil
        accountKey = nil
        apply([])
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        isRefreshing = false
    }

    private static func fetchAll(_ repository: any ForumBlacklistRemoteOperating) async throws -> (entries: [ForumBlacklistEntry], formHash: String) {
        var entries: [ForumBlacklistEntry] = []
        var seen = Set<String>()
        var page = 1
        var totalPages = 1
        var formHash = ""
        repeat {
            try Task.checkCancellation()
            let result = try await repository.fetchPage(page: page)
            let current = result.navigation?.currentPage ?? 1
            let total = result.navigation?.totalPages ?? 1
            guard current == page, total >= page, total <= 10_000 else {
                throw YamiboError.parsingFailed(context: L10n.string("blacklist.title"))
            }
            // A list changing during pagination must be retried, not cached as
            // complete after a missing or duplicated page.
            if page > 1, total != totalPages {
                throw YamiboError.underlying(L10n.string("blacklist.list_changed"))
            }
            totalPages = total
            if page == 1 { formHash = result.formHash }
            for entry in result.entries {
                guard seen.insert(entry.uid).inserted else {
                    throw YamiboError.underlying(L10n.string("blacklist.list_changed"))
                }
                entries.append(entry)
            }
            if totalPages > 1, result.entries.isEmpty {
                throw YamiboError.parsingFailed(context: L10n.string("blacklist.title"))
            }
            page += 1
        } while page <= totalPages
        return (entries, formHash)
    }
}
