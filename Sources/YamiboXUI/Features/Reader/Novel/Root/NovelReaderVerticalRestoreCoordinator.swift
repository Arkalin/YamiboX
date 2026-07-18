import Observation
import SwiftUI
import YamiboXCore
import UIKit

/// Owns the vertical reading-position restore state machine that previously
/// lived as seven pieces of `@State` (plus ~360 lines of methods) directly on
/// `NovelReaderView`. Moving it here keeps the polling tasks, retry counters
/// and fingerprint bookkeeping out of the view value type, where every stray
/// copy of the struct made the ownership of the two long-lived `Task` handles
/// hard to reason about.
///
/// Design constraints, chosen to keep behavior byte-for-byte equivalent to the
/// old in-view implementation:
///
/// - `model` (`NovelReaderViewModel`) and the `NovelReaderVerticalScrollCoordinator`
///   are passed as method parameters instead of being injected in `init`.
///   `NovelReaderView` re-initializes on every parent render, and only the
///   first `@State` value survives — injecting the view model here in `init`
///   would wire a freshly built (immediately discarded) instance into the
///   retained coordinator. Parameter passing sidesteps that lifecycle
///   question entirely (each call hands over the retained instances the view
///   resolves at call time) and guarantees the coordinator can never retain
///   the view or outlive its collaborators' intended lifetimes.
/// - The class is `@MainActor`, exactly like the SwiftUI `View` the code came
///   from (the `View` protocol is main-actor isolated), so `Task {}` blocks
///   created here inherit the same actor context as before and the
///   `await MainActor.run` hops inside them keep their original structure.
@MainActor
@Observable
final class NovelReaderVerticalRestoreCoordinator {
    /// Consumed by `body` (handed to `NovelReaderVerticalViewportScrollView`),
    /// so writes must invalidate the view the same way the old `@State` did —
    /// tracked (was `@Published` before the `@Observable` migration).
    private(set) var verticalScrollRequest: NovelReaderVerticalScrollRequest?
    /// `shouldConcealViewportContent` drives the loading overlay in `body`;
    /// tracking the whole struct mirrors the old `@State`/`@Published`
    /// invalidation behavior (every phase mutation writes the struct back).
    private(set) var verticalRestoreController = ReaderVerticalRestoreController()

    // The remaining fields are pure internal sequencing state: nothing in
    // `body` reads them, so they were never `@Published` and stay
    // unobserved (`@ObservationIgnored`) to keep the notification surface
    // identical. The two task handles must also stay ignored because the
    // nonisolated `deinit` cancels them — the macro would otherwise turn
    // them into main-actor computed properties unreachable from `deinit`.
    @ObservationIgnored private var verticalScrollRequestCommandID: UInt64 = 0
    @ObservationIgnored private var verticalRestoreRetryTask: Task<Void, Never>?
    @ObservationIgnored private var verticalViewportPositionUpdateTask: Task<Void, Never>?
    /// Reference-type box (never triggered view updates as `@State` either);
    /// mutated from the viewport's deferred callbacks.
    private let verticalViewportSampling = NovelReaderVerticalViewportSamplingBox()
    @ObservationIgnored private var lastVerticalPositioningFingerprint: NovelReaderVerticalPositioningFingerprint?

    /// The view's `onDisappear` cancels explicitly (see
    /// `cancelPendingRestoreWork`), matching the old code path; deinit is a
    /// safety net for teardown orders where SwiftUI destroys the state object
    /// without a final `onDisappear`. Cancelling an already-cancelled or
    /// finished task is a no-op, so this can only ever stop work earlier,
    /// never change results.
    deinit {
        verticalRestoreRetryTask?.cancel()
        verticalViewportPositionUpdateTask?.cancel()
    }

    // MARK: - View lifecycle support

    /// Called from `NovelReaderView`'s `onDisappear`. Deliberately only
    /// cancels (does not nil the handles), exactly like the original
    /// `onDisappear` body did.
    func cancelPendingRestoreWork() {
        verticalRestoreRetryTask?.cancel()
        verticalViewportPositionUpdateTask?.cancel()
    }

