public enum FavoriteAddSyncDecision: Equatable, Sendable {
    case prompt
    case silent(syncToRemote: Bool)

    public static func resolve(settings: FavoriteLibrarySettings, canSyncRemote: Bool) -> FavoriteAddSyncDecision {
        guard canSyncRemote else { return .silent(syncToRemote: false) }
        return settings.addSyncPromptEnabled ? .prompt : .silent(syncToRemote: settings.addSyncDefault)
    }
}

public enum FavoriteRemoveRemoteDecision: Equatable, Sendable {
    case prompt
    case silent(removeRemote: Bool)

    public static func resolve(settings: FavoriteLibrarySettings, canRemoveRemote: Bool) -> FavoriteRemoveRemoteDecision {
        guard canRemoveRemote else { return .silent(removeRemote: false) }
        return settings.removeRemotePromptEnabled ? .prompt : .silent(removeRemote: settings.removeRemoteDefault)
    }
}

public extension FavoriteItem {
    func favorite(type: FavoriteType) -> Favorite {
        guard let threadID = target.threadID else {
            preconditionFailure("Thread favorite conversion requires thread target")
        }
        return Favorite(
            id: id,
            title: title,
            displayName: displayName,
            threadID: threadID,
            remoteFavoriteID: remoteMapping?.yamiboFavoriteID,
            type: type,
            tagIDs: tagIDs
        )
    }
}
