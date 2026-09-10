import Foundation
import Observation
import SwiftUI
import WebKit
import YamiboXCore

@MainActor
@Observable
final class AccountLoginViewModel {
    let sessionStore: SessionStore
    let profileStore: YamiboProfileStore
    let webCoordinator: ForumWebSessionCoordinator
    let initialUsername: String
    let loginQuestions = YamiboLoginQuestion.defaultQuestions
    private let switcher: AccountSwitchCoordinator
    private let expectedUID: String?
    private let verifyWebProfile: (@MainActor () async throws -> YamiboProfile)?
    private var lease: UUID?
    private var isClosed = false
    private var work: Task<Bool, Never>?
    var isReady = false
    var isLoggingIn = false
    var errorMessage: String?
    var errorDetails: LoadFailureDetails?

    init(switcher: AccountSwitchCoordinator, account: SavedAccount? = nil,
         verifyWebProfile: (@MainActor () async throws -> YamiboProfile)? = nil) {
        self.switcher = switcher
        self.verifyWebProfile = verifyWebProfile
        expectedUID = account?.id
        initialUsername = account?.profile.username ?? ""
        let store = AccountStore.temporary()
        sessionStore = SessionStore(accountStore: store)
        profileStore = YamiboProfileStore(accountStore: store)
        webCoordinator = ForumWebSessionCoordinator(sessionStore: sessionStore, websiteDataStore: .nonPersistent())
    }

    func prepare() async {
        guard lease == nil, !isClosed else { return }
        do {
            let token = try await switcher.sessionStore.accountOperations.acquire()
            guard !isClosed, !Task.isCancelled else {
                await switcher.sessionStore.accountOperations.release(token)
                return
            }
            lease = token
            webCoordinator.setAppIsActive(true)
            isReady = true
        } catch { present(error) }
    }

    func login(username: String, password: String, questionID: String, answer: String) async -> Bool {
        await run {
            await self.resetCandidate()
            let service = self.makeService()
            let profile = try await service.login(YamiboLoginRequest(
                username: username, password: password, questionID: questionID, answer: answer
            ))
            return try await self.commit(profile)
        }
    }

    func finishWebLogin() async -> Bool {
        guard await sessionStore.load().hasValidAuthenticationCookie else { return false }
        return await run {
            let profile: YamiboProfile
            if let verify = self.verifyWebProfile { profile = try await verify() }
            else { profile = try await self.makeService().refreshProfile() }
            return try await self.commit(profile)
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Bool) async -> Bool {
        guard isReady, !isLoggingIn, !isClosed else { return false }
        isLoggingIn = true
        defer { isLoggingIn = false; work = nil }
        errorMessage = nil
        errorDetails = nil
        let task = Task {
            do { return try await operation() }
            catch {
                if !self.isClosed, !LoadDiagnosticError.isCancellation(error) {
                    self.present(error)
                    await self.resetCandidate()
                }
                return false
            }
        }
        work = task
        return await task.value
    }

    private func makeService() -> YamiboAccountService {
        .isolatedLoginService(sessionStore: sessionStore, profileStore: profileStore, wafRecoverer: webCoordinator)
    }

    private func commit(_ profile: YamiboProfile) async throws -> Bool {
        guard !isClosed, let lease else { throw CancellationError() }
        let session = try await sessionStore.snapshot().session
        try await switcher.activateLogin(session: session, profile: profile, expectedUID: expectedUID, lease: lease)
        return true
    }

    private func resetCandidate() async {
        await webCoordinator.prepareForAccountChange()
        try? await sessionStore.reset()
        await webCoordinator.finishAccountChange(SessionState())
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        errorDetails = LoadFailureDetails(error: error)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        work?.cancel()
        let pending = work
        let token = lease
        lease = nil
        isReady = false
        Task {
            await webCoordinator.tearDown()
            _ = await pending?.value
            if let token { await switcher.sessionStore.accountOperations.release(token) }
        }
    }
}

struct AccountLoginSheet: View {
    @State private var model: AccountLoginViewModel
    @State private var isWebLoginPresented = false
    let onSuccess: () -> Void
    let onCancel: () -> Void

    init(switcher: AccountSwitchCoordinator, account: SavedAccount? = nil, onSuccess: @escaping () -> Void, onCancel: @escaping () -> Void) {
        model = AccountLoginViewModel(switcher: switcher, account: account)
        self.onSuccess = onSuccess
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            List {
                AccountLoginForm(viewModel: model, onWebLogin: { isWebLoginPresented = true }, onLoginSuccess: complete)
                    .disabled(!model.isReady || model.isLoggingIn)
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(0)
            .navigationTitle(L10n.string("mine.login"))
            .yamiboInlineNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel")) { model.close(); onCancel() }
                        .disabled(model.isLoggingIn)
                }
            }
            .failureAlert(
                L10n.string("common.operation_failed"), message: model.errorMessage, details: model.errorDetails,
                isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button(L10n.string("common.ok")) { model.errorMessage = nil }
            }
        }
        .interactiveDismissDisabled(model.isLoggingIn)
        .task { await model.prepare() }
        .onDisappear { model.close() }
        .sheet(isPresented: $isWebLoginPresented, onDismiss: {
            Task { if await model.finishWebLogin() { complete() } }
        }) {
            NavigationStack {
                ForumWebSessionWebViewHost(coordinator: model.webCoordinator, placement: .visible)
                    .navigationTitle(L10n.string("mine.web_login"))
                    .yamiboInlineNavigationTitleDisplayMode()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.string("common.close")) { isWebLoginPresented = false }
                        }
                    }
            }
            .task {
                await model.webCoordinator.openLoginPage()
                let monitor = MineWebLoginSessionMonitor(sessionStore: model.sessionStore)
                if await monitor.waitForAuthentication(), !Task.isCancelled { isWebLoginPresented = false }
            }
        }
        .sheet(item: Binding(
            get: { isWebLoginPresented ? nil : model.webCoordinator.presentation },
            set: { if $0 == nil { model.webCoordinator.dismissPresentation() } }
        )) { _ in
            ForumWAFVerificationView(coordinator: model.webCoordinator)
        }
    }

    private func complete() {
        model.close()
        onSuccess()
    }
}
