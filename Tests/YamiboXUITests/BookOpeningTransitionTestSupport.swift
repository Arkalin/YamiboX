import SwiftUI
import Testing
@testable import YamiboXUI

@MainActor
func makeBookOpeningTransitionForTest() throws -> BookOpeningTransition {
    let recorder = BookOpeningTransitionRecorder()
    let host = UIHostingController(rootView: BookOpeningTransitionFixture(recorder: recorder))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 140))
    window.rootViewController = host
    window.isHidden = false
    defer {
        window.isHidden = true
        window.rootViewController = nil
    }
    host.view.frame = window.bounds
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    return try #require(recorder.source)
}

@MainActor
private final class BookOpeningTransitionRecorder {
    var source: BookOpeningTransition?
}

private struct BookOpeningTransitionFixture: View {
    @Namespace private var namespace
    let recorder: BookOpeningTransitionRecorder

    var body: some View {
        let source = BookOpeningTransition(namespace: namespace)
        Color.clear
            .matchedTransitionSource(id: BookOpeningTransition.sourceID, in: namespace)
            .onAppear { recorder.source = source }
    }
}
