import SwiftUI
import Observation
import YamiboXCore

#if os(iOS)
enum ReaderInformationTypography {
    static let pointSize: CGFloat = 14

    static var lineHeight: CGFloat {
        ceil(UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: UIFont.systemFont(ofSize: pointSize, weight: .semibold)
        ).lineHeight)
    }
}

struct ReaderInformationFont: ViewModifier {
    @ScaledMetric(relativeTo: .caption) private var size = ReaderInformationTypography.pointSize

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: .semibold))
    }
}

struct ReaderAttachedPageInformation: Equatable {
    let pageID: String?
    let title: String
    let pageNumber: Int?
    let pageLine: String
    let webLine: String
}

struct ReaderAttachedInformationConfiguration: Equatable {
    var pages: [[ReaderAttachedPageInformation]] = []
    var presentation = ReaderPageInformationPresentation(isPaged: true, isImmersive: true, isChromeVisible: false)
    var selectedIndex = 0
    var backgroundStyle: ReaderBackgroundStyle? = nil
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var titleSidePadding: CGFloat = 76
    var titleLift: CGFloat = 0
    var contentTopInset: CGFloat = 0
}

// Hosted pages observe only this presentation channel. Updating chrome must not
// replace their text/image hosts or invalidate a native zoom interaction.
@MainActor @Observable
final class ReaderAttachedInformationState {
    private(set) var configuration = ReaderAttachedInformationConfiguration()
    var usesStationaryZoomInformation = false

    func update(_ configuration: ReaderAttachedInformationConfiguration) {
        if self.configuration != configuration { self.configuration = configuration }
    }
}

struct ReaderAttachedInformationView: View {
    let state: ReaderAttachedInformationState
    let itemIndex: Int
    var slot: Int? = nil
    var stationaryZoomCopy = false
    var isBack = false

    var body: some View {
        let configuration = state.configuration
        let visible = configuration.presentation.isVisible
            && (stationaryZoomCopy == state.usesStationaryZoomInformation)
        HStack(spacing: 0) {
            if configuration.pages.indices.contains(itemIndex) {
                let pages = configuration.pages[itemIndex]
                ForEach(pages.indices, id: \.self) { index in
                    if slot == nil || slot == index {
                        ReaderAttachedInformationPage(page: pages[index], configuration: configuration)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .modifier(ReaderInformationVisibility(isVisible: configuration.presentation.isVisible))
        .opacity(stationaryZoomCopy == state.usesStationaryZoomInformation ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(!visible || isBack || configuration.selectedIndex != itemIndex)
    }

}

private struct ReaderAttachedInformationPage: View {
    let page: ReaderAttachedPageInformation
    let configuration: ReaderAttachedInformationConfiguration

    var body: some View {
        VStack(spacing: 0) {
            ReaderAttachedInformationTitle(title: page.title, backgroundStyle: configuration.backgroundStyle)
                .id(page.pageID)
                .padding(.horizontal, configuration.titleSidePadding)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                .padding(.top, max(configuration.topInset + 8, 20) - configuration.titleLift)
            Spacer(minLength: 0)
            if let number = page.pageNumber {
                ReaderAttachedInformationFooter(page: page, number: number, configuration: configuration)
                    .padding(.horizontal, 12)
                    .padding(.bottom, ReaderBottomChromeLayoutPresentation().bottomPadding(forBottomInset: configuration.bottomInset))
            }
        }
    }
}

private struct ReaderAttachedInformationTitle: View {
    let title: String
    let backgroundStyle: ReaderBackgroundStyle?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let text = Text(title)
            .modifier(ReaderInformationFont())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.center)
            .foregroundStyle(backgroundStyle == .quiet
                ? Color(uiColor: readerThemeTextUIColor(for: .quiet)).opacity(0.8) : Color.secondary)
        if backgroundStyle == nil {
            let capsuleSize = text.hidden().padding(.horizontal, 14).padding(.vertical, 8)
            let animation: Animation? = reduceMotion ? nil
                : .easeInOut(duration: ReaderInformationAnimation.titleCrossfadeDuration)
            ZStack {
                // Size the single plate independently of the outgoing title.
                capsuleSize
                    .readerChromePanel(cornerRadius: 18, tint: readerChromePanelTint(for: colorScheme))
                    .accessibilityHidden(true)
                text.padding(.horizontal, 14).padding(.vertical, 8)
                    .modifier(ReaderInformationTitleTransition(title: title))
                    .mask {
                        capsuleSize
                            .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    }
            }
            .animation(animation, value: title)
        } else {
            text
                .modifier(ReaderInformationTitleTransition(title: title))
        }
    }
}

private struct ReaderAttachedInformationFooter: View {
    let page: ReaderAttachedPageInformation
    let number: Int
    let configuration: ReaderAttachedInformationConfiguration

    var body: some View {
        ReaderInformationFooterReplacement(value: ReaderInformationFooterValue(
            pageID: page.pageID, number: number, pageLine: page.pageLine, webLine: page.webLine,
            style: configuration.presentation.pageNumberStyle
        )) { value in
            ReaderAttachedInformationFooterContent(value: value, backgroundStyle: configuration.backgroundStyle)
        }
    }
}

private struct ReaderAttachedInformationFooterContent: View {
    let value: ReaderInformationFooterValue
    let backgroundStyle: ReaderBackgroundStyle?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let compact = value.style == .compact
        let content = VStack(spacing: ReaderBottomChromeLayoutPresentation().progressSummaryLineSpacing) {
            Text(compact ? String(value.number) : value.pageLine)
            if !value.webLine.isEmpty {
                Text(value.webLine).opacity(compact ? 0 : 1).accessibilityHidden(compact)
            }
        }
        .modifier(ReaderInformationFont())
        .foregroundStyle(backgroundStyle == .quiet
            ? Color(uiColor: readerThemeTextUIColor(for: .quiet)).opacity(0.8) : Color.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .multilineTextAlignment(.center)
        if backgroundStyle == nil {
            content.padding(.horizontal, 14).padding(.vertical, 6)
                .readerChromePanel(cornerRadius: 16, tint: readerChromePanelTint(for: colorScheme))
        } else {
            content
        }
    }
}
#endif
