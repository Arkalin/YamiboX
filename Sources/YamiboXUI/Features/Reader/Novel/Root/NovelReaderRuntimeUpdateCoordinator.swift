import Observation
import YamiboXCore

/// Owns presentation inputs and runtime-update admission/rollback for a reader
/// session. The ViewModel supplies the workflow and publishes committed output;
/// it does not manage geometry/appearance request generations itself.
@MainActor
@Observable
final class NovelReaderRuntimeUpdateCoordinator {
    struct Reading {
        var settings: @MainActor () -> NovelReaderAppearanceSettings
        var workflow: @MainActor () -> NovelReadingWorkflow?
        var prepareInitialPresentation: @MainActor () async -> Void
        var updatePreparation: @MainActor () -> NovelReadingWorkflowRuntimeUpdatePreparation
        var publish: @MainActor (NovelReadingWorkflowState) -> Void
        var reportFailure: @MainActor (any Error) -> Void
    }

    private enum Activity {
        case idle
        case applyingAppearance(UInt64)
        case closed
    }

    let preparation = NovelReaderPreparationCoordinator()
    var bootstrapSettings = NovelReaderAppearanceSettings()
    @ObservationIgnored var initialViewportSettings: NovelReaderAppearanceSettings?
    var applePencilPageTurnSettings = ApplePencilPageTurnSettings()
    private var activity = Activity.idle
    @ObservationIgnored private(set) var usesPadPresentation = false
    @ObservationIgnored private var appearanceSettingsApplicationSequence: UInt64 = 0
    @ObservationIgnored private var requestSequence: UInt64 = 0
    @ObservationIgnored private var layoutRequestOwnershipSequence: UInt64 = 0
    @ObservationIgnored private var surfaceAppearanceRevision: UInt64 = 0
    @ObservationIgnored private var latestSurfaceAppearanceSettings: NovelReaderAppearanceSettings?
    private let reading: Reading

    init(reading: Reading) {
        self.reading = reading
    }

    var isApplyingAppearanceSettings: Bool {
        if case .applyingAppearance = activity { return true }
        return false
    }

    var layout: NovelReaderLayout { preparation.layout }
    private var latestRequestedLayout: NovelReaderLayout { preparation.requestedLayout }
    private var layoutRequestSequence: UInt64 { preparation.layoutRevision }
    private var initialPresentationPhase: NovelReaderInitialPresentationPhase { preparation.phase }
    private var settings: NovelReaderAppearanceSettings { reading.settings() }

    func close() {
        activity = .closed
        requestSequence &+= 1
        layoutRequestOwnershipSequence &+= 1
        appearanceSettingsApplicationSequence &+= 1
        preparation.close()
    }

