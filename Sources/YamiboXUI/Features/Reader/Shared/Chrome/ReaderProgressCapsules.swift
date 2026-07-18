import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

private struct ReaderProgressChapterTickOverlay: View {
    let ticks: [ReaderChromeProgressTick]
    let currentTint: Color

    var body: some View {
        let layout = ReaderBottomChromeLayoutPresentation()

        GeometryReader { geometry in
            ForEach(Array(ticks.enumerated()), id: \.element.targetIndex) { _, tick in
                Capsule()
                    .fill(tick.isCurrent ? currentTint : Color.secondary.opacity(0.38))
                    .frame(width: tick.isCurrent ? 3 : 2, height: tick.isCurrent ? 12 : 8)
                    .position(
                        x: layout.capsuleChapterTickCoordinate(
                            position: tick.positionFraction,
                            length: geometry.size.width,
                            edgeInset: layout.capsuleChapterTickRoundedEdgeInset
                        ),
                        y: geometry.size.height / 2
                    )
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

struct ReaderDirectoryProgressCapsule: View {
    let title: String
    let progressFraction: Double
    let fillDirection: ReaderProgressFillDirection
    let showsFill: Bool
    let supportsScrub: Bool
    let isScrubbing: Bool
    let ticks: [ReaderChromeProgressTick]
    let iconSystemName: String
    let onTapDirectory: () -> Void
    let onScrub: (CGFloat, CGFloat) -> Void
    let onEndScrub: () -> Void
    @State private var dragStartProgressFraction: Double?
    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        progressFraction: Double,
        fillDirection: ReaderProgressFillDirection = .leftToRight,
        showsFill: Bool,
        supportsScrub: Bool,
        isScrubbing: Bool,
        ticks: [ReaderChromeProgressTick],
        iconSystemName: String = "list.bullet",
        onTapDirectory: @escaping () -> Void,
        onScrub: @escaping (CGFloat, CGFloat) -> Void,
        onEndScrub: @escaping () -> Void
    ) {
        self.title = title
        self.progressFraction = progressFraction
        self.fillDirection = fillDirection
        self.showsFill = showsFill
        self.supportsScrub = supportsScrub
        self.isScrubbing = isScrubbing
        self.ticks = ticks
        self.iconSystemName = iconSystemName
        self.onTapDirectory = onTapDirectory
        self.onScrub = onScrub
        self.onEndScrub = onEndScrub
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = ReaderBottomChromeLayoutPresentation()
            let controlTint = layout.progressCapsulesUseButtonTint ? readerChromeButtonTint(for: colorScheme) : Color.accentColor
            let width = max(geometry.size.width, 1)
            let clampedProgress = min(max(progressFraction, 0), 1)

            ZStack(alignment: fillAlignment) {
                Capsule()
                    .fill(Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.12))

                if showsFill {
                    Rectangle()
                        .fill(controlTint.opacity(colorScheme == .dark ? 0.24 : 0.18))
                        .frame(
                            width: layout.capsuleProgressFillExtent(
                                position: clampedProgress,
                                length: width,
                                edgeInset: layout.capsuleChapterTickRoundedEdgeInset
                            )
                        )
                        .accessibilityHidden(true)
                }

                ReaderProgressChapterTickOverlay(ticks: ticks, currentTint: controlTint)
                    .opacity(showsChapterTicks(layout: layout) ? 1 : 0)

                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 12)
                    Image(systemName: iconSystemName)
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(layout.directoryCapsuleContentUsesAccentColor ? controlTint : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .opacity(layout.horizontalDirectoryContentHiddenWhileScrubbing && isScrubbing ? 0 : 1)
            }
            .frame(height: 44)
            .clipShape(Capsule())
            .contentShape(Capsule())
            .readerChromePanel(cornerRadius: 24, tint: readerChromePanelTint(for: colorScheme))
            .gesture(scrubGesture(width: width), including: supportsScrub ? .gesture : .subviews)
            .onTapGesture(perform: onTapDirectory)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityHint(L10n.string("reader.chapters"))
        }
        .frame(height: ReaderBottomChromeLayoutPresentation().progressPanelHeight)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard supportsScrub else { return }
                if dragStartProgressFraction == nil {
                    dragStartProgressFraction = progressFraction
                }
                let logicalTranslation = fillDirection == .rightToLeft ? -value.translation.width : value.translation.width
                let targetFraction = ReaderProgressDragMapping.value(
                    startProgressFraction: dragStartProgressFraction ?? progressFraction,
                    translation: logicalTranslation,
                    length: width,
                    range: 0...1
                )
                onScrub(CGFloat(targetFraction) * width, width)
            }
            .onEnded { _ in
                guard supportsScrub else { return }
                dragStartProgressFraction = nil
                onEndScrub()
            }
    }

    private var fillAlignment: Alignment {
        switch fillDirection {
        case .leftToRight:
            .leading
        case .rightToLeft:
            .trailing
        }
    }

