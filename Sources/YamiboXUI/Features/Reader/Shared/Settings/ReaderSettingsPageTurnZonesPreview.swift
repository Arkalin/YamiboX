import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct ReaderSettingsPageTurnZonesPreview: View {
    let direction: ReaderPageTurnDirection
    let swapped: Bool
    let requestID: Int
    let isEnabled: Bool
    var usesCompactLabels = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    private struct Request: Equatable {
        let id: Int
        let isEnabled: Bool
    }

    private var leftIsPrevious: Bool {
        direction.directionalTapZone(for: .previous, swapped: swapped) == .previous
    }

    private var accessibilitySummary: String {
        L10n.string(leftIsPrevious ? "reader.tap_zones.left_previous" : "reader.tap_zones.left_next")
    }

    var body: some View {
        HStack(spacing: 0) {
            ReaderSettingsPageTurnZone(isPrevious: leftIsPrevious, arrow: "arrow.left", isCompact: usesCompactLabels)
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ReaderSettingsPageTurnZone(isPrevious: !leftIsPrevious, arrow: "arrow.right", isCompact: usesCompactLabels)
        }
        // The gesture zones are physical left/right thirds, independent of UI language.
        .environment(\.layoutDirection, .leftToRight)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHidden(!isVisible)
        .accessibilityIdentifier("reader.settings.tapZones.preview")
        .task(id: Request(id: requestID, isEnabled: isEnabled)) {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isVisible = isEnabled && requestID > 0
            }
            guard isVisible else { return }
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: accessibilitySummary)
            }
            do {
                try await Task.sleep(for: .seconds(1.6))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.9)) {
                isVisible = false
            }
        }
    }
}

private struct ReaderSettingsPageTurnZone: View {
    let isPrevious: Bool
    let arrow: String
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 6 : 10) {
            Image(systemName: arrow)
                .font(isCompact ? .caption.weight(.semibold) : .title3.weight(.semibold))
            Text(L10n.string(isPrevious ? "reader.previous_page" : "reader.next_page"))
                .font(isCompact ? .caption.weight(.semibold) : .headline)
                .lineLimit(isCompact ? 1 : nil)
                .minimumScaleFactor(isCompact ? 0.6 : 1)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
        .padding(.horizontal, isCompact ? 3 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.48))
    }
}

#endif