    // MARK: - Viewport callback entry points
    // These are the bodies of the closures `NovelReaderView.verticalContent`
    // passes to `NovelReaderVerticalViewportScrollView`, moved verbatim; the
    // view now forwards into them so the sampling box can live here.

    /// Body of the old `onScrollRequestHandled` closure.
    func handleScrollRequestHandled(
        _ request: NovelReaderVerticalScrollRequest,
        model: NovelReaderViewModel,
        scrollCoordinator: NovelReaderVerticalScrollCoordinator
    ) {
        guard verticalRestoreController.scrollingRequest == request else {
            if verticalScrollRequest == request {
                verticalScrollRequest = nil
            }
            return
        }
        verticalScrollRequest = nil
        if request.textAnchor != nil {
            verticalRestoreController.beginSettling(request, now: CACurrentMediaTime())
            verticalRestoreRetryTask?.cancel()
            verticalRestoreRetryTask = nil
            return
        }
        tryAdvanceVerticalRestore(model: model, scrollCoordinator: scrollCoordinator)
    }

    /// Body of the old `onSurfaceFramesChange` closure.
    func handleSurfaceFramesChange(
        _ frames: [Int: NovelReaderVerticalSurfaceFrameValue],
        model: NovelReaderViewModel,
        scrollCoordinator: NovelReaderVerticalScrollCoordinator
    ) {
        guard verticalViewportSampling.surfaceFrames != frames else { return }
        verticalViewportSampling.surfaceFrames = frames
        tryAdvanceVerticalRestore(model: model, scrollCoordinator: scrollCoordinator)
        applyVerticalViewportPositionUpdate(for: .viewportGeometryChanged, model: model)
    }

    /// Body of the old `onTextViewportSampleChange` closure.
    func handleTextViewportSampleChange(
        _ sample: NovelTextViewportSample?,
        model: NovelReaderViewModel
    ) {
        guard verticalViewportSampling.textViewportSample != sample else { return }
        verticalViewportSampling.textViewportSample = sample
        applyVerticalViewportPositionUpdate(for: .textViewportSampleChanged, model: model)
    }

    // MARK: - Fingerprint bookkeeping

    /// The tail of the old `updateChromeForContentState()`: everything after
    /// the chrome-state mutation dealt exclusively with the positioning
    /// fingerprint, so it moved here as one block to preserve the early-return
    /// order exactly.
    func synchronizePositioningFingerprintWithContentState(model: NovelReaderViewModel) {
        if model.isLoading && model.novelReaderSurfaces.isEmpty {
            lastVerticalPositioningFingerprint = nil
            return
        }

        if model.errorMessage != nil && model.novelReaderSurfaces.isEmpty {
            lastVerticalPositioningFingerprint = nil
            return
        }

        guard !model.novelReaderSurfaces.isEmpty else {
            lastVerticalPositioningFingerprint = nil
            return
        }

        if currentVerticalPositioningFingerprint(model: model) == nil {
            lastVerticalPositioningFingerprint = nil
        }
    }

    /// Was a computed property on the view; a method here because it needs
    /// the model handed in.
    private func currentVerticalPositioningFingerprint(
        model: NovelReaderViewModel
    ) -> NovelReaderVerticalPositioningFingerprint? {
        guard model.settings.readingMode == .vertical,
              !model.novelReaderSurfaces.isEmpty,
              let generation = model.novelReaderPresentation?.generation else {
            return nil
        }
        return NovelReaderVerticalPositioningFingerprint(
            generation: generation,
            view: model.visibleView,
            surfaceCount: model.novelReaderSurfaces.count,
            surfaceIndex: model.selectedSurfaceIndex,
            intraSurfaceProgressBucket: Int((model.currentSurfaceIntraProgress * 1000).rounded()),
            readingMode: model.settings.readingMode
        )
    }

