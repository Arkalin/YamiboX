import YamiboXCore

/// Pending remote-deletion question, owned by the presenting interface.
struct FavoriteRemovePrompt: Identifiable, Equatable, Sendable {
    let favorite: Favorite
    var id: String { favorite.threadID }
}

extension FavoriteCommands.AddResult {
    var feedback: TransientFeedback {
        if case .failed = remote {
            return .failure(remote.addFeedbackMessage, details: failureDetails)
        }
        return TransientFeedback(message: remote.addFeedbackMessage)
    }
}

extension FavoriteCommands.RemotePushResult {
    var addFeedbackMessage: String {
        switch self {
        case .notAttempted:
            L10n.string("favorites.quick.added_local")
        case .synced:
            L10n.string("favorites.quick.added_synced")
        case .syncedWithoutMapping:
            L10n.string("favorites.quick.added_synced_pending")
        case let .failed(reason):
            L10n.string("favorites.quick.added_sync_failed", reason)
        }
    }
}
