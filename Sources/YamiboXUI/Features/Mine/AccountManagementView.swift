import Observation
import SwiftUI
import YamiboXCore

@MainActor
@Observable
final class AccountManagementViewModel {
    let switcher: AccountSwitchCoordinator
    var accounts: [SavedAccount] = []
    var isBusy = false
    var errorMessage: String?
    var errorDetails: LoadFailureDetails?
    var accountToLogin: SavedAccount?
    var isLoginPresented = false
    var verification: AccountVerificationSession?
    private var switchTask: Task<Void, Error>?

    init(switcher: AccountSwitchCoordinator) { self.switcher = switcher }

    func load() async {
        do { accounts = try await switcher.accounts() }
        catch { present(error) }
    }

    func select(_ account: SavedAccount) async -> Bool {
        guard !isBusy, !account.isCurrent || account.requiresLogin else { return false }
        if account.requiresLogin {
            accountToLogin = account
            isLoginPresented = true
            return false
        }
        isBusy = true
        let verification = AccountVerificationSession()
        self.verification = verification
        defer { isBusy = false; self.verification = nil; switchTask = nil }
        let task = Task {
            try await switcher.switchAccount(uid: account.id) { session in
                try await verification.verify(session)
            }
        }
        switchTask = task
        do {
            try await task.value
            await verification.close()
            return true
        } catch {
            await verification.close()
            if LoadDiagnosticError.classificationError(error) as? YamiboError == .notAuthenticated {
                accountToLogin = account
                isLoginPresented = true
            } else if !LoadDiagnosticError.isCancellation(error) { present(error) }
            await load()
            return false
        }
    }

    func cancel() {
        switchTask?.cancel()
        if let verification { Task { await verification.close() } }
    }

    func remove(_ account: SavedAccount) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { try await switcher.removeAccount(uid: account.id); await load() }
        catch { if !LoadDiagnosticError.isCancellation(error) { present(error) } }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        errorDetails = LoadFailureDetails(error: error)
    }
}

struct AccountManagementView: View {
    @State private var model: AccountManagementViewModel
    @State private var accountToRemove: SavedAccount?
    @Environment(\.dismiss) private var dismiss
    private let avatarLoader: YamiboProfileAvatarLoader

    init(switcher: AccountSwitchCoordinator) {
        model = AccountManagementViewModel(switcher: switcher)
        avatarLoader = YamiboProfileAvatarLoader(sessionStore: switcher.sessionStore)
    }

    var body: some View {
        List {
            Section {
                ForEach(model.accounts) { account in
                    Button {
                        Task { if await model.select(account) { dismiss() } }
                    } label: {
                        SavedAccountRow(account: account, avatarLoader: avatarLoader)
                    }
                    .disabled(model.isBusy)
                    .swipeActions(allowsFullSwipe: false) {
                        Button(role: .destructive) { accountToRemove = account } label: {
                            Label(L10n.string("account.remove"), systemImage: "trash")
                        }
                        .disabled(model.isBusy)
                    }
                }
            }
            Section {
                Button {
                    model.accountToLogin = nil
                    model.isLoginPresented = true
                } label: {
                    Label(L10n.string("account.add"), systemImage: "person.badge.plus")
                }
                .disabled(model.isBusy)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.string("account.switch"))
        .yamiboInlineNavigationTitleDisplayMode()
        .navigationBarBackButtonHidden(model.isBusy)
        .background {
            if let verification = model.verification {
                ForumWebSessionWebViewHost(coordinator: verification.coordinator, placement: .hidden)
                    .frame(width: 1, height: 1).opacity(0.001).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .overlay { if model.isBusy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) } }
        .task {
            let changes = model.switcher.sessionStore.changes()
            await model.load()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await model.load()
            }
        }
        .sheet(isPresented: $model.isLoginPresented, onDismiss: { Task { await model.load() } }) {
            AccountLoginSheet(switcher: model.switcher, account: model.accountToLogin) {
                model.isLoginPresented = false
                dismiss()
            } onCancel: {
                model.isLoginPresented = false
            }
        }
        .sheet(item: Binding(
            get: { model.verification?.coordinator.presentation },
            set: { if $0 == nil { model.verification?.coordinator.dismissPresentation() } }
        )) { _ in
            if let verification = model.verification { ForumWAFVerificationView(coordinator: verification.coordinator) }
        }
        .onDisappear { model.cancel() }
        .alert(L10n.string("account.remove"), isPresented: Binding(
            get: { accountToRemove != nil }, set: { if !$0 { accountToRemove = nil } }
        ), presenting: accountToRemove) { account in
            Button(L10n.string("account.remove"), role: .destructive) { Task { await model.remove(account) } }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: { account in
            Text(L10n.string(account.isCurrent ? "account.remove_current_confirmation" : "account.remove_confirmation"))
        }
        .failureAlert(
            L10n.string("common.operation_failed"), message: model.errorMessage, details: model.errorDetails,
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button(L10n.string("common.ok")) { model.errorMessage = nil }
        }
    }
}

@MainActor
final class AccountVerificationSession {
    let coordinator: ForumWebSessionCoordinator
    private let sessions: SessionStore
    private let profiles: YamiboProfileStore

    init() {
        let store = AccountStore.temporary()
        sessions = SessionStore(accountStore: store)
        profiles = YamiboProfileStore(accountStore: store)
        coordinator = ForumWebSessionCoordinator(sessionStore: sessions, websiteDataStore: .nonPersistent())
    }

    func verify(_ session: SessionState) async throws -> AuthenticatedAccount {
        try Task.checkCancellation()
        try await sessions.save(session)
        coordinator.setAppIsActive(true)
        let profile = try await YamiboAccountService.isolatedLoginService(
            sessionStore: sessions, profileStore: profiles, wafRecoverer: coordinator
        ).refreshProfile()
        try Task.checkCancellation()
        return AuthenticatedAccount(session: await sessions.load(), profile: profile)
    }

    func close() async { await coordinator.tearDown() }
}

private struct SavedAccountRow: View {
    let account: SavedAccount
    let avatarLoader: YamiboProfileAvatarLoader

    var body: some View {
        HStack(spacing: 12) {
            MineAvatarView(profile: account.profile, avatarLoader: avatarLoader, avatarReloadDate: account.profile.refreshedAt)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.profile.username).foregroundStyle(.primary)
                Text(verbatim: "UID \(account.id)").font(.caption).foregroundStyle(.secondary)
                if account.requiresLogin {
                    Text(L10n.string("account.requires_login")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if account.isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel(L10n.string("account.current"))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
