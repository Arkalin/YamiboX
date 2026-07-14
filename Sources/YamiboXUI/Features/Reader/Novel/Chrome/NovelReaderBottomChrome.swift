import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct NovelReaderBottomChrome: View {
    let progress: ReaderChromeProgress
    let readingMode: ReaderReadingMode
    let fillDirection: ReaderProgressFillDirection
    let bottomInset: CGFloat
    let isVisible: Bool
    let onShowChapters: () -> Void
    let onShowSettings: () -> Void
    let onShowCache: () -> Void
    let onShowComments: () -> Void
    let onOpenForum: () -> Void
    let onShowLikes: () -> Void
    let onJumpChapter: (Int) -> Void
    let onProgressCommit: (Int) -> Void
    let onVerticalProgressCommit: (Int) -> Void
    let onBeginVerticalProgressScrub: () -> Void
    let onEndVerticalProgressScrub: () -> Void
    let isProgressScrubbing: Bool

    @State private var scrubState = ReaderProgressScrubState()
    @State private var progressTickFeedbackGenerator = UISelectionFeedbackGenerator()
    @State private var progressStartFeedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    @State private var progressCommitFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 12) {
            bottomControls
                .readerChromeAnchoredPopupVisibility(isVisible)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .padding(.bottom, chromeLayout.bottomControlsAdditionalBottomOffset)

            progressSummary
                .readerChromeFadeVisibility(isVisible)
                .padding(.horizontal, 12)
        }
        .padding(.top, chromeLayout.bottomChromeTopPadding)
        .padding(.bottom, max(bottomInset - 18, 8))
    }

    private var chromeLayout: ReaderBottomChromeLayoutPresentation {
        ReaderBottomChromeLayoutPresentation()
    }

    private var bottomControls: some View {
        HStack(alignment: .top, spacing: chromeLayout.verticalScrubberSideSpacing) {
            VStack(spacing: chromeLayout.panelSpacing) {
                progressControl
                actionRow
            }
            .frame(width: chromeLayout.maxChromeWidth)

            if progressChromePresentation.showsVerticalScrubber {
                verticalProgressControl
                    .frame(width: chromeLayout.verticalScrubberWidth, alignment: .trailing)
            }
        }
        .frame(
            maxWidth: chromeLayout.maxChromeWidth + verticalProgressControlReservedWidth,
            alignment: .trailing
        )
    }

    private var verticalProgressControlReservedWidth: CGFloat {
        guard progressChromePresentation.showsVerticalScrubber else { return 0 }
        return chromeLayout.verticalScrubberSideSpacing + chromeLayout.verticalScrubberWidth
    }

    private var verticalProgressControl: some View {
        ReaderVerticalProgressCapsule(
            restingProgressFraction: progress.progressFraction,
            scrubContext: progress.scrubContext,
            ticks: progress.ticks,
            onBeginScrub: onBeginVerticalProgressScrub,
            onCommit: onVerticalProgressCommit,
            onEndScrub: onEndVerticalProgressScrub
        )
        .frame(width: chromeLayout.verticalScrubberWidth, alignment: .trailing)
    }

    private var actionRow: some View {
        let presentation = actionRowPresentation
        return HStack(spacing: 0) {
            bottomActionButton(
                action: ReaderBottomAction(kind: .browser),
                title: L10n.string("common.original_post"),
                systemName: "safari",
                handler: onOpenForum
            )
            Spacer(minLength: chromeLayout.actionButtonSpacing)
            bottomActionButton(
                action: ReaderBottomAction(kind: .bookmark),
                title: L10n.string("mine.my_likes"),
                systemName: "heart",
                handler: onShowLikes
            )
            Spacer(minLength: chromeLayout.actionButtonSpacing)
            bottomActionButton(
                action: ReaderBottomAction(kind: .cache),
                title: L10n.string("reader.cache"),
                systemName: "square.and.arrow.down",
                handler: onShowCache
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: chromeLayout.actionButtonRowHeight)
        .opacity(presentation.opacity)
        .allowsHitTesting(presentation.allowsHitTesting)
        .accessibilityHidden(presentation.isAccessibilityHidden)
    }

    private var actionRowPresentation: ReaderBottomActionRowPresentation {
        ReaderBottomActionRowPresentation(isScrubbing: isProgressScrubbing || scrubState.phase == .scrubbing)
    }

    @ViewBuilder
    private var progressSummary: some View {
        let summary = ReaderChromeProgressSummary(
            chapterTitle: progress.title(forTargetIndex: progress.currentIndex),
            progressText: progress.secondaryText ?? ""
        )

        let content = VStack(spacing: 2) {
            Text(summary.pageProgressLine)
            if !summary.webProgressLine.isEmpty {
                Text(summary.webProgressLine)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .multilineTextAlignment(.center)

        if readingMode == .vertical {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .readerChromePanel(cornerRadius: 16, tint: readerChromePanelTint(for: colorScheme))
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func bottomActionButton(
        action: ReaderBottomAction,
        title: String,
        systemName: String,
        handler: @escaping () -> Void
    ) -> some View {
        Button(action: handler) {
            Image(systemName: systemName)
                .font(.headline)
                .frame(width: chromeLayout.actionButtonIconFrame, height: chromeLayout.actionButtonIconFrame)
        }
        .readerChromeButtonStyle(tint: readerChromeButtonTint(for: colorScheme))
        .opacity(action.isDisabled ? 0.34 : 1)
        .disabled(action.isDisabled)
        .accessibilityLabel(title)
    }

    private var progressControl: some View {
        VStack(spacing: chromeLayout.panelSpacing) {
            if let preview = scrubState.preview, scrubState.phase == .scrubbing {
                ReaderVerticalProgressPreviewCapsule(preview: preview)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            ReaderDirectoryProgressCapsule(
                title: progress.primaryText,
                progressFraction: displayedProgressFraction,
                fillDirection: fillDirection,
                showsFill: progressChromePresentation.showsHorizontalFill,
                supportsScrub: progressChromePresentation.supportsHorizontalScrub && sliderHasAvailableRange,
                isScrubbing: scrubState.phase == .scrubbing,
                ticks: progress.ticks,
                onTapDirectory: onShowChapters,
                onScrub: { locationX, width in
                    handleHorizontalCapsuleScrub(locationX: locationX, width: width)
                },
                onEndScrub: {
                    commitHorizontalCapsuleScrub()
                }
            )
            .opacity(shouldHideDirectoryCapsule ? 0 : 1)
            .allowsHitTesting(!shouldHideDirectoryCapsule)
            .accessibilityHidden(shouldHideDirectoryCapsule)

            secondaryCapsuleButton(
                title: L10n.string("reader.comments"),
                systemName: "text.bubble",
                action: onShowComments
            )

            secondaryCapsuleButton(
                title: L10n.string("settings.title"),
                systemName: "gearshape",
                action: onShowSettings
            )
        }
    }

    private func secondaryCapsuleButton(
        title: String,
        systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        let presentation = actionRowPresentation

        return ReaderChromeCapsuleButton(
            title: title,
            systemName: systemName,
            action: action
        )
        .opacity(presentation.opacity)
        .allowsHitTesting(presentation.allowsHitTesting)
        .accessibilityHidden(presentation.isAccessibilityHidden)
    }

    private var shouldHideDirectoryCapsule: Bool {
        chromeLayout.hidesDirectoryCapsuleDuringVerticalScrub
            && readingMode == .vertical
            && isProgressScrubbing
    }

    private var progressChromePresentation: ReaderProgressChromePresentation {
        ReaderProgressChromePresentation(readingMode: readingMode, isChromeVisible: true)
    }

    private var sliderHasAvailableRange: Bool {
        progress.itemCount > 1
    }

    private var displayedProgressFraction: Double {
        if scrubState.phase == .scrubbing {
            return progress.positionFraction(forTargetIndex: scrubState.targetIndex)
        }
        return progress.progressFraction
    }

    private var scrubContext: ReaderProgressScrubContext {
        progress.scrubContext
    }

    private func handleHorizontalCapsuleScrub(locationX: CGFloat, width: CGFloat) {
        guard progressChromePresentation.supportsHorizontalScrub, width > 0 else { return }
        let fraction = min(max(locationX / width, 0), 1)
        let update = scrubState.update(value: Double(fraction), context: scrubContext)
        triggerFeedback(update.haptics)
    }

    private func commitHorizontalCapsuleScrub() {
        guard scrubState.phase == .scrubbing else { return }
        let update = scrubState.end()
        triggerFeedback(update.haptics)
        if let target = update.committedTargetIndex {
            onProgressCommit(target)
        }
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
}
#endif
