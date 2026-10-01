import SwiftUI

/// Native scroll targets retain an anchor as lazy rows acquire their actual
/// sizes. Start when the scroll container has layout, not after a fixed delay.
struct ForumThreadAnchorScrollModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(idType: String.self)
    @State private var hasLayout = false
    @State private var pendingAnchor: String?
    @State private var visiblePostIDs: [String] = []

    let postIDs: [String]?
    let targetPostID: String?
    let restoredAnchorPostID: String?
    @Binding var highlightedPostID: String?
    let onConsumeRestoredAnchor: () -> Void

    private struct Request: Equatable {
        let postIDs: [String]?
        let target: String?
        let restored: String?
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position, anchor: .top)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.containerSize.height > 0 && geometry.contentSize.height > 0
            } action: { _, ready in
                hasLayout = ready
                if ready { scrollToPendingAnchor() }
            }
            // Long novel floors may be taller than 100 viewports. Any visible
            // portion counts; a percentage threshold could never be reached.
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0) { ids in
                visiblePostIDs = ids
                finishVisibleAnchor()
            }
            .task(id: Request(postIDs: postIDs, target: targetPostID, restored: restoredAnchorPostID)) {
                pendingAnchor = nil
                highlightedPostID = nil
                guard let postIDs else { return }
                guard let anchor = targetPostID ?? restoredAnchorPostID else { return }
                guard postIDs.contains(anchor) else {
                    if targetPostID == nil { onConsumeRestoredAnchor() }
                    return
                }
                pendingAnchor = anchor
                scrollToPendingAnchor()
            }
            .task(id: highlightedPostID) {
                guard highlightedPostID != nil else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                highlightedPostID = nil
            }
    }

    private func scrollToPendingAnchor() {
        guard hasLayout, let pendingAnchor else { return }
        // Centering a long chapter floor lands midway through its text.
        // Restores also avoid intermediate visibility/progress during motion.
        if reduceMotion || targetPostID == nil {
            position.scrollTo(id: pendingAnchor, anchor: .top)
        } else {
            withAnimation(.snappy) { position.scrollTo(id: pendingAnchor, anchor: .top) }
        }
        finishVisibleAnchor()
    }

    private func finishVisibleAnchor() {
        guard let anchor = pendingAnchor, visiblePostIDs.contains(anchor) else { return }
        pendingAnchor = nil
        if targetPostID != nil {
            highlightedPostID = anchor
        } else {
            // Seed progress from the requested floor before accepting live
            // visibility reports, so a no-scroll visit cannot drift upward.
            onConsumeRestoredAnchor()
        }
    }
}
