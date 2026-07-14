import SwiftUI
import XCTest
import YamiboXCore
@testable import YamiboXUI

/// The iOS 26 system bottom bar sizes its floating Liquid Glass capsule to
/// the toolbar content's *ideal* size, so the bar must already ask for
/// comfortable equal-width cells at that proposal — the original HStack of
/// `maxWidth: .infinity` buttons collapsed to the sum of the buttons' tight
/// icon/caption sizes (~130pt for the favorites bar), cramming the icons
/// together and truncating the longest caption.
final class SelectionBottomToolbarLayoutTests: XCTestCase {
    @MainActor
    func testIdealSizeGivesEveryActionAComfortableEqualCell() {
        let ideal = measuredSize(
            of: SelectionBottomToolbar(actions: Self.favoritesStyleActions).fixedSize()
        )

        // Four equal-width cells of at least 64pt each plus the bar's own
        // 16pt horizontal padding.
        XCTAssertGreaterThanOrEqual(ideal.width, 64 * 4 + 16)
        // Cells stay content-sized (widest caption plus breathing room)
        // instead of exploding past what an iPhone-width capsule can hold.
        XCTAssertLessThanOrEqual(ideal.width, 400)
        // Icon-over-caption buttons keep a >=44pt hit target inside the
        // bar's 12pt of vertical padding; the total stays low enough that
        // the iOS 26 floating capsule matches the ~61pt system tab bar it
        // replaces during selection mode.
        XCTAssertGreaterThanOrEqual(ideal.height, 44 + 12)
        XCTAssertLessThanOrEqual(ideal.height, 60)
    }

    @MainActor
    func testIdealSizeOfSingleActionBarStaysAButtonSizedBubble() {
        let ideal = measuredSize(
            of: SelectionBottomToolbar(
                actions: [
                    SelectionToolbarAction(
                        id: "delete",
                        title: L10n.string("common.delete"),
                        systemImage: "trash",
                        role: .destructive,
                        action: {}
                    )
                ]
            ).fixedSize()
        )

        XCTAssertGreaterThanOrEqual(ideal.width, 64 + 16)
        XCTAssertLessThanOrEqual(ideal.width, 200)
    }

    /// The pre-iOS-26 mounting proposes the full screen width via
    /// `.safeAreaInset`; the bar must keep filling it (evenly split cells)
    /// rather than hugging its ideal size.
    @MainActor
    func testProposedWidthIsFilledCompletely() {
        let filled = measuredSize(
            of: SelectionBottomToolbar(actions: Self.favoritesStyleActions),
            proposal: CGSize(width: 390, height: 640)
        )

        XCTAssertEqual(filled.width, 390, accuracy: 0.5)
    }

    @MainActor
    private func measuredSize(of view: some View, proposal: CGSize = CGSize(width: 10_000, height: 10_000)) -> CGSize {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: proposal)
    }

    /// The favorites screen's pure-favorites selection: its four actions are
    /// the widest bar in the app and include the longest caption (创建合集).
    private static let favoritesStyleActions: [SelectionToolbarAction] = [
        SelectionToolbarAction(id: "move", title: L10n.string("common.move"), systemImage: "folder", action: {}),
        SelectionToolbarAction(id: "createCollection", title: L10n.string("favorites.create_collection"), systemImage: "folder.badge.plus", action: {}),
        SelectionToolbarAction(id: "tags", title: L10n.string("favorites.tags_action"), systemImage: "tag", action: {}),
        SelectionToolbarAction(id: "delete", title: L10n.string("common.delete"), systemImage: "trash", role: .destructive, action: {})
    ]
}