    func commitNovelTextPresentationEnvironment(isPad: Bool) async {
        guard initialPresentationPhase != .cancelled, usesPadPresentation != isPad else { return }
        let previousUsesPadPresentation = usesPadPresentation
        guard settings.readingMode == .paged,
              reading.workflow()?.state != nil else {
            usesPadPresentation = isPad
            return
        }
        do {
            guard let state = try await requestRuntimeUpdate(
                settings: settings,
                layout: layout,
                usesPadPresentation: isPad
            ) else { return }
            usesPadPresentation = isPad
            reading.publish(state)
        } catch is CancellationError {
        } catch {
            usesPadPresentation = previousUsesPadPresentation
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                reading.reportFailure(error)
            }
        }
    }

    func commitNovelTextLayout(_ layout: NovelReaderLayout) async {
        guard initialPresentationPhase != .cancelled else { return }
        if initialPresentationPhase != .ready {
            if initialPresentationPhase == .restoring, latestRequestedLayout == layout { return }
            _ = beginLayoutRequestOwnership()
            preparation.requestLayout(layout)
            preparation.commitLayout(layout)
            guard preparation.hasStarted, initialPresentationPhase != .failed else { return }
            preparation.invalidateRestorationForLayoutChange()
            await reading.prepareInitialPresentation()
            return
        }
        guard isReadyForTextLayout(layout) else { return }
        guard latestRequestedLayout != layout else { return }
        let layoutOwnership = beginLayoutRequestOwnership()
        let requestSequence = preparation.requestLayout(layout)
        guard reading.workflow()?.state != nil else {
            preparation.commitLayout(layout)
            // The initial view task owns settings/repository bootstrap.
            // Geometry may arrive while that task is still suspended.
            if reading.workflow() != nil {
                await reading.prepareInitialPresentation()
            }
            return
        }
        do {
            guard let state = try await requestRuntimeUpdate(
                settings: settings,
                layout: layout,
                usesPadPresentation: usesPadPresentation
            ) else {
                rollbackLayoutRequest(ifCurrent: requestSequence, ownership: layoutOwnership)
                return
            }
            guard layoutRequestSequence == requestSequence,
                  layoutRequestOwnershipSequence == layoutOwnership else { return }
            preparation.commitLayout(layout)
            reading.publish(state)
        } catch is CancellationError {
            rollbackLayoutRequest(ifCurrent: requestSequence, ownership: layoutOwnership)
        } catch {
            guard layoutRequestSequence == requestSequence,
                  layoutRequestOwnershipSequence == layoutOwnership else { return }
            rollbackLayoutRequest(ifCurrent: requestSequence, ownership: layoutOwnership)
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                reading.reportFailure(error)
            }
        }
    }

    func isReadyForTextLayout(_ layout: NovelReaderLayout) -> Bool {
        layout.novelTextBoxLayout(settings: settings, usesPadPresentation: usesPadPresentation)
            .isReadyForTextLayout
    }

    func invalidateViewportUpdates() {
        reading.workflow()?.supersedePendingRuntimeUpdate()
        requestSequence &+= 1
        layoutRequestOwnershipSequence &+= 1
        appearanceSettingsApplicationSequence &+= 1
        preparation.rollbackLayoutRequest(ifCurrent: layoutRequestSequence)
        if isApplyingAppearanceSettings { activity = .idle }
    }

    /// Apply the target geometry directly. Applying appearance to the old
    /// window first would index the same document twice during handoff.
    func commitReaderViewport(_ update: NovelReadingWorkflowRuntimeUpdate) async throws -> Bool {
        guard initialPresentationPhase != .cancelled, !Task.isCancelled else { return false }
        guard update.layout.novelTextBoxLayout(
                settings: update.settings, usesPadPresentation: update.usesPadPresentation
              ).isReadyForTextLayout else {
            throw NovelTextLayoutFailure.textKitIndexing
        }
        if !preparation.hasStarted {
            initialViewportSettings = update.settings
            bootstrapSettings = update.settings
            usesPadPresentation = update.usesPadPresentation
            preparation.requestLayout(update.layout)
            preparation.commitLayout(update.layout)
            return true
        }
        guard initialPresentationPhase == .ready, reading.workflow()?.state != nil else {
            throw NovelTextLayoutFailure.textKitIndexing
        }
        guard settings != update.settings || layout != update.layout ||
                usesPadPresentation != update.usesPadPresentation else { return true }

        let ownership = beginLayoutRequestOwnership()
        let revision = preparation.requestLayout(update.layout)
        defer { rollbackLayoutRequest(ifCurrent: revision, ownership: ownership) }
        do {
            guard let state = try await requestRuntimeUpdate(
                settings: update.settings, layout: update.layout, usesPadPresentation: update.usesPadPresentation
            ), !Task.isCancelled, layoutRequestOwnershipSequence == ownership,
               layoutRequestSequence == revision else { return false }
            usesPadPresentation = update.usesPadPresentation
            preparation.commitLayout(update.layout)
            bootstrapSettings = update.settings
            reading.publish(state)
            return true
        } catch is CancellationError {
            return false
        }
    }

    func applyNovelTextAppearance(_ newSettings: NovelReaderAppearanceSettings) async {
        guard initialPresentationPhase != .cancelled, !Task.isCancelled else { return }
        let oldSettings = settings
        guard oldSettings != newSettings else { return }

        if oldSettings.isSurfaceOnlyAppearanceChange(to: newSettings) {
            surfaceAppearanceRevision &+= 1
            latestSurfaceAppearanceSettings = newSettings
            if let state = reading.workflow()?.commitSurfaceAppearance(newSettings) {
                reading.publish(state)
            }
            bootstrapSettings = newSettings
            return
        }

        guard reading.workflow()?.state != nil else {
            bootstrapSettings = newSettings
            return
        }

        let applicationSequence = beginApplyingAppearanceSettings()
        let appearanceLayout = NovelReaderLayoutPresentation.layout(
            containerSize: latestRequestedLayout.containerSize,
            safeAreaInsets: latestRequestedLayout.safeAreaInsets,
            settings: newSettings
        )
        let layoutOwnership = beginLayoutRequestOwnership()
        let layoutSequence = preparation.requestLayout(appearanceLayout)
        defer { finishApplyingAppearanceSettings(applicationSequence) }

        do {
            guard let state = try await requestRuntimeUpdate(
                settings: newSettings,
                layout: appearanceLayout,
                usesPadPresentation: usesPadPresentation
            ) else {
                guard appearanceSettingsApplicationSequence == applicationSequence else { return }
                rollbackLayoutRequest(ifCurrent: layoutSequence, ownership: layoutOwnership)
                return
            }
            guard appearanceSettingsApplicationSequence == applicationSequence else { return }
            guard layoutRequestSequence == layoutSequence,
                  layoutRequestOwnershipSequence == layoutOwnership else { return }
            preparation.commitLayout(appearanceLayout)
            reading.publish(state)
            bootstrapSettings = state.presentation?.committedSettings ?? newSettings
        } catch is CancellationError {
            guard appearanceSettingsApplicationSequence == applicationSequence else { return }
            rollbackLayoutRequest(ifCurrent: layoutSequence, ownership: layoutOwnership)
        } catch {
            guard appearanceSettingsApplicationSequence == applicationSequence else { return }
            rollbackLayoutRequest(ifCurrent: layoutSequence, ownership: layoutOwnership)
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                reading.reportFailure(error)
            }
        }
    }

    /// Both asynchronous success and failure belong to a specific workflow and
    /// request. Closing/replacing the workflow or a newer request invalidates both.
    func requestRuntimeUpdate(
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        usesPadPresentation: Bool
    ) async throws -> NovelReadingWorkflowState? {
        guard initialPresentationPhase != .cancelled, let workflow = reading.workflow() else { return nil }
        requestSequence &+= 1
        let sequence = requestSequence
        let surfaceRevision = surfaceAppearanceRevision
        while true {
            let documentRevision = workflow.documentRequestRevision
            do {
                let state = try await workflow.requestRuntimeUpdate(
                    NovelReadingWorkflowRuntimeUpdate(settings: settings, layout: layout, usesPadPresentation: usesPadPresentation),
                    preparation: reading.updatePreparation()
                )
                guard requestSequence == sequence, reading.workflow() === workflow,
                      initialPresentationPhase != .cancelled, !Task.isCancelled else { return nil }
                // Navigation may supersede the content transaction, but does
                // not invalidate this still-owned window/settings request.
                // Each retry requires a new document event, never just nil.
                if state == nil, workflow.documentRequestRevision != documentRevision { continue }
                guard surfaceAppearanceRevision != surfaceRevision else { return state }
                guard let latestSurfaceAppearanceSettings,
                      let committedSettings = state?.presentation?.committedSettings else { return nil }
                var mergedSettings = committedSettings
                mergedSettings.backgroundStyle = latestSurfaceAppearanceSettings.backgroundStyle
                mergedSettings.pagedTurnStyle = latestSurfaceAppearanceSettings.pagedTurnStyle
                mergedSettings.isImmersiveModeEnabled = latestSurfaceAppearanceSettings.isImmersiveModeEnabled
                mergedSettings.pageTurnDirection = latestSurfaceAppearanceSettings.pageTurnDirection
                mergedSettings.swapsPageTurnTapZones = latestSurfaceAppearanceSettings.swapsPageTurnTapZones
                return workflow.commitSurfaceAppearance(mergedSettings)
            } catch {
                guard requestSequence == sequence, reading.workflow() === workflow,
                      initialPresentationPhase != .cancelled, !Task.isCancelled else { throw CancellationError() }
                if error is CancellationError,
                   workflow.documentRequestRevision != documentRevision { continue }
                throw error
            }
        }
    }

    private func beginLayoutRequestOwnership() -> UInt64 {
        // Equal geometry can still belong to a newer appearance transaction.
        // Keep ownership separate from the geometry revision so an older
        // resize cannot roll back that transaction's requested layout.
        layoutRequestOwnershipSequence &+= 1
        return layoutRequestOwnershipSequence
    }

    private func rollbackLayoutRequest(ifCurrent revision: UInt64, ownership: UInt64) {
        guard layoutRequestOwnershipSequence == ownership else { return }
        preparation.rollbackLayoutRequest(ifCurrent: revision)
    }

    private func beginApplyingAppearanceSettings() -> UInt64 {
        appearanceSettingsApplicationSequence &+= 1
        activity = .applyingAppearance(appearanceSettingsApplicationSequence)
        return appearanceSettingsApplicationSequence
    }

    private func finishApplyingAppearanceSettings(_ sequence: UInt64) {
        guard case let .applyingAppearance(current) = activity, current == sequence else { return }
        activity = .idle
    }
}

