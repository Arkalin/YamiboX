import Foundation
import Observation

@MainActor
@Observable
public final class MessageUnreadWorkflow {
    public private(set) var summary: MessageUnreadSummary?
    public var totalCount: Int { summary?.totalCount ?? 0 }
    public var hasUnreadMessages: Bool { totalCount > 0 }

    @ObservationIgnored private let sessionStore: SessionStore
    @ObservationIgnored private let makeRepository: @Sendable (SessionState) -> any MessageUnreadLoading
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var isAppActive = false
    @ObservationIgnored private var authentication: String?
    @ObservationIgnored private var accountUID: String?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var needsFollowup = false

    public nonisolated init(
        sessionStore: SessionStore,
        makeRepository: @escaping @Sendable (SessionState) -> any MessageUnreadLoading,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.sessionStore = sessionStore
        self.makeRepository = makeRepository
        self.now = now
    }

    public func appDidBecomeActive() async {
        isAppActive = true
        await refresh()
    }

    public func appDidEnterBackground() {
        isAppActive = false
        if requestTask != nil { lastAttempt = nil }
        invalidateRequest()
    }

    public func prepareForAccountChange() {
        summary = nil
        lastAttempt = nil
        invalidateRequest()
    }

    public func finishAccountChange() {
        if isAppActive { Task { await refresh(force: true) } }
    }

    public func refresh(force: Bool = false) async {
        let session = await sessionStore.load()
        guard !Task.isCancelled else { return }
        updateSession(session)
        guard isAppActive, authentication != nil else { return }
        if let requestTask {
            await requestTask.value
            return
        }
        if !force, let lastAttempt, now().timeIntervalSince(lastAttempt) < 30 { return }

        let id = UUID()
        requestID = id
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRefresh(id: id)
        }
        requestTask = task
        await task.value
    }

    /// Invalidate immediately, before the async refresh can yield. Multiple
    /// read completions during a probe collapse into one follow-up request.
    @discardableResult
    public func refreshAfterReading() -> Task<Void, Never> {
        generation += 1
        needsFollowup = true
        return Task { await refresh(force: true) }
    }

    public func observeSessionChanges() async {
        let changes = sessionStore.changes()
        await sessionDidChange()
        for await _ in changes {
            guard !Task.isCancelled else { return }
            await sessionDidChange()
        }
    }

    private func sessionDidChange() async {
        let changed = updateSession(await sessionStore.load())
        if changed, isAppActive {
            // Do not hold up the change stream while the network is slow;
            // sign-out must be able to invalidate the in-flight response.
            Task { await refresh() }
        }
    }

    private func runRefresh(id: UUID) async {
        defer {
            if requestID == id {
                requestID = nil
                requestTask = nil
                needsFollowup = false
            }
        }
        repeat {
            guard requestID == id, isAppActive, !Task.isCancelled else { return }
            needsFollowup = false
            guard let snapshot = try? await sessionStore.snapshot(),
                  await sessionStore.isCurrentGeneration(snapshot.generation) else { return }
            let session = snapshot.session
            guard requestID == id, isAppActive, !Task.isCancelled else { return }
            if updateSession(session) {
                Task { await refresh() }
                return
            }
            guard requestID == id, isAppActive, !Task.isCancelled else { return }
            let requestGeneration = generation
            lastAttempt = now()

            let result: Result<MessageUnreadSummary, any Error>
            do {
                result = .success(try await makeRepository(session).fetchUnreadSummary())
            } catch {
                result = .failure(error)
            }

            // Validate against the store too, even if its change observer
            // has not yet handled a concurrent logout or account switch.
            guard requestID == id, isAppActive, !Task.isCancelled else { return }
            guard await sessionStore.isCurrentGeneration(snapshot.generation) else { return }
            let currentSession = await sessionStore.load()
            guard requestID == id, isAppActive, !Task.isCancelled else { return }
            if updateSession(currentSession) {
                Task { await refresh() }
                return
            }
            guard requestID == id, isAppActive, !Task.isCancelled else { return }
            if requestGeneration == generation {
                switch result {
                case let .success(summary):
                    self.summary = summary
                case let .failure(error):
                    if (LoadDiagnosticError.classificationError(error) as? YamiboError) == .notAuthenticated {
                        summary = nil
                    } else if !LoadDiagnosticError.isCancellation(error) {
                        YamiboLog.forum.warning("Silent unread check failed: \(error.localizedDescription)")
                    }
                }
            }
        } while needsFollowup
    }

    @discardableResult
    private func updateSession(_ session: SessionState) -> Bool {
        let nextAuthentication = session.isLoggedIn ? session.authenticationCookie?.value : nil
        let nextUID = session.accountUID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let accountChanged = accountUID != nil && nextUID != nil && accountUID != nextUID
        guard authentication != nextAuthentication || accountChanged else {
            if nextAuthentication != nil, let nextUID { accountUID = nextUID }
            return false
        }
        authentication = nextAuthentication
        accountUID = nextAuthentication == nil ? nil : nextUID
        summary = nil
        lastAttempt = nil
        invalidateRequest()
        return true
    }

    private func invalidateRequest() {
        generation += 1
        requestTask?.cancel()
        requestTask = nil
        requestID = nil
        needsFollowup = false
    }
}
