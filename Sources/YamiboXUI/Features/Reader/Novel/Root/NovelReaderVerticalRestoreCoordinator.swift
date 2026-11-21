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
    @ObservationIgnored private var verticalViewportPositionUpdateTask: Task<Void, Never>?
    private let verticalViewportSampling = NovelReaderVerticalViewportSamplingBox()
    @ObservationIgnored private var lastVerticalPositioningFingerprint: NovelReaderVerticalPositioningFingerprint?
    @ObservationIgnored var admitsViewport: () -> Bool = { true }
    @ObservationIgnored private var hasRequestedPlacement = false

    /// Normally detached synchronously before the session can move.
    deinit {
        verticalViewportPositionUpdateTask?.cancel()
    }


    func cancelPendingRestoreWork() {
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
        verticalRestoreController.beginSettling(request, now: CACurrentMediaTime())
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

    func tryAdvanceVerticalRestore(
        model: NovelReaderViewModel,
        scrollCoordinator: NovelReaderVerticalScrollCoordinator
    ) {
        guard admitsViewport() else { return }
        refreshVerticalRestorePhase()
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
    }

}
