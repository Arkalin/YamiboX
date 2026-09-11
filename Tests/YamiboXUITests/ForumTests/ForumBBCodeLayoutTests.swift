import SwiftUI
import UIKit
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class ForumBBCodeLayoutTests: XCTestCase {
    func testEditorAndNativePanelsAtPhoneAndTabletSizes() async throws {
        for width: CGFloat in [320, 390, 834] {
            for large in [false, true] {
                let controller = ForumEditorController()
                let source = "[b]BBCode 正文[/b] [ruby=ふりがな]注音[/ruby]\n[list=1][*]第一项[*]第二项[/list]\n[collapse=1,折叠标题][i]折叠内文[/i][/collapse]\n[table][tr][td]甲[/td][td]乙[/td][/tr][/table]"
                let context = ForumComposerContext(target: .init(kind: .newThread), bbcode: .allowed)
                let root = AnyView(NavigationStack {
                    Form {
                        Section("主题") { Text("原生编辑器验收") }
                        Section {
                            ForumBBCodeEditor(text: .constant(source), controller: controller, composerContext: context,
                                              onDrafts: {}, draftStatus: L10n.string("forum.composer.draft_saved"))
                        }
                    }.navigationTitle("发帖").navigationBarTitleDisplayMode(.inline)
                }.environment(\.dynamicTypeSize, large ? .accessibility3 : .large))
                let fixture = await mount(root, size: CGSize(width: width, height: width > 600 ? 1100 : 844), dark: large)
                defer { fixture.close() }
                let body = try XCTUnwrap(controller.bbcodeSession.view)
                XCTAssertNotNil(body.textLayoutManager)
                XCTAssertTrue(body.text.contains("BBCode 正文"))
                XCTAssertLessThanOrEqual(body.frame.width, width)
                XCTAssertGreaterThan(body.frame.width, width - 120)
                XCTAssertEqual(body.accessibilityLabel, L10n.string("forum.native.message"))
                let previews = descendants(of: body).compactMap { $0 as? ForumBBCodePreviewControl }
                for preview in previews where [.table, .collapse].contains(preview.attachment.node.tag) {
                    XCTAssertGreaterThan(preview.bounds.width, body.bounds.width * 0.7, "Block preview must use the text column, not default attachment bounds")
                }
                try snapshot(fixture.host.view, name: "editor-\(Int(width))-\(large ? "dark-large" : "light")")

                controller.bbcodeSession.insertNode(.table)
                let tableRequest = try XCTUnwrap(controller.bbcodeSession.nodeRequest)
                controller.bbcodeSession.cancelNodeEditing()
                let panel = await mount(AnyView(ForumComposerNodePanel(request: tableRequest, session: controller.bbcodeSession)
                    .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)), size: fixture.window.bounds.size, dark: large)
                try snapshot(panel.host.view, name: "table-panel-\(Int(width))-\(large ? "dark-large" : "light")")
                panel.close()

                controller.bbcodeSession.insertNode(.hide)
                let hideRequest = try XCTUnwrap(controller.bbcodeSession.nodeRequest)
                controller.bbcodeSession.cancelNodeEditing()
                let hidePanel = await mount(AnyView(ForumComposerNodePanel(request: hideRequest, session: controller.bbcodeSession)
                    .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)), size: fixture.window.bounds.size, dark: large)
                try snapshot(hidePanel.host.view, name: "hide-panel-\(Int(width))-\(large ? "dark-large" : "light")")
                hidePanel.close()

                let fullscreenController = ForumEditorController()
                fullscreenController.bbcodeSession.isFullScreen = true
                let fullscreen = await mount(AnyView(ForumBBCodeFullScreen(text: .constant(source), controller: fullscreenController, composerContext: context, parsesBBCode: true, parsesEmoticons: true)
                    .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)), size: fixture.window.bounds.size, dark: large)
                XCTAssertNotNil(fullscreenController.bbcodeSession.view?.textLayoutManager)
                try snapshot(fullscreen.host.view, name: "fullscreen-\(Int(width))-\(large ? "dark-large" : "light")")
                fullscreen.close()
                await settle()
                XCTAssertEqual(controller.bbcodeSession.source, source)
            }
        }
    }

    func testLongTextKitDocumentDoesNotRebuildForOrdinaryTyping() async throws {
        let block = "[collapse=1,title]body[/collapse]\n"
        let seed = String(repeating: "paragraph 中文\n" + block, count: 200)
        let source = seed + String(repeating: "x", count: 100_000 - seed.utf16.count)
        let buffer = BBCodeLayoutBuffer(source)
        let controller = ForumEditorController()
        let fixture = await mount(AnyView(ForumBBCodeEditor(text: Binding(get: { buffer.source }, set: { buffer.source = $0 }), controller: controller)), size: CGSize(width: 390, height: 844), dark: false)
        defer { fixture.close() }
        let session = controller.bbcodeSession
        let view = try XCTUnwrap(session.view)
        let attachment = try XCTUnwrap(session.projection.spans.first { $0.kind == .atomic }.flatMap { session.attachment(for: $0) })
        view.selectedRange = NSRange(location: 5, length: 0)
        session.captureSelection()
        var timings: [Double] = []
        for _ in 0..<30 {
            let start = ContinuousClock.now
            view.insertText("a")
            view.delegate?.textViewDidChange?(view)
            let duration = start.duration(to: .now)
            timings.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
        }
        let current = try XCTUnwrap(session.projection.spans.first { $0.kind == .atomic }.flatMap { session.attachment(for: $0) })
        XCTAssertTrue(current === attachment)
        XCTAssertEqual(session.source.utf16.count, 100_030)
        let p95 = timings.sorted()[28]
        let result = XCTAttachment(string: "TextKit 2; \(UIDevice.current.model); \(UIDevice.current.systemVersion); UTF16=100000; complex=200; typing_p95_ms=\(p95)")
        result.name = "bbcode-textkit-performance"; result.lifetime = .keepAlways; add(result)
        print("BBCode TextKit typing_p95_ms=\(p95)")
        #if !DEBUG
        XCTAssertLessThanOrEqual(p95, 50)
        #endif
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(250)) }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func mount(_ view: AnyView, size: CGSize, dark: Bool) async -> BBCodeLayoutWindow {
        let host = UIHostingController(rootView: view.environment(\.horizontalSizeClass, size.width > 600 ? .regular : .compact))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previous = scene?.keyWindow
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        host.traitOverrides.horizontalSizeClass = size.width > 600 ? .regular : .compact
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        await settle()
        host.view.layoutIfNeeded()
        return .init(window: window, host: host, previous: previous)
    }

    private func snapshot(_ view: UIView, name: String) throws {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { view.layer.render(in: $0.cgContext) }
        let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(pixels).count, 16)
        let result = XCTAttachment(image: image); result.name = "bbcode-" + name; result.lifetime = .keepAlways; add(result)
    }
}

@MainActor
private final class BBCodeLayoutBuffer {
    var source: String
    init(_ source: String) { self.source = source }
}

@MainActor
private struct BBCodeLayoutWindow {
    let window: UIWindow
    let host: UIViewController
    let previous: UIWindow?
    func close() { host.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
}