    private func showsChapterTicks(layout: ReaderBottomChromeLayoutPresentation) -> Bool {
        let canShowTicks = showsFill || layout.directoryChapterTicksDoNotRequireProgressFill
        return canShowTicks && (!layout.horizontalChapterTicksVisibleOnlyWhileScrubbing || isScrubbing)
    }
}

struct ReaderVerticalProgressCapsule<PreviewContent: View>: View {
    let restingProgressFraction: Double
    let scrubContext: ReaderProgressScrubContext
    let ticks: [ReaderChromeProgressTick]
    let previewSize: CGSize
    let showsPreview: Bool
    let onPreviewChange: (ReaderProgressScrubPreview?) -> Void
    let onBeginScrub: () -> Void
    let onCommit: (Int) -> Void
    let onEndScrub: () -> Void
    @ViewBuilder let previewContent: (ReaderProgressScrubPreview) -> PreviewContent
    @State private var dragStartProgressFraction: Double?
    @State private var scrubState = ReaderProgressScrubState()
    @State private var progressStartFeedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    @State private var progressTickFeedbackGenerator = UISelectionFeedbackGenerator()
    @State private var progressCommitFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
    @Environment(\.colorScheme) private var colorScheme

    init(
        restingProgressFraction: Double,
        scrubContext: ReaderProgressScrubContext,
        ticks: [ReaderChromeProgressTick],
        previewSize: CGSize,
        showsPreview: Bool = true,
        onPreviewChange: @escaping (ReaderProgressScrubPreview?) -> Void = { _ in },
        onBeginScrub: @escaping () -> Void,
        onCommit: @escaping (Int) -> Void,
        onEndScrub: @escaping () -> Void,
        @ViewBuilder previewContent: @escaping (ReaderProgressScrubPreview) -> PreviewContent
    ) {
        self.restingProgressFraction = restingProgressFraction
        self.scrubContext = scrubContext
        self.ticks = ticks
        self.previewSize = previewSize
        self.showsPreview = showsPreview
        self.onPreviewChange = onPreviewChange
        self.onBeginScrub = onBeginScrub
        self.onCommit = onCommit
        self.onEndScrub = onEndScrub
        self.previewContent = previewContent
    }

