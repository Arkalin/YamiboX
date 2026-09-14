import SwiftUI

#if os(iOS)
enum ReaderInformationAnimation {
    static let visibilityDuration = 0.25
    static let replacementFadeOutDuration = 0.12
    static let replacementFadeInDuration = 0.18

    static func shouldReplaceFooter(
        from previous: ReaderInformationFooterValue,
        to next: ReaderInformationFooterValue,
        reduceMotion: Bool
    ) -> Bool {
        !reduceMotion && previous.pageID == next.pageID
            && previous.style != .hidden && next.style != .hidden
            && previous.style != next.style
    }
}

struct ReaderInformationFooterValue: Equatable {
    let pageID: String?
    let number: Int
    let pageLine: String
    let webLine: String
    let style: ReaderPageInformationPresentation.PageNumberStyle
}

struct ReaderInformationVisibility: ViewModifier {
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .animation(reduceMotion ? nil : .easeInOut(duration: ReaderInformationAnimation.visibilityDuration), value: isVisible)
    }
}

// Only one text/plate copy exists. Cancelled tasks cannot publish an obsolete
// label after a rapid chrome toggle or after the hosted page is reused.
struct ReaderInformationFooterReplacement<Content: View>: View {
    let value: ReaderInformationFooterValue
    @ViewBuilder let content: (ReaderInformationFooterValue) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed: ReaderInformationFooterValue?
    @State private var previous: ReaderInformationFooterValue?
    @State private var opacity = 1.0
    @State private var fadeDuration = ReaderInformationAnimation.replacementFadeInDuration

    var body: some View {
        let isSamePage = displayed?.pageID == value.pageID
        content(isSamePage ? (displayed ?? value) : value)
            .transaction { $0.animation = nil }
            .opacity(isSamePage ? opacity : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: fadeDuration), value: opacity)
            .task(id: Request(value: value, reduceMotion: reduceMotion)) {
                let old = previous
                previous = value
                guard let old else {
                    displayed = value
                    return
                }
                guard ReaderInformationAnimation.shouldReplaceFooter(from: old, to: value, reduceMotion: reduceMotion) else {
                    // Keep the old format while the whole information region fades out.
                    if value.style != .hidden || old.pageID != value.pageID { displayed = value }
                    fadeDuration = ReaderInformationAnimation.replacementFadeInDuration
                    opacity = 1
                    return
                }
                if displayed == value {
                    fadeDuration = ReaderInformationAnimation.replacementFadeInDuration
                    opacity = 1
                    return
                }
                fadeDuration = ReaderInformationAnimation.replacementFadeOutDuration
                opacity = 0
                do {
                    try await Task.sleep(for: .seconds(ReaderInformationAnimation.replacementFadeOutDuration))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                displayed = value
                fadeDuration = ReaderInformationAnimation.replacementFadeInDuration
                opacity = 1
            }
    }

    private struct Request: Equatable {
        let value: ReaderInformationFooterValue
        let reduceMotion: Bool
    }
}
#endif