    // MARK: - Vertical position persistence and restore

    private func rememberCurrentVerticalPositioningFingerprint(model: NovelReaderViewModel) {
        lastVerticalPositioningFingerprint = currentVerticalPositioningFingerprint(model: model)
    }

    func restoreVerticalPositionIfNeeded(
        model: NovelReaderViewModel,
        scrollCoordinator: NovelReaderVerticalScrollCoordinator
    ) {
        guard let fingerprint = currentVerticalPositioningFingerprint(model: model) else {
            lastVerticalPositioningFingerprint = nil
            return
        }
        guard lastVerticalPositioningFingerprint != fingerprint else { return }
        lastVerticalPositioningFingerprint = fingerprint
        requestVerticalScrollToCurrentPage(model: model, scrollCoordinator: scrollCoordinator)
    }

    private func makeVerticalScrollRequest(model: NovelReaderViewModel) -> NovelReaderVerticalScrollRequest {
        let resumePoint = model.currentNovelResumePoint
        let textAnchor = resumePoint?.view == model.visibleView
            ? resumePoint.map(NovelReaderVerticalTextAnchor.init(position:))
            : nil
        verticalScrollRequestCommandID &+= 1
        let request = NovelReaderVerticalScrollRequest(
            commandID: verticalScrollRequestCommandID,
            view: model.visibleView,
            surfaceIndex: model.selectedSurfaceIndex,
            intraSurfaceProgress: model.currentSurfaceIntraProgress,
            textAnchor: textAnchor
        )
        return request
    }

    private func requestVerticalScrollToCurrentPage(
        model: NovelReaderViewModel,
        scrollCoordinator: NovelReaderVerticalScrollCoordinator
    ) {
        let request = makeVerticalScrollRequest(model: model)
        beginVerticalRestoreScrolling(for: request)
        verticalScrollRequest = request
        scheduleVerticalRestoreRetry(for: request, model: model, scrollCoordinator: scrollCoordinator)
    }

    func updateVerticalViewportPosition(model: NovelReaderViewModel) {
        guard model.settings.readingMode == .vertical else { return }
        guard verticalRestoreController.canSampleViewport(now: CACurrentMediaTime()) else {
            return
        }

        if let sample = verticalViewportSampling.textViewportSample {
            model.updateVerticalViewportPosition(sample: sample)
            rememberCurrentVerticalPositioningFingerprint(model: model)
        }
    }

    func applyVerticalViewportPositionUpdate(
        for trigger: NovelReaderVerticalViewportPositionUpdateTiming.Trigger,
        model: NovelReaderViewModel
    ) {
        switch NovelReaderVerticalViewportPositionUpdateTiming.updateMode(for: trigger) {
        case .immediate:
            verticalViewportPositionUpdateTask?.cancel()
            verticalViewportPositionUpdateTask = nil
            updateVerticalViewportPosition(model: model)
        case .deferred:
            scheduleVerticalViewportPositionUpdate(model: model)
        }
    }

