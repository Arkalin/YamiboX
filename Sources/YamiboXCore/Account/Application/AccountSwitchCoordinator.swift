import Foundation

public struct AccountSwitchCoordinator: Sendable {
    typealias Transition = @Sendable (@escaping @Sendable (UUID) async throws -> Void) async throws -> Void

    public let sessionStore: SessionStore
    private let profileStore: YamiboProfileStore
    private let makeService: @Sendable () -> YamiboAccountService
    private let transition: Transition

    init(
        sessionStore: SessionStore,
        profileStore: YamiboProfileStore,
        makeService: @escaping @Sendable () -> YamiboAccountService,
        transition: @escaping Transition
    ) {
        self.sessionStore = sessionStore
        self.profileStore = profileStore
        self.makeService = makeService
        self.transition = transition
    }

    public func accounts() async throws -> [SavedAccount] {
        try await sessionStore.accountStore?.accounts() ?? []
    }

    public func switchAccount(
        uid: String,
        verify: (@Sendable (SessionState) async throws -> AuthenticatedAccount)? = nil
    ) async throws {
        try await sessionStore.accountOperations.run {
            let current = try await sessionStore.snapshot()
            if current.session.accountUID == uid, current.session.hasValidAuthenticationCookie { return }
            guard let store = sessionStore.accountStore else { throw AccountSwitchError.accountMissing }
            guard let saved = try await store.savedSession(uid: uid), saved.hasValidAuthenticationCookie else {
                try await store.invalidate(uid: uid)
                throw YamiboError.notAuthenticated
            }
            let verified: AuthenticatedAccount
            do {
                if let verify { verified = try await verify(saved) }
                else { verified = AuthenticatedAccount(session: saved, profile: try await makeService().verifySession(saved)) }
            } catch {
                if LoadDiagnosticError.classificationError(error) as? YamiboError == .notAuthenticated {
                    try await store.invalidate(uid: uid)
                }
                throw error
            }
            guard verified.profile.uid == uid, verified.session.accountUID == uid else { throw AccountSwitchError.identityMismatch }
            try Task.checkCancellation()
            try await activate(session: verified.session, profile: verified.profile)
        }
    }

    public func activateLogin(session: SessionState, profile: YamiboProfile, expectedUID: String?, lease: UUID) async throws {
        try await sessionStore.accountOperations.checkOwner(lease)
        if let expectedUID, profile.uid != expectedUID { throw AccountSwitchError.identityMismatch }
        guard !profile.uid.isEmpty, session.accountUID == profile.uid else { throw AccountSwitchError.identityMismatch }
        try Task.checkCancellation()
        try await activate(session: session, profile: profile)
    }

    private func activate(session: SessionState, profile: YamiboProfile) async throws {
        try await transition { token in
            try await sessionStore.commitAccount(session, profile: profile, token: token)
            if sessionStore.accountStore == nil { try await profileStore.save(profile) }
        }
    }

    public func removeAccount(uid: String) async throws {
        try await sessionStore.accountOperations.run {
            let session = try await sessionStore.snapshot().session
            if session.accountUID == uid {
                try await signOutWithinOperation(removesAccount: true)
            } else {
                try await sessionStore.accountStore?.remove(uid: uid)
            }
        }
    }

    public func signOut() async throws {
        try await sessionStore.accountOperations.run {
            try await signOutWithinOperation(removesAccount: true)
        }
    }

    func invalidateCurrent(expectedGeneration: UUID?) async throws {
        try await sessionStore.accountOperations.run {
            if let expectedGeneration, !(await sessionStore.isCurrentGeneration(expectedGeneration)) {
                throw CancellationError()
            }
            try await signOutWithinOperation(removesAccount: false)
        }
    }

    private func signOutWithinOperation(removesAccount: Bool) async throws {
        try await transition { token in
            // Local persistence must succeed before attempting a server logout.
            let old = await sessionStore.load()
            let profile = await profileStore.load()
            try await sessionStore.commitSignOut(token: token, removesAccount: removesAccount)
            if sessionStore.accountStore == nil { await profileStore.clear() }
            if removesAccount { await makeService().requestServerSignOut(session: old, profile: profile) }
        }
    }
}

/// UI-owned web views and sync sessions join the Core transition without Core importing WebKit.
public actor AccountTransitionLifecycle {
    private var prepare: (@MainActor @Sendable () async throws -> Void)?
    private var finish: (@MainActor @Sendable (SessionState) async -> Void)?
    private var publish: (@MainActor @Sendable () -> Void)?

    public func configure(
        prepare: @escaping @MainActor @Sendable () async throws -> Void,
        finish: @escaping @MainActor @Sendable (SessionState) async -> Void,
        publish: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.prepare = prepare
        self.finish = finish
        self.publish = publish
    }

    func willChange() async throws { try await prepare?() }
    func didChange(_ session: SessionState) async { await finish?(session) }
    func didPublish() async { await publish?() }
}
