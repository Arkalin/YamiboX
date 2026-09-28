import Foundation

/// Registered in execution order. A failure stops the sequence and retains the
/// original error; reset never bypasses a store's own persistence operation.
struct AppDataResetStep: Sendable {
    let id: String
    let perform: @Sendable () async throws -> Void

    init(_ id: String, perform: @escaping @Sendable () async throws -> Void) {
        self.id = id
        self.perform = perform
    }
}

struct AppDataResetWorkflow: Sendable {
    let sessionStore: SessionStore
    let profileStore: YamiboProfileStore
    let transition: AccountTransitionWorkflow
    let webDataCleanup: AccountTransitionWorkflow.WebDataCleanup
    let steps: [AppDataResetStep]

    func run() async throws {
        try await sessionStore.accountOperations.run {
            try await transition.run(webDataCleanup: webDataCleanup) { token in
                try await sessionStore.resetAllAccounts(token: token)
                if sessionStore.accountStore == nil { await profileStore.clear() }
                for step in steps {
                    do { try await step.perform() }
                    catch {
                        YamiboLog.persistence.error("Application reset failed at \(step.id, privacy: .public): \(error)")
                        throw error
                    }
                }
            }
        }
    }
}