    private func scheduleVerticalViewportPositionUpdate(model: NovelReaderViewModel) {
        verticalViewportPositionUpdateTask?.cancel()
        verticalViewportPositionUpdateTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.updateVerticalViewportPosition(model: model)
                self.verticalViewportPositionUpdateTask = nil
            }
        }
    }

    private func applyVerticalFineTune(
        for request: NovelReaderVerticalScrollRequest,
        model: NovelReaderViewModel,
        scrollCoordinator: NovelReaderVerticalScrollCoordinator
    ) {
        guard verticalRestoreController.scrollingRequest == request else {
            return
        }
        guard request.view == nil || request.view == model.visibleView else {
            return
        }
        if request.textAnchor != nil {
            return
        }
        guard let frame = currentVerticalSurfaceFrames(model: model)[request.surfaceIndex] else {
            return
        }
        verticalRestoreController.beginFineTuning(request)
        guard scrollCoordinator.restoreOffset(
            to: frame,
            intraSurfaceProgress: request.intraSurfaceProgress
        ) else {
            verticalRestoreController.beginScrolling(to: request)
            return
        }
        verticalRestoreController.beginSettling(request, now: CACurrentMediaTime())
        verticalRestoreRetryTask?.cancel()
        verticalRestoreRetryTask = nil
    }

    func tryAdvanceVerticalRestore(
        model: NovelReaderViewModel,
        scrollCoordinator: NovelReaderVerticalScrollCoordinator
    ) {
        refreshVerticalRestorePhase()
        guard let request = verticalRestoreController.scrollingRequest else { return }
        guard request.view == nil || request.view == model.visibleView else {
            return
        }
        guard scrollCoordinator.hasAttachedScrollView else {
            return
        }
        let frames = currentVerticalSurfaceFrames(model: model)
        guard let frame = frames[request.surfaceIndex] else {
            return
        }
        guard frame.height > 0 else {
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1))
            self.applyVerticalFineTune(for: request, model: model, scrollCoordinator: scrollCoordinator)
        }
    }

    func syncVerticalViewportBeforeSave(
        model: NovelReaderViewModel,
        scrollCoordinator: NovelReaderVerticalScrollCoordinator
    ) {
        guard model.settings.readingMode == .vertical else { return }
        tryAdvanceVerticalRestore(model: model, scrollCoordinator: scrollCoordinator)
        guard verticalRestoreController.canSampleViewport(now: CACurrentMediaTime()) else {
            return
        }
        updateVerticalViewportPosition(model: model)
    }

    private func beginVerticalRestoreScrolling(for request: NovelReaderVerticalScrollRequest) {
        verticalRestoreController.beginScrolling(to: request)
    }

    private func currentVerticalSurfaceFrames(model: NovelReaderViewModel) -> [Int: CGRect] {
        verticalViewportSampling.surfaceFrames.compactMapValues { value in
            value.documentView == model.visibleView ? value.frame : nil
        }
    }

    private func refreshVerticalRestorePhase(now: CFTimeInterval = CACurrentMediaTime()) {
        verticalRestoreController.refresh(now: now)
    }

    func cancelVerticalRestoreForUserScroll() {
        guard verticalRestoreController.activeRequest != nil else { return }
        verticalRestoreController.cancel(now: CACurrentMediaTime())
        verticalScrollRequest = nil
        verticalRestoreRetryTask?.cancel()
        verticalRestoreRetryTask = nil
    }

    private func reissueVerticalScrollRequest(_ request: NovelReaderVerticalScrollRequest) {
        guard verticalRestoreController.scrollingRequest == request else { return }
        verticalScrollRequest = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1))
            guard self.verticalRestoreController.scrollingRequest == request else { return }
            self.verticalScrollRequest = request
        }
    }

    /// Fixed 10 x 80ms poll: layout of the vertical collection view lands
    /// asynchronously, so the restore keeps nudging itself until the target
    /// frame materializes; attempts 3/6/9 re-issue the scroll request in case
    /// the viewport dropped it (e.g. it arrived before the scroll view had
    /// nonzero bounds). `model`/`scrollCoordinator` captured here are the same
    /// stable instances the old view-struct copy resolved at tick time.
    private func scheduleVerticalRestoreRetry(
        for request: NovelReaderVerticalScrollRequest,
        model: NovelReaderViewModel,
        scrollCoordinator: NovelReaderVerticalScrollCoordinator
    ) {
        verticalRestoreRetryTask?.cancel()
        verticalRestoreRetryTask = Task {
            for attempt in 1 ... 10 {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.verticalRestoreController.scrollingRequest == request else { return }
                    self.tryAdvanceVerticalRestore(model: model, scrollCoordinator: scrollCoordinator)
                    if self.verticalRestoreController.scrollingRequest == request, attempt == 3 || attempt == 6 || attempt == 9 {
                        self.reissueVerticalScrollRequest(request)
                    }
                }
            }
        }
    }
}
