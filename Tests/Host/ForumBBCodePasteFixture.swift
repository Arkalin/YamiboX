import SwiftUI
import UIKit
import UniformTypeIdentifiers
@testable import YamiboXCore
@testable import YamiboXUI

struct ForumBBCodePasteFixture: View {
    @State private var source = "Before image"
    @State private var uploads = 0
    @State private var controller = ForumEditorController()
    private let boardName = UIPasteboard.Name("bbcode-paste-fixture-" + UUID().uuidString)
    private let configuration = ForumUploadConfiguration(id: "offline", url: YamiboDomain.baseURL,
        kind: .threadImage, values: [], maximumBytes: 1_000_000, extensions: ["png", "jpg"])

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ForumBBCodeEditor(text: $source, controller: controller,
                                  composerContext: .init(target: .init(kind: .reply), bbcode: .allowed, images: .allowed))
                Button("粘贴测试图片", action: pasteImage).accessibilityIdentifier("bbcode-paste-fixture-image")
                Text("uploads=\(uploads)").accessibilityIdentifier("bbcode-paste-fixture-count")
            }
            .padding()
            .navigationTitle("图片粘贴测试")
        }
        .environment(\.forumComposerImageUpload, ForumComposerImageUploadAction(configuration: configuration, isBusy: false) { _, editor in
            uploads += 1
            let anchor = editor.bookmark()
            _ = editor.insertMarkup("[attachimg]999002[/attachimg]", at: anchor)
        })
        .onDisappear { UIPasteboard.remove(withName: boardName) }
    }

    private func pasteImage() {
        guard let view = controller.bbcodeSession.view, let board = UIPasteboard(name: boardName, create: true) else { return }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        guard let data = image.pngData() else { return }
        board.setItems([[UTType.png.identifier: data]], options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(600)])
        view.pasteboard = board
        view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
        view.paste(nil)
    }
}
