import Foundation

extension YamiboAppContext {
    @MainActor
    package func makeRuntimeCoordinator(continuity: AppContinuityWorkflow) -> AppRuntimeCoordinator {
        AppRuntimeCoordinator(
            observations: [
                .init(
                    changeID: mangaDirectoryStore.changeID,
                    changes: { [mangaDirectoryStore] in mangaDirectoryStore.changes() },
                    onChange: { continuity.localDataChanged() }
                ),
                .init(
                    changeID: browsingHistoryStore.changeID,
                    changes: { [browsingHistoryStore] in browsingHistoryStore.changes() },
                    onChange: { continuity.localDataChanged() }
                ),
                .init(
                    changeID: localFavoriteLibraryStore.changeID,
                    changes: { [localFavoriteLibraryStore] in localFavoriteLibraryStore.changes() },
                    onChange: { continuity.localDataChanged() }
                ),
                .init(
                    changeID: settingsStore.changeID,
                    changes: { [settingsStore] in settingsStore.changes() },
                    onChange: { continuity.localDataChanged(touchesAppSettings: true) }
                ),
                .init(
                    changeID: readingProgressStore.changeID,
                    changes: { [readingProgressStore] in readingProgressStore.changes() },
                    onChange: { continuity.localDataChanged() }
                ),
                .init(
                    changeID: contentCoverStore.changeID,
                    changes: { [contentCoverStore] in contentCoverStore.changes() },
                    onChange: { continuity.localDataChanged() }
                ),
            ],
            operations: [
                { [browsingHistoryWorkflow] in await browsingHistoryWorkflow.observeChanges() },
                { [messageUnreadWorkflow] in await messageUnreadWorkflow.observeSessionChanges() },
            ],
            actions: .init(
                synchronizeForeground: { continuity.foregroundBecameActive() },
                refreshUnread: { [messageUnreadWorkflow] in await messageUnreadWorkflow.appDidBecomeActive() },
                invalidateUnread: { [messageUnreadWorkflow] in messageUnreadWorkflow.appDidEnterBackground() },
                synchronizeBackground: { continuity.willEnterBackground() }
            )
        )
    }
}
