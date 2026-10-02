import Foundation

/// The sync service and runtime observations are projections of the same registration.
struct AppWebDAVDataset: Sendable {
    let participant: any WebDAVSyncParticipant
    let changeID: String
    let changes: @Sendable () -> AsyncStream<String>
}

extension YamiboAppContext {
    @MainActor
    package func makeRuntimeCoordinator(continuity: AppContinuityWorkflow) -> AppRuntimeCoordinator {
        AppRuntimeCoordinator(
            observations: webDAVDatasets.map { dataset in
                .init(
                    changeID: dataset.changeID,
                    changes: dataset.changes,
                    onChange: { continuity.localDataChanged(datasetID: dataset.participant.datasetID) }
                )
            },
            operations: [
                { [browsingHistoryWorkflow] in await browsingHistoryWorkflow.observeChanges() },
                { [messageUnreadWorkflow] in await messageUnreadWorkflow.observeSessionChanges() },
                { [blacklistWorkflow] in await blacklistWorkflow.observeSessionChanges() },
            ],
            actions: .init(
                synchronizeForeground: { continuity.foregroundBecameActive() },
                refreshUnread: { [messageUnreadWorkflow, blacklistWorkflow] in
                    async let unread: Void = messageUnreadWorkflow.appDidBecomeActive()
                    async let blacklist: Void = blacklistWorkflow.appDidBecomeActive()
                    _ = await (unread, blacklist)
                },
                invalidateUnread: { [messageUnreadWorkflow, blacklistWorkflow] in
                    messageUnreadWorkflow.appDidEnterBackground()
                    blacklistWorkflow.appDidEnterBackground()
                },
                synchronizeBackground: { continuity.willEnterBackground() }
            )
        )
    }
}