private extension NovelReaderAppearanceSettings {
    func isSurfaceOnlyAppearanceChange(to other: NovelReaderAppearanceSettings) -> Bool {
        // Authored ink is contrast-adjusted against the paper color in the
        // attributed document, so a theme change must rebuild its attributes.
        if forumFormat.textColor || forumFormat.backgroundColor || forumFormat.quote,
           backgroundStyle != other.backgroundStyle {
            return false
        }
        // Quiet changes the attributed glyph color, not just the page background.
        // Rebuild on entry and exit so the live TextKit graph cannot retain old text colors.
        if backgroundStyle != other.backgroundStyle,
           backgroundStyle == .quiet || other.backgroundStyle == .quiet {
            return false
        }
        var lhs = self
        var rhs = other
        lhs.backgroundStyle = .system
        rhs.backgroundStyle = .system
        lhs.pagedTurnStyle = .slide
        rhs.pagedTurnStyle = .slide
        lhs.isImmersiveModeEnabled = false
        rhs.isImmersiveModeEnabled = false
        lhs.pageTurnDirection = .leftToRight
        rhs.pageTurnDirection = .leftToRight
        lhs.swapsPageTurnTapZones = false
        rhs.swapsPageTurnTapZones = false
        return lhs == rhs &&
            (backgroundStyle != other.backgroundStyle || pagedTurnStyle != other.pagedTurnStyle
                || isImmersiveModeEnabled != other.isImmersiveModeEnabled
                || pageTurnDirection != other.pageTurnDirection
                || swapsPageTurnTapZones != other.swapsPageTurnTapZones)
    }
}
