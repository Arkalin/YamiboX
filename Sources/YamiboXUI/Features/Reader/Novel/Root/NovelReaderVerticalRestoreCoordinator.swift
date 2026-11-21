import Observation
import SwiftUI
import YamiboXCore
import UIKit

@MainActor
@Observable
final class NovelReaderVerticalRestoreCoordinator {
    private(set) var verticalScrollRequest: NovelReaderVerticalScrollRequest?
    private(set) var verticalRestoreController = ReaderVerticalRestoreController()

    @ObservationIgnored private var verticalScrollRequestCommandID: UInt64 = 0
    @ObservationIgnored private var verticalRestoreRetryTask: Task<Void, Never>?
    @ObservationIgnored private var verticalViewportPositionUpdateTask: Task<Void, Never>?
    private let verticalViewportSampling = NovelReaderVerticalViewportSamplingBox()
    @ObservationIgnored private var lastVerticalPositioningFingerprint: NovelReaderVerticalPositioningFingerprint?
    @ObservationIgnored var admitsViewport: () -> Bool = { true }
    @ObservationIgnored private var hasRequestedPlacement = false

    /// Normally detached synchronously before the session can move.
    deinit {
        verticalRestoreRetryTask?.cancel()
        verticalViewportPositionUpdateTask?.cancel()
    }


    func cancelPendingRestoreWork() {
        verticalRestoreRetryTask?.cancel()
        verticalViewportPositionUpdateTask?.cancel()
        verticalRestoreController.cancel()
        verticalScrollRequest = nil
        lastVerticalPositioningFingerprint = nil
        hasRequestedPlacement = false
        verticalViewportSampling.viewportSample = nil
        verticalViewportSampling.surfaceFrames = [:]
    }


    func handleScrollRequestHandled(
        _ request: NovelReaderVerticalScrollRequest,
        model: NovelReaderViewModel,
        scrollCoordinator: NovelReaderVerticalScrollCoordinator
    ) {
        guard admitsViewport() else { return }
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

    func handleSurfaceFramesChange(
        _ frames: [Int: NovelReaderVerticalSurfaceFrameValue],
        model: NovelReaderViewModel,
        scrollCoordinator: NovelReaderVerticalScrollCoordinator
    ) {
        guard admitsViewport() else { return }
        guard verticalViewportSampling.surfaceFrames != frames else { return }
        verticalViewportSampling.surfaceFrames = frames
        tryAdvanceVerticalRestore(model: model, scrollCoordinator: scrollCoordinator)
        applyVerticalViewportPositionUpdate(for: .viewportGeometryChanged, model: model)
    }

    func handleViewportSampleChange(
        _ sample: NovelReaderVerticalViewportSample?,
        model: NovelReaderViewModel
    ) {
        guard admitsViewport() else { return }
        guard verticalViewportSampling.viewportSample != sample else { return }
        verticalViewportSampling.viewportSample = sample
        applyVerticalViewportPositionUpdate(for: .viewportSampleChanged, model: model)
    }


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


    private func rememberCurrentVerticalPositioningFingerprint(model: NovelReaderViewModel) {
        lastVerticalPositioningFingerprint = currentVerticalPositioningFingerprint(model: model)
    }

    func restoreVerticalPositionIfNeeded(
        model: NovelReaderViewModel,
        scrollCoordinator: NovelReaderVerticalScrollCoordinator
    ) {
        guard admitsViewport() else { return }
        guard let fingerprint = currentVerticalPositioningFingerprint(model: model) else {
            lastVerticalPositioningFingerprint = nil
            return
        }
        guard lastVerticalPositioningFingerprint != fingerprint else { return }
        lastVerticalPositioningFingerprint = fingerprint
        hasRequestedPlacement = true
        requestVerticalScrollToCurrentPage(model: model, scrollCoordinator: scrollCoordinator)
    }

    private func makeVerticalScrollRequest(model: NovelReaderViewModel) -> NovelReaderVerticalScrollRequest {
        let resumePoint = model.currentNovelResumePoint
        let isImage = model.novelReaderSurfaces.contains { surface in
            surface.documentView == resumePoint?.view && surface.externalBlocks.contains {
                $0.imageSegmentIdentity != nil && $0.imageSegmentIdentity == resumePoint?.textSegmentIdentity
            }
        }
        let textAnchor = !isImage && resumePoint?.view == model.visibleView
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
        guard admitsViewport(), hasRequestedPlacement, model.settings.readingMode == .vertical else { return }
        guard canSampleVerticalViewport() else {
            return
        }

        if let sample = verticalViewportSampling.viewportSample {
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
        guard admitsViewport() else { return }
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
        guard admitsViewport() else { return }
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
        guard canSampleVerticalViewport() else {
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
        var refreshedController = verticalRestoreController
        refreshedController.refresh(now: now)
        guard refreshedController != verticalRestoreController else { return }
        verticalRestoreController = refreshedController
    }

    private func canSampleVerticalViewport() -> Bool {
        refreshVerticalRestorePhase()
        return !verticalRestoreController.shouldSuppressViewportSampling
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
