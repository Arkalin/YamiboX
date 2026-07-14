import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class MineHomeViewModel {
    var session = SessionState()
    var profile: YamiboProfile?
    var errorMessage: String?
    var isLoading = false
    var isRefreshingProfile = false
    var isLoggingIn = false
    var isSigningOut = false
    var isCheckingIn = false
    var hasCheckedInToday = false
    var checkInResultMessage: String?

    let offlineQueue: OfflineCacheQueueViewModel
    let loginQuestions = YamiboLoginQuestion.defaultQuestions
    @ObservationIgnored let profileAvatarLoader: YamiboProfileAvatarLoader

    private let dependencies: AccountDependencies
    @ObservationIgnored private let checkInService: any YamiboCheckInServicing
    @ObservationIgnored private var lastAutomaticProfileRefreshCredential: String?

    init(
        dependencies: AccountDependencies,
        offlineCacheQueueController: (any OfflineCacheQueueControlling)? = nil,
        checkInService: (any YamiboCheckInServicing)? = nil
    ) {
        self.dependencies = dependencies
        self.checkInService = checkInService ?? dependencies.makeCheckInService()
        offlineQueue = OfflineCacheQueueViewModel(
            dependencies: dependencies,
            controller: offlineCacheQueueController
        )
        profileAvatarLoader = YamiboProfileAvatarLoader(sessionStore: dependencies.sessionStore)
    }

    var isLoggedIn: Bool {
        session.isLoggedIn && SessionState.hasAuthenticationCookie(session.cookie)
    }

    var isBusy: Bool {
        isLoading || isLoggingIn || isSigningOut || isCheckingIn
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        session = await dependencies.sessionStore.load()
        profile = await dependencies.profileStore.load()
        await refreshCheckInState()
        await offlineQueue.load()

        guard isLoggedIn,
              let credential = SessionState.authenticationCookieValue(in: session.cookie) else {
            lastAutomaticProfileRefreshCredential = nil
            return
        }
        guard lastAutomaticProfileRefreshCredential != credential else { return }
        guard canAttemptAutomaticProfileRefresh else { return }

        lastAutomaticProfileRefreshCredential = credential
        await refreshProfile(presentsErrors: profile == nil)
    }

    private var canAttemptAutomaticProfileRefresh: Bool {
        guard profile != nil else { return true }
        guard let accountUID = session.accountUID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountUID.isEmpty else {
            return false
        }
        return true
    }

    func refreshProfile() async {
        await refreshProfile(presentsErrors: true)
    }

    func login(username: String, password: String, questionID: String, answer: String) async -> Bool {
        guard !isLoggingIn else { return false }
        isLoggingIn = true
        defer { isLoggingIn = false }

        do {
            profile = try await dependencies.makeAccountService().login(
                YamiboLoginRequest(
                    username: username,
                    password: password,
                    questionID: questionID,
                    answer: answer
                )
            )
            session = await dependencies.sessionStore.load()
            await refreshCheckInState()
            errorMessage = nil
            checkInResultMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }

        do {
            try await dependencies.makeAccountService().signOut()
            session = await dependencies.sessionStore.load()
            profile = await dependencies.profileStore.load()
            lastAutomaticProfileRefreshCredential = nil
            hasCheckedInToday = false
            errorMessage = nil
            checkInResultMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkIn() async {
        guard !isCheckingIn else { return }
        guard !hasCheckedInToday else {
            checkInResultMessage = YamiboCheckInResult.alreadyCheckedInToday.message
            errorMessage = nil
            return
        }
        isCheckingIn = true
        defer { isCheckingIn = false }

        let result = await checkInService.checkInIfNeeded(force: false)
        checkInResultMessage = nil
        switch result {
        case .success:
            hasCheckedInToday = true
            checkInResultMessage = result.message
            errorMessage = nil
            await refreshProfile(presentsErrors: false)
        case .alreadyCheckedInToday, .skippedToday:
            hasCheckedInToday = true
            checkInResultMessage = YamiboCheckInResult.alreadyCheckedInToday.message
            errorMessage = nil
        case .notAuthenticated:
            hasCheckedInToday = false
            errorMessage = result.message
        case .parseFailed, .verificationFailed, .networkFailed:
            errorMessage = result.message
        }
    }

    private func refreshCheckInState() async {
        guard isLoggedIn else {
            hasCheckedInToday = false
            return
        }
        hasCheckedInToday = !(await dependencies.checkInStore.needsCheckIn(session: session))
    }

    private func refreshProfile(presentsErrors: Bool) async {
        guard isLoggedIn, !isRefreshingProfile else { return }
        isRefreshingProfile = true
        defer { isRefreshingProfile = false }

        do {
            profile = try await dependencies.makeAccountService().refreshProfile()
            session = await dependencies.sessionStore.load()
            errorMessage = nil
        } catch YamiboError.notAuthenticated {
            do {
                try await dependencies.makeAccountService().clearLocalAuthentication()
            } catch {
                YamiboLog.account.error("Failed to clear local authentication after server reported notAuthenticated: \(error)")
            }
            session = await dependencies.sessionStore.load()
            profile = await dependencies.profileStore.load()
            await refreshCheckInState()
            if presentsErrors {
                errorMessage = YamiboError.notAuthenticated.localizedDescription
            }
        } catch {
            if presentsErrors {
                errorMessage = error.localizedDescription
            }
        }
    }
}
