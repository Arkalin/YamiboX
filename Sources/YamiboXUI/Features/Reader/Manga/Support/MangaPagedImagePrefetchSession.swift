import YamiboXCore

/// Each viewport owns a session; loader replacement and teardown share one policy.
@MainActor
final class MangaPagedImagePrefetchSession {
    private var loader: MangaReaderPageImageLoader
    private var coordinator: ReaderImagePrefetchCoordinator
    private var sources: [YamiboImageSource] = []
    private var isStopped = false

    init(loader: MangaReaderPageImageLoader) {
        self.loader = loader
        coordinator = loader.makePrefetchCoordinator()
    }

    func update(plan: MangaPagedReadingPlan, loader: MangaReaderPageImageLoader) {
        guard !isStopped else { return }
        if self.loader !== loader {
            coordinator.cancel()
            self.loader = loader
            coordinator = loader.makePrefetchCoordinator()
            sources = []
        }
        let nextSources = loader.imageSources(for: MangaPagedImagePrefetchPlan.pagesToPrefetch(plan: plan))
        guard nextSources != sources else { return }
        sources = nextSources
        coordinator.update(sources: nextSources)
    }

    func stop() {
        isStopped = true
        coordinator.cancel()
        sources = []
    }
}
