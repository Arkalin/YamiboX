import Foundation

public struct SavedAccount: Identifiable, Equatable, Sendable {
    public var id: String { profile.uid }
    public let profile: YamiboProfile
    public let lastUsedAt: Date
    public let isCurrent: Bool
    public let requiresLogin: Bool
}

public struct AccountSessionSnapshot: Sendable {
    public let session: SessionState
    public let generation: UUID
}

public struct AuthenticatedAccount: Sendable {
    public let session: SessionState
    public let profile: YamiboProfile

    public init(session: SessionState, profile: YamiboProfile) {
        self.session = session
        self.profile = profile
    }
}

public enum AccountSwitchError: Error, LocalizedError, Equatable {
    case busy
    case accountMissing
    case identityMismatch
    case secureStorage(Int32)

    public var errorDescription: String? {
        switch self {
        case .busy: L10n.string("account.error.busy")
        case .accountMissing: L10n.string("account.error.missing")
        case .identityMismatch: L10n.string("account.error.identity_mismatch")
        case .secureStorage: L10n.string("account.error.secure_storage")
        }
    }
}