    var body: some View {
        let layout = ReaderBottomChromeLayoutPresentation()
        let preview = scrubState.preview
        let totalWidth = isScrubbing && showsPreview ? previewSize.width + layout.verticalScrubberSideSpacing + layout.verticalScrubberWidth : layout.verticalScrubberWidth

        GeometryReader { geometry in
            let height = max(geometry.size.height, 1)
            let thumbY = min(max(height * min(max(displayedProgressFraction, 0), 1), 0), height)

            ZStack(alignment: .topTrailing) {
                verticalProgressBar(height: height, thumbY: thumbY)
                    .frame(width: layout.verticalScrubberWidth, height: height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

                if isScrubbing, let preview, showsPreview {
                    previewContent(preview)
                        .frame(width: previewSize.width, height: previewSize.height)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(y: min(max(thumbY - previewSize.height / 2, 0), max(height - previewSize.height, 0)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .topTrailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartProgressFraction == nil {
                            // Touch-down: spin the Taptic Engine up before the
                            // first haptic of this scrub fires.
                            prepareFeedbackGenerators()
                            dragStartProgressFraction = displayedProgressFraction
                        }
                        let targetFraction = ReaderProgressDragMapping.value(
                            startProgressFraction: dragStartProgressFraction ?? displayedProgressFraction,
                            translation: value.translation.height,
                            length: height,
                            range: 0...1
                        )
                        updateScrub(value: targetFraction)
                    }
                    .onEnded { _ in
                        dragStartProgressFraction = nil
                        commitScrub()
                    }
            )
            .accessibilityLabel(L10n.string("reader.progress_capsule.directory_progress"))
        }
        .frame(width: totalWidth)
        .frame(height: layout.verticalScrubberHeight)
        .onAppear(perform: prepareFeedbackGenerators)
    }

    private func prepareFeedbackGenerators() {
        progressStartFeedbackGenerator.prepare()
        progressTickFeedbackGenerator.prepare()
        progressCommitFeedbackGenerator.prepare()
    }

    private var displayedProgressFraction: Double {
        if scrubState.phase == .scrubbing {
            guard scrubContext.itemCount > 1 else { return 0 }
            return Double(scrubState.targetIndex) / Double(max(scrubContext.itemCount - 1, 1))
        }
        return restingProgressFraction
    }

    private var isScrubbing: Bool {
        scrubState.phase == .scrubbing
    }

    private func updateScrub(value: Double) {
        let wasScrubbing = scrubState.phase == .scrubbing
        let update = scrubState.update(value: value, context: scrubContext)
        if !wasScrubbing, scrubState.phase == .scrubbing {
            onBeginScrub()
        }
        onPreviewChange(scrubState.preview)
        triggerFeedback(update.haptics)
    }

    private func commitScrub() {
        guard scrubState.phase == .scrubbing else {
            scrubState.reset()
            onPreviewChange(nil)
            onEndScrub()
            return
        }
        let update = scrubState.end()
        triggerFeedback(update.haptics)
        if let target = update.committedTargetIndex {
            onCommit(target)
        }
        scrubState.reset()
        onPreviewChange(nil)
        onEndScrub()
    }

    private func triggerFeedback(_ haptics: [ReaderProgressScrubHaptic]) {
        for haptic in haptics {
            switch haptic {
            case .start:
                progressStartFeedbackGenerator.impactOccurred()
                progressStartFeedbackGenerator.prepare()
                progressTickFeedbackGenerator.prepare()
            case .chapterTick:
                progressTickFeedbackGenerator.selectionChanged()
                progressTickFeedbackGenerator.prepare()
            case .commit:
                progressCommitFeedbackGenerator.impactOccurred()
                progressCommitFeedbackGenerator.prepare()
            }
        }
    }

    private func verticalProgressBar(height: CGFloat, thumbY: CGFloat) -> some View {
        let layout = ReaderBottomChromeLayoutPresentation()
        let controlTint = layout.progressCapsulesUseButtonTint ? readerChromeButtonTint(for: colorScheme) : Color.accentColor

        return ZStack(alignment: .topTrailing) {
            Capsule()
                .fill(Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.12))
                .readerChromePanel(cornerRadius: 24, tint: readerChromePanelTint(for: colorScheme))

            if layout.verticalScrubberShowsProgressFill {
                Rectangle()
                    .fill(controlTint.opacity(colorScheme == .dark ? 0.24 : 0.18))
                    .frame(
                        width: layout.verticalScrubberWidth,
                        height: layout.capsuleProgressFillExtent(
                            position: min(max(thumbY / max(height, 1), 0), 1),
                            length: height,
                            edgeInset: layout.capsuleChapterTickRoundedEdgeInset
                        )
                    )
                    .accessibilityHidden(true)
            }

            ReaderVerticalProgressChapterTickOverlay(ticks: ticks, currentTint: controlTint)
                .opacity(layout.verticalScrubberShowsChapterTicks && (!layout.verticalChapterTicksVisibleOnlyWhileScrubbing || isScrubbing) ? 1 : 0)

            if layout.verticalScrubberShowsLiveThumb {
                Capsule()
                    .fill(controlTint.opacity(0.82))
                    .frame(width: 28, height: 3)
                    .offset(x: -18, y: min(max(thumbY - 1.5, 0), height - 3))
                    .accessibilityHidden(true)
            }
        }
        .mask(Capsule())
    }
}

extension ReaderVerticalProgressCapsule where PreviewContent == ReaderVerticalProgressPreviewCapsule {
    init(
        restingProgressFraction: Double,
        scrubContext: ReaderProgressScrubContext,
        ticks: [ReaderChromeProgressTick],
        onBeginScrub: @escaping () -> Void,
        onCommit: @escaping (Int) -> Void,
        onEndScrub: @escaping () -> Void
    ) {
        let layout = ReaderBottomChromeLayoutPresentation()
        self.init(
            restingProgressFraction: restingProgressFraction,
            scrubContext: scrubContext,
            ticks: ticks,
            previewSize: CGSize(width: layout.verticalPreviewWidth, height: layout.verticalPreviewHeight),
            onBeginScrub: onBeginScrub,
            onCommit: onCommit,
            onEndScrub: onEndScrub
        ) { preview in
            ReaderVerticalProgressPreviewCapsule(preview: preview)
        }
    }
}

private struct ReaderVerticalProgressChapterTickOverlay: View {
    let ticks: [ReaderChromeProgressTick]
    let currentTint: Color

    var body: some View {
        let layout = ReaderBottomChromeLayoutPresentation()

        GeometryReader { geometry in
            ForEach(Array(ticks.enumerated()), id: \.element.targetIndex) { _, tick in
                Capsule()
                    .fill(tick.isCurrent && layout.verticalCurrentChapterTickUsesAccentColor ? currentTint : Color.secondary.opacity(0.38))
                    .frame(width: tick.isCurrent ? 28 : 18, height: tick.isCurrent ? 3 : 2)
                    .position(
                        x: layout.verticalScrubberTicksAreCentered ? geometry.size.width / 2 : geometry.size.width - 24,
                        y: layout.capsuleChapterTickCoordinate(
                            position: tick.positionFraction,
                            length: geometry.size.height,
                            edgeInset: layout.capsuleChapterTickRoundedEdgeInset
                        )
                    )
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ReaderVerticalProgressPreviewCapsule: View {
    let preview: ReaderProgressScrubPreview

    var body: some View {
        let layout = ReaderBottomChromeLayoutPresentation()
        let chapterTitle = preview.chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(spacing: 2) {
            Text(chapterTitle?.isEmpty == false ? chapterTitle! : L10n.string("reader.chapters"))
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Text(L10n.string("reader.page_number_compact", preview.pageNumber))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .frame(width: layout.verticalPreviewWidth, height: layout.verticalPreviewHeight)
        .readerChromePanel(cornerRadius: 24, tint: Color.accentColor.opacity(0.08))
        .shadow(color: Color.black.opacity(0.08), radius: 10, y: 4)
    }
}
#endif
