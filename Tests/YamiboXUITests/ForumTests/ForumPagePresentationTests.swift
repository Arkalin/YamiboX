import SwiftUI
import WebKit
import XCTest
import YamiboXCore
@testable import YamiboXUI

final class ForumPagePresentationTests: XCTestCase {
    @MainActor
    func testReplyColdEntryLoadsNativeComposerOnPhoneAndTabletWithoutWebView() async throws {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1194)] {
            let repository = NativePresentationRepository(page: Self.formPage)
            let model = ForumPageSession(url: Self.pageURL, repository: repository)
            XCTAssertNil(model.page)
            XCTAssertFalse(model.isLoading)
            XCTAssertFalse(model.requiresLoadConfirmation)
            let fixture = await mount(model, size: size)
            defer { fixture.close() }
            await waitFor { model.page != nil }
            fixture.host.view.layoutIfNeeded()

            let textViews = descendants(fixture.host.view).compactMap { $0 as? UITextView }
            let editor = try XCTUnwrap(textViews.first { $0.isEditable && $0.text.contains("Synthetic draft") })
            let editorFrame = editor.convert(editor.bounds, to: fixture.host.view)
            XCTAssertGreaterThan(editorFrame.width, 100)
            XCTAssertGreaterThanOrEqual(editorFrame.minX, 0)
            XCTAssertLessThanOrEqual(editorFrame.maxX, size.width)
            editor.text = "Edited synthetic draft"
            editor.delegate?.textViewDidChange?(editor)
            XCTAssertEqual(model.drafts["thread"]?["message"], ["Edited synthetic draft"])
            let form = try XCTUnwrap(model.page?.forms.first)
            let button = try XCTUnwrap(form.buttons.first)
            model.prepareSubmission(form: form, button: button)
            XCTAssertNotNil(model.pendingSubmission)
            model.pendingSubmission = nil
            XCTAssertTrue(descendants(fixture.host.view).contains { $0 is UICollectionView })
            try attach(fixture.host.view, name: "native-composer-\(Int(size.width))")
            let counts = await repository.counts
            XCTAssertEqual(counts, .init(started: 1, completed: 1))
        }
    }

    @MainActor
    func testExplicitStatusRendersInDarkLargeTypeWithoutWebView() async throws {
        let page = ForumPageDocument(url: Self.pageURL, title: "Status", message: "An explicit server status message wraps across multiple lines on a phone.")
        for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1194)] {
            let repository = NativePresentationRepository(page: page)
            let model = ForumPageSession(url: Self.pageURL, repository: repository)
            let fixture = await mount(model, size: size, scheme: .dark, typeSize: .accessibility3)
            defer { fixture.close() }
            await waitFor { model.page != nil }
            fixture.host.view.layoutIfNeeded()
            try attach(fixture.host.view, name: "native-article-dark-large-\(Int(size.width))")
            let counts = await repository.counts
            XCTAssertEqual(counts, .init(started: 1, completed: 1))
        }
    }

    @MainActor
    func testColdEntryFailureShowsNativeRetryContentWithoutAutomaticRetry() async throws {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1194)] {
            let repository = NativePresentationRepository(page: Self.formPage, failure: true)
            let model = ForumPageSession(url: Self.pageURL, repository: repository)
            let fixture = await mount(model, size: size)
            defer { fixture.close() }
            await waitFor { model.errorMessage != nil }
            fixture.host.view.layoutIfNeeded()
            try attach(fixture.host.view, name: "native-error-\(Int(size.width))")
            XCTAssertNotNil(model.errorMessage)
            XCTAssertFalse(model.isLoading)
            XCTAssertNil(model.page)
            let counts = await repository.counts
            XCTAssertEqual(counts, .init(started: 1, failed: 1))
        }
    }

    @MainActor
    func testActionConfirmationRemainsNativeAndDoesNotRequestBeforeConsent() async throws {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1194)] {
            let repository = NativePresentationRepository(page: Self.formPage)
            let actionURL = try XCTUnwrap(URL(string: "https://bbs.yamibo.com/home.php?mod=spacecp&ac=friend&op=delete&uid=123"))
            let confirmationModel = ForumPageSession(url: actionURL, repository: repository)
            XCTAssertTrue(confirmationModel.requiresLoadConfirmation)
            let confirmation = await mount(confirmationModel, size: size)
            defer { confirmation.close() }
            try await Task.sleep(for: .milliseconds(300))
            try attach(confirmation.host.view, name: "native-load-confirmation-\(Int(size.width))")
            XCTAssertNil(confirmationModel.page)
            let counts = await repository.counts
            XCTAssertEqual(counts, .init())
        }
    }

    @MainActor
    func testDelayedColdEntryLoadsExactlyOnceAcrossLoadingAndContentBranches() async throws {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1194)] {
            let loadingRepository = NativePresentationRepository(page: Self.formPage, delays: [.milliseconds(700)])
            let loadingModel = ForumPageSession(url: Self.pageURL, repository: loadingRepository)
            let loading = await mount(loadingModel, size: size)
            defer { loading.close() }
            await waitFor { loadingModel.isLoading }
            XCTAssertTrue(loadingModel.isLoading)
            XCTAssertNil(loadingModel.page)
            try attach(loading.host.view, name: "native-loading-\(Int(size.width))")
            await waitFor { loadingModel.page != nil }
            loading.host.view.layoutIfNeeded()
            XCTAssertFalse(loadingModel.isLoading)
            XCTAssertNil(loadingModel.errorMessage)
            let counts = await loadingRepository.counts
            XCTAssertEqual(counts, .init(started: 1, completed: 1))
        }
    }

    @MainActor
    func testLeavingDuringLoadCancelsAndRemountingStartsFreshAppearanceLoad() async throws {
        let repository = NativePresentationRepository(page: Self.formPage, delays: [.seconds(60), .milliseconds(200)])
        let model = ForumPageSession(url: Self.pageURL, repository: repository)
        let initial = await mount(model, size: CGSize(width: 390, height: 844))
        await waitFor { model.isLoading }
        initial.close()
        await waitFor { !model.isLoading }
        XCTAssertNil(model.page)
        XCTAssertNil(model.errorMessage)
        let cancelled = await repository.counts
        XCTAssertEqual(cancelled, .init(started: 1, cancelled: 1))

        let returned = await mount(model, size: CGSize(width: 390, height: 844))
        defer { returned.close() }
        await waitFor { model.page != nil }
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        let completed = await repository.counts
        XCTAssertEqual(completed, .init(started: 2, completed: 1, cancelled: 1))
        returned.host.view.layoutIfNeeded()
        try attach(returned.host.view, name: "native-reply-after-cancel-and-return")
    }

    @MainActor
    private func waitFor(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Expected appearance-driven state transition did not occur", file: file, line: line)
    }

    @MainActor
    private func mount(
        _ model: ForumPageSession, size: CGSize,
        scheme: ColorScheme = .light, typeSize: DynamicTypeSize = .large
    ) async -> Fixture {
        let host = UIHostingController(rootView: AnyView(NavigationStack {
            ForumPageScreen(model: model, onURLTap: { _ in XCTFail("Synthetic fixtures must not navigate to the network") })
                .forumNavigationBarStyle()
        }
        .environment(\.colorScheme, scheme)
        .environment(\.dynamicTypeSize, typeSize)
        .environment(\.horizontalSizeClass, size.width > 600 ? .regular : .compact)))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKeyWindow = scene?.keyWindow
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        host.traitOverrides.horizontalSizeClass = size.width > 600 ? .regular : .compact
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        return Fixture(window: window, host: host, previousKeyWindow: previousKeyWindow)
    }

    @MainActor
    private func attach(_ view: UIView, name: String) throws {
        XCTAssertTrue(descendants(view).allSatisfy { !($0 is WKWebView) }, "Internal pages must contain no embedded browser")
        let hierarchy = XCTAttachment(string: descendants(view).map {
            "\(type(of: $0)) frame=\($0.convert($0.bounds, to: view)) id=\($0.accessibilityIdentifier ?? "") label=\($0.accessibilityLabel ?? "")"
        }.joined(separator: "\n"))
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(pixels).count, 16, "The fixture must render visible content")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private struct Fixture {
        let window: UIWindow
        let host: UIHostingController<AnyView>
        let previousKeyWindow: UIWindow?

        func close() {
            host.dismiss(animated: false)
            // Remove the production view, rather than retain its appearance task offscreen.
            host.rootView = AnyView(EmptyView())
            host.view.layoutIfNeeded()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
    }

    private static let pageURL = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=reply&fid=21&tid=123")!
    private static var formPage: ForumPageDocument {
        ForumPageDocument(url: pageURL, title: "Reply to thread", forms: [
            ForumForm(id: "thread", title: "New thread", actionURL: pageURL, kind: .thread, fields: [
                .init(id: "subject", name: "subject", label: "Subject", initialValues: ["Synthetic title"], isRequired: true),
                .init(id: "message", name: "message", label: "Message", kind: .multiline, initialValues: ["Synthetic draft. No live request is permitted."], isRequired: true),
                .init(id: "type", name: "typeid", label: "Category", kind: .choice, initialValues: ["1"], options: [.init(value: "1", label: "Discussion"), .init(value: "2", label: "Questions")]),
                .init(id: "notify", name: "notify", label: "Notify replies", kind: .toggle, initialValues: [], options: [.init(value: "1", label: "Notify replies")])
            ], buttons: [.init(id: "submit", title: "Publish")])
        ])
    }
}

private actor NativePresentationRepository: ForumPageLoading {
    struct Counts: Equatable, Sendable {
        var started = 0
        var completed = 0
        var cancelled = 0
        var failed = 0
        var submissions = 0
        var uploads = 0
    }

    let page: ForumPageDocument
    let failure: Bool
    let delays: [Duration]
    private(set) var counts = Counts()

    init(page: ForumPageDocument, failure: Bool = false, delays: [Duration] = []) {
        self.page = page
        self.failure = failure
        self.delays = delays
    }

    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageLoadResult {
        let index = counts.started
        counts.started += 1
        do {
            if delays.indices.contains(index) { try await Task.sleep(for: delays[index]) }
            if failure { throw URLError(.notConnectedToInternet) }
            counts.completed += 1
            return .page(page)
        } catch is CancellationError {
            counts.cancelled += 1
            throw CancellationError()
        } catch {
            counts.failed += 1
            throw error
        }
    }

    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageLoadResult {
        counts.submissions += 1
        XCTFail("Presentation fixtures must never submit")
        throw ForumPageError.invalidForm
    }

    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment {
        counts.uploads += 1
        XCTFail("Presentation fixtures must never upload")
        throw ForumPageError.unsupportedUpload
    }
}
