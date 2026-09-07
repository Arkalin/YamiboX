import SwiftUI
import UIKit
import WebKit
import XCTest
import YamiboXCore
@testable import YamiboXUI

final class LoadFailureDetailsPresentationTests: XCTestCase {
    @MainActor
    func testSwiftUIToastPausesAboveSheetAndResumesRemainingTime() async throws {
        let fixture = try mountedWindow()
        defer { fixture.close() }
        let model = FeedbackFixtureModel()
        let owner = UIHostingController(rootView: FeedbackFixture(model: model))
        fixture.root.present(owner, animated: false)
        try await Task.sleep(for: .milliseconds(300))
        let details = LoadFailureDetails(error: URLError(.timedOut), requestContext: "toast-owner")
        model.feedback = .failure("Timeout", details: details)
        try await Task.sleep(for: .milliseconds(800))
        let button = try XCTUnwrap(descendants(of: owner.view, as: UIButton.self).first {
            $0.accessibilityIdentifier == "toast-details-probe"
        })
        button.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(500))
        let presented = try XCTUnwrap(owner.presentedViewController)
        let text = try XCTUnwrap(descendants(of: presented.view, as: UITextView.self).first)
        XCTAssertEqual(text.text, details.diagnosticText)
        try await Task.sleep(for: .seconds(3))
        XCTAssertNotNil(model.feedback, "Viewing details must pause the owner's toast")
        XCTAssertTrue(fixture.root.presentedViewController === owner)
        presented.dismiss(animated: true)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNotNil(model.feedback, "Closing details must not immediately expire the remaining time")
        try await Task.sleep(for: .seconds(2))
        XCTAssertNil(model.feedback, "Closing details resumes the remaining time instead of a fresh duration")
        XCTAssertTrue(fixture.root.presentedViewController === owner)
    }

    @MainActor
    func testSwiftUIToastReplacesOpenDetailsAndClearsOnOwnerDismissal() async throws {
        let fixture = try mountedWindow()
        defer { fixture.close() }
        let model = FeedbackFixtureModel()
        let owner = UIHostingController(rootView: FeedbackFixture(model: model))
        fixture.root.present(owner, animated: false)
        try await Task.sleep(for: .milliseconds(300))
        model.feedback = .failure("Same error", details: LoadFailureDetails(message: "old snapshot"))
        try await Task.sleep(for: .milliseconds(300))
        let firstID = model.feedback?.id
        let button = try XCTUnwrap(descendants(of: owner.view, as: UIButton.self).first {
            $0.accessibilityIdentifier == "toast-details-probe"
        })
        button.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNotNil(owner.presentedViewController)
        model.feedback = .failure("Same error", details: LoadFailureDetails(message: "new snapshot"))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNotEqual(firstID, model.feedback?.id)
        XCTAssertNil(owner.presentedViewController)
        button.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(500))
        let presented = try XCTUnwrap(owner.presentedViewController)
        let text = try XCTUnwrap(descendants(of: presented.view, as: UITextView.self).first)
        XCTAssertEqual(text.text, model.feedback?.details?.diagnosticText)
        fixture.root.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.feedback)
    }

    @MainActor
    func testUIKitDetailsButtonIsBelowRetryAndPresentsSharedSheet() throws {
        let fixture = try mountedWindow()
        defer { fixture.close() }
        let overlay = ReaderLoadStateOverlayView(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        fixture.root.view.addSubview(overlay)
        let details = LoadFailureDetails(error: URLError(.timedOut), requestContext: "chapter-12")
        var retryCount = 0
        overlay.show(status: .failed(message: "Request timed out", details: details), retryAction: { retryCount += 1 })
        overlay.layoutIfNeeded()

        let detailsButton = try XCTUnwrap(descendants(of: overlay, as: UIButton.self).first {
            $0.accessibilityIdentifier == "load-failure-details"
        })
        let retryButton = try XCTUnwrap(descendants(of: overlay, as: UIButton.self).first {
            $0 !== detailsButton
        })
        let retryFrame = retryButton.convert(retryButton.bounds, to: overlay)
        let detailsFrame = detailsButton.convert(detailsButton.bounds, to: overlay)
        XCTAssertGreaterThanOrEqual(detailsFrame.minY, retryFrame.maxY)
        XCTAssertGreaterThanOrEqual(detailsFrame.height, 44)
        XCTAssertTrue(overlay.bounds.contains(detailsFrame))
        XCTAssertTrue(overlay.hitTest(CGPoint(x: detailsFrame.midX, y: detailsFrame.midY), with: nil) === detailsButton)
        retryButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(retryCount, 1)
        attach(overlay, name: "Failure buttons - small portrait")

        detailsButton.sendActions(for: .touchUpInside)
        settle()
        let presented = try XCTUnwrap(fixture.root.presentedViewController as? UIHostingController<LoadFailureDetailsSheet>)
        XCTAssertEqual(presented.rootView.details, details)
        XCTAssertEqual(presented.sheetPresentationController?.detents.map(\.identifier), [.medium, .large])
        XCTAssertEqual(presented.sheetPresentationController?.prefersGrabberVisible, true)
        let text = try XCTUnwrap(descendants(of: presented.view, as: UITextView.self).first)
        XCTAssertEqual(text.text, details.diagnosticText)
        detailsButton.sendActions(for: .touchUpInside)
        settle()
        XCTAssertNil(presented.presentedViewController, "Repeated details taps must not stack duplicate sheets")
        attach(presented.view, name: "Error details - medium sheet")
    }

    @MainActor
    func testUIKitDetailsPresentsAboveExistingSheetAndUsesLatestFailure() throws {
        let fixture = try mountedWindow()
        defer { fixture.close() }
        let existingSheet = UIViewController()
        existingSheet.view.backgroundColor = .systemBackground
        existingSheet.modalPresentationStyle = .pageSheet
        fixture.root.present(existingSheet, animated: false)
        settle()
        let overlay = ReaderLoadStateOverlayView(frame: existingSheet.view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        existingSheet.view.addSubview(overlay)
        overlay.show(status: .failed(message: "Old error", details: LoadFailureDetails(message: "old-request")), retryAction: {})
        overlay.show(status: .loading)
        overlay.hide()
        let latest = LoadFailureDetails(error: URLError(.cannotDecodeContentData), requestContext: "image-42")
        overlay.show(status: .failed(message: "New error", details: latest), retryAction: {})
        overlay.layoutIfNeeded()
        let button = try XCTUnwrap(descendants(of: overlay, as: UIButton.self).first {
            $0.accessibilityIdentifier == "load-failure-details"
        })
        button.sendActions(for: .touchUpInside)
        settle()

        let presented = try XCTUnwrap(existingSheet.presentedViewController as? UIHostingController<LoadFailureDetailsSheet>)
        XCTAssertTrue(fixture.root.presentedViewController === existingSheet)
        XCTAssertEqual(presented.rootView.details, latest)
        let text = try XCTUnwrap(descendants(of: presented.view, as: UITextView.self).first)
        XCTAssertTrue(text.text.contains("image-42"))
        XCTAssertFalse(text.text.contains("old-request"))
        attach(presented.view, name: "Error details above existing sheet")
        let close = try XCTUnwrap(presented.rootView.onClose)
        close()
        waitForDismissal(from: existingSheet)
        XCTAssertNil(existingSheet.presentedViewController)
        XCTAssertTrue(fixture.root.presentedViewController === existingSheet, "Closing details must preserve the original sheet")
        button.sendActions(for: .touchUpInside)
        settle()
        XCTAssertNotNil(existingSheet.presentedViewController)
        overlay.show(status: .loading)
        waitForDismissal(from: existingSheet)
        XCTAssertNil(existingSheet.presentedViewController, "Starting a new request must dismiss its stale diagnostics")
        XCTAssertTrue(fixture.root.presentedViewController === existingSheet)
    }

    @MainActor
    func testLongHTMLIsPlainSelectableScrollableAndNotTruncated() throws {
        let fixture = try mountedWindow()
        defer { fixture.close() }
        let source = "<html><body><input name=\"token\" value=\"private-token\"><script>alert('not executed')</script>\n"
            + (0..<250).map { "<p>Diagnostic source line \($0)</p>" }.joined(separator: "\n")
            + "\n</body></html>"
        let details = LoadFailureDetails(error: YamiboError.parsingFailed(context: "Missing content"), html: source)
        let host = UIHostingController(rootView: LoadFailureDetailsSheet(details: details))
        mount(host, in: fixture.root, size: CGSize(width: 320, height: 568))
        let picker = try XCTUnwrap(descendants(of: host.view, as: UISegmentedControl.self).first)
        XCTAssertEqual(picker.numberOfSegments, 2)
        picker.selectedSegmentIndex = 1
        picker.sendActions(for: .valueChanged)
        settle()

        let text = try XCTUnwrap(descendants(of: host.view, as: UITextView.self).first)
        XCTAssertEqual(text.text, details.html)
        XCTAssertFalse(text.text.contains("private-token"))
        XCTAssertTrue(text.text.contains("<script>alert('not executed')</script>"))
        XCTAssertTrue(text.text.hasSuffix("</body></html>"))
        XCTAssertTrue(descendants(of: host.view, as: WKWebView.self).isEmpty)
        XCTAssertFalse(text.isEditable)
        XCTAssertTrue(text.isSelectable)
        XCTAssertTrue(text.isScrollEnabled)
        XCTAssertTrue(text.font?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
        text.selectedRange = NSRange(location: 0, length: 6)
        XCTAssertEqual(text.selectedRange, NSRange(location: 0, length: 6))
        XCTAssertGreaterThan(text.contentSize.height, text.bounds.height)
        attach(host.view, name: "Long HTML - plain selectable source")
        text.scrollRangeToVisible(NSRange(location: text.text.utf16.count - 14, length: 14))
        settle()
        XCTAssertGreaterThan(text.contentOffset.y, 0)
        attach(host.view, name: "Long HTML - final source lines")
    }

    @MainActor
    func testDetailsRemainReadableInSmallLandscapeDarkModeAndLargeType() throws {
        let fixture = try mountedWindow()
        defer { fixture.close() }
        let details = LoadFailureDetails(
            error: URLError(.timedOut),
            requestContext: "https://example.invalid/reader/chapter-with-a-long-request-context"
        )
        for size in [CGSize(width: 320, height: 568), CGSize(width: 568, height: 320)] {
            let host = UIHostingController(rootView: LoadFailureDetailsSheet(details: details)
                .environment(\.colorScheme, .dark)
                .environment(\.dynamicTypeSize, .accessibility3))
            host.overrideUserInterfaceStyle = .dark
            host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
            mount(host, in: fixture.root, size: size)
            let text = try XCTUnwrap(descendants(of: host.view, as: UITextView.self).first)
            let frame = text.convert(text.bounds, to: host.view)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, -1)
            XCTAssertGreaterThanOrEqual(frame.minY, -1)
            XCTAssertLessThanOrEqual(frame.maxX, size.width + 1)
            XCTAssertLessThanOrEqual(frame.maxY, size.height + 1)
            XCTAssertGreaterThan(text.font?.pointSize ?? 0, 17)
            XCTAssertEqual(text.text, details.diagnosticText)
            XCTAssertEqual(text.traitCollection.userInterfaceStyle, .dark)
            XCTAssertTrue(text.adjustsFontForContentSizeCategory)
            attach(host.view, name: "Error details - dark large type \(Int(size.width))x\(Int(size.height))")
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
    }

    @MainActor
    private func mountedWindow() throws -> WindowFixture {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Presentation and control events require an app-hosted run with TEST_HOST; the default test plan uses a logic-test runner")
        }
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground
        window.rootViewController = root
        window.makeKeyAndVisible()
        settle()
        return WindowFixture(window: window, root: root, previousKeyWindow: previousKeyWindow)
    }

    @MainActor
    private func mount(_ child: UIViewController, in parent: UIViewController, size: CGSize) {
        parent.addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        parent.view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            child.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
            child.view.widthAnchor.constraint(equalToConstant: size.width),
            child.view.heightAnchor.constraint(equalToConstant: size.height)
        ])
        child.didMove(toParent: parent)
        parent.view.layoutIfNeeded()
        settle()
    }

    @MainActor
    private func descendants<T: UIView>(of view: UIView, as type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? [])
            + view.subviews.flatMap { descendants(of: $0, as: type) }
    }

    @MainActor
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    @MainActor
    private func waitForDismissal(from presenter: UIViewController) {
        let deadline = Date().addingTimeInterval(3)
        while presenter.presentedViewController != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    @MainActor
    private func attach(_ view: UIView, name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private struct WindowFixture {
        let window: UIWindow
        let root: UIViewController
        let previousKeyWindow: UIWindow?

        func close() {
            root.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
    }
}

@MainActor
private final class FeedbackFixtureModel: ObservableObject {
    @Published var feedback: TransientFeedback?
}

private struct FeedbackFixture: View {
    @ObservedObject var model: FeedbackFixtureModel

    var body: some View {
        Color.white
            .transientFeedbackOverlay(
                model.feedback, bottomPadding: 24, horizontalPadding: 24,
                minimumSeconds: 3, animation: .linear(duration: 0)
            ) { _, action in
                FeedbackDetailsProbe(action: action)
                    .frame(width: 120, height: 44)
            } clear: {
                model.feedback = nil
            }
    }
}

private struct FeedbackDetailsProbe: UIViewRepresentable {
    let action: (() -> Void)?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "toast-details-probe"
        button.setTitle("Details", for: .normal)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.removeAction(identifiedBy: .init("details"), for: .touchUpInside)
        button.addAction(UIAction(identifier: .init("details")) { _ in action?() }, for: .touchUpInside)
    }
}
