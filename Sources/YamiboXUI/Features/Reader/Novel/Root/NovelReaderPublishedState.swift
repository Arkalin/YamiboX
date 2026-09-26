import Observation
import YamiboXCore

/// One committed UI snapshot, with independent observation for each projection.
/// A position update must not invalidate readers of unchanged settings/structure.
@MainActor
final class NovelReaderPublishedState: Observable {
    private struct Snapshot {
        var presentation: NovelReaderPresentation?
        var structure: NovelReaderPresentationStructure?
        var progress = NovelReaderChromeProgressSnapshot.empty
        var resumePoint: NovelResumePoint?

        var settings: NovelReaderAppearanceSettings? { presentation?.committedSettings }
    }

    private let registrar = ObservationRegistrar()
    private var snapshot = Snapshot()

    var presentation: NovelReaderPresentation? {
        registrar.access(self, keyPath: \.presentation)
        return snapshot.presentation
    }

    var structure: NovelReaderPresentationStructure? {
        registrar.access(self, keyPath: \.structure)
        return snapshot.structure
    }

    var progress: NovelReaderChromeProgressSnapshot {
        registrar.access(self, keyPath: \.progress)
        return snapshot.progress
    }

    var settings: NovelReaderAppearanceSettings? {
        registrar.access(self, keyPath: \.settings)
        return snapshot.settings
    }

    var resumePoint: NovelResumePoint? {
        registrar.access(self, keyPath: \.resumePoint)
        return snapshot.resumePoint
    }

    /// Loading, navigation, layout/settings changes and close all publish here.
    func publish(_ state: NovelReadingWorkflowState?, cache: NovelReaderPresentationCache) {
        var next = Snapshot()
        if let state, let presentation = state.presentation {
            next.presentation = presentation
            next.structure = state.presentationStructure
            next.resumePoint = state.resumePoint
            if let structure = next.structure {
                next.progress = cache.progress(presentation: presentation, structure: structure)
            } else {
                cache.clear()
            }
        } else {
            cache.clear()
        }

        // Nest notifications around a single replacement: every willSet sees
        // the complete old snapshot, and every didSet sees the complete new one.
        // Tracking the backing struct itself would invalidate all projections.
        withChange(of: \.presentation, to: next.presentation) {
            withChange(of: \.structure, to: next.structure) {
                withChange(of: \.progress, to: next.progress) {
                    withChange(of: \.settings, to: next.settings) {
                        withChange(of: \.resumePoint, to: next.resumePoint) {
                            snapshot = next
                        }
                    }
                }
            }
        }
    }

    private func withChange<Value: Equatable>(
        of keyPath: KeyPath<NovelReaderPublishedState, Value>,
        to value: Value,
        _ mutation: () -> Void
    ) {
        if self[keyPath: keyPath] == value {
            mutation()
        } else {
            registrar.withMutation(of: self, keyPath: keyPath, mutation)
        }
    }
}
