import SwiftUI
import UIKit
import XCTest
@testable import YamiboXUI

@MainActor
final class ForumEditorEditabilityTests: XCTestCase {
    func testEditabilityIsDeferredWhileInputIsBlockedImmediately() async {
        let view = EditabilityTrackingTextView()
        let controller = ForumEditorController()
        controller.view = view
        let coordinator = ForumTextEditor.Coordinator(
            text: .constant("Draft"), isHTMLSource: .constant(false), isBlog: false, controller: controller
        )
        view.delegate = coordinator
        view.editabilityAssignments = []

        coordinator.updateEditability(false, in: view)
        XCTAssertTrue(view.isEditable, "The responder-affecting setter must not run inside updateUIView")
        XCTAssertTrue(view.editabilityAssignments.isEmpty)
        XCTAssertFalse(coordinator.textViewShouldBeginEditing(view))
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "x"))

        await drainMainQueue()
        XCTAssertFalse(view.isEditable)
        XCTAssertEqual(view.editabilityAssignments, [false])
        coordinator.updateEditability(false, in: view)
        await drainMainQueue()
        XCTAssertEqual(view.editabilityAssignments, [false], "Unchanged updates must not touch the responder chain")

        coordinator.updateEditability(true, in: view)
        XCTAssertFalse(view.isEditable)
        await drainMainQueue()
        XCTAssertTrue(view.isEditable)
        XCTAssertTrue(coordinator.textViewShouldBeginEditing(view))
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "x"))
        XCTAssertEqual(view.editabilityAssignments, [false, true])
    }

    func testLatestEditabilityWinsAndDismantleCancelsPendingUIKitWork() async {
        let view = EditabilityTrackingTextView()
        let controller = ForumEditorController()
        controller.view = view
        let coordinator = ForumTextEditor.Coordinator(
            text: .constant("Draft"), isHTMLSource: .constant(false), isBlog: false, controller: controller
        )
        view.delegate = coordinator
        view.editabilityAssignments = []

        coordinator.updateEditability(false, in: view)
        coordinator.updateEditability(true, in: view)
        await drainMainQueue()
        XCTAssertTrue(view.isEditable)
        XCTAssertTrue(view.editabilityAssignments.isEmpty)

        coordinator.updateEditability(false, in: view)
        coordinator.updateEditability(true, in: view)
        coordinator.updateEditability(false, in: view)
        await drainMainQueue()
        XCTAssertFalse(view.isEditable)
        XCTAssertEqual(view.editabilityAssignments, [false])

        coordinator.updateEditability(true, in: view)
        ForumTextEditor.dismantleUIView(view, coordinator: coordinator)
        await drainMainQueue()
        XCTAssertEqual(view.editabilityAssignments, [false])
        XCTAssertNil(view.delegate)
        XCTAssertNil(controller.view)
        XCTAssertFalse(coordinator.textViewShouldBeginEditing(view))
    }

    func testLiveDisabledEditorPreservesDraftAndCanResumeEditingInBothModes() async throws {
        for mode in [ForumComposerMode.visual, .code] {
            let state = EditabilityState()
            let controller = ForumEditorController()
            let host = UIHostingController(rootView: EditabilityHarness(state: state, mode: mode, controller: controller))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let previousKey = scene?.keyWindow
            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousKey?.makeKeyAndVisible()
            }
            host.view.layoutIfNeeded()
            await waitFor { controller.view != nil }
            let view = try XCTUnwrap(controller.view)
            XCTAssertTrue(view.becomeFirstResponder())
            let renderedDraft = view.text

            state.isEnabled = false
            await waitFor { !view.isEditable }
            XCTAssertFalse(view.isFirstResponder)
            XCTAssertEqual(view.text, renderedDraft)
            XCTAssertEqual(state.text, "[i]Draft[/i]")

            state.isEnabled = true
            await waitFor { view.isEditable }
            XCTAssertTrue(view.becomeFirstResponder())
            view.selectedRange = NSRange(location: view.text.utf16.count, length: 0)
            view.insertText("!")
            await waitFor { state.text.contains("!") }
            XCTAssertEqual(state.text, mode == .visual ? "[i]Draft![/i]" : "[i]Draft[/i]!")
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func waitFor(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor
private final class EditabilityTrackingTextView: UITextView {
    var editabilityAssignments: [Bool] = []
    override var isEditable: Bool {
        get { super.isEditable }
        set {
            editabilityAssignments.append(newValue)
            super.isEditable = newValue
        }
    }
}

@MainActor @Observable
private final class EditabilityState {
    var text = "[i]Draft[/i]"
    var isHTMLSource = false
    var isEnabled = true
}

private struct EditabilityHarness: View {
    @Bindable var state: EditabilityState
    let mode: ForumComposerMode
    let controller: ForumEditorController

    var body: some View {
        ForumTextEditor(text: $state.text, isHTMLSource: $state.isHTMLSource, isBlog: false, mode: mode, controller: controller)
            .disabled(!state.isEnabled)
    }
}
