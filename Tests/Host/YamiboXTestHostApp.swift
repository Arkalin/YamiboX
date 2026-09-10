import SwiftUI
import UIKit
@testable import YamiboXCore
@testable import YamiboXUI

// A scene-backed host without application services, networking, or persisted user state.
@main
struct YamiboXTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["FORUM_ATTACHMENT_UPLOAD_FIXTURE"] == "1" {
                ForumPhotoUploadFixture(attachmentFixture: true)
            } else if ProcessInfo.processInfo.environment["FORUM_PHOTO_UPLOAD_FIXTURE"] == "1" {
                ForumPhotoUploadFixture()
            } else if ProcessInfo.processInfo.environment["FORUM_SEND_CRASH_FIXTURE"] == "1" {
                ForumSendCrashFixture()
            } else {
                MangaLongPressFixture()
            }
        }
    }
}

private struct ForumPhotoUploadFixture: View {
    @State private var model: ForumPageSession
    @State private var counts: ForumPhotoUploadCounts

    init(attachmentFixture: Bool = false) {
        if attachmentFixture {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try! FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try! Data("Offline attachment fixture.\n".utf8).write(to: documents.appendingPathComponent("offline-attachment.txt"), options: .atomic)
        }
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=reply&tid=123&mobile=2")!
        let html = """
        <html><head><title>Offline Photo Upload</title></head><body>
        <form id="postform" method="post" action="forum.php?mod=post&amp;action=reply&amp;tid=123&amp;replysubmit=yes&amp;mobile=2">
        <input type="hidden" name="formhash" value="offline-fixture">
        <textarea name="message" id="message">Offline photo draft</textarea>
        <button type="submit" name="replysubmit" value="yes">Send Reply</button>
        </form></body></html>
        """
        let parsed = try! ForumPageParser.parse(html: html, url: url)
        let configurations = attachmentFixture ? [
            ForumUploadConfiguration(id: "offline-attachment", url: url, kind: .threadAttachment, values: [], maximumBytes: 5 * 1_024 * 1_024, extensions: ["txt", "pdf", "jpg"])
        ] : [
            ForumUploadConfiguration(id: "offline-image", url: url, kind: .threadImage, values: [], maximumBytes: 5 * 1_024 * 1_024, extensions: ["jpg", "jpeg", "png", "gif"]),
            ForumUploadConfiguration(id: "offline-attachment", url: url, kind: .threadAttachment, values: [], maximumBytes: 5 * 1_024 * 1_024, extensions: ["jpg", "jpeg", "png", "gif"])
        ]
        let page = ForumPageDocument(url: url, title: parsed.title, forms: parsed.forms, uploads: configurations)
        let counts = ForumPhotoUploadCounts()
        _counts = State(wrappedValue: counts)
        _model = State(wrappedValue: ForumPageSession(url: url, repository: ForumPhotoUploadRepository(page: page, counts: counts)))
    }

    var body: some View {
        NavigationStack {
            ForumPageScreen(model: model, onURLTap: { _ in })
                .forumNavigationBarStyle()
                .safeAreaInset(edge: .bottom) {
                    Text(verbatim: "uploads=\(counts.uploads);mime=\(counts.mimeType);bytes=\(counts.byteCount)")
                        .font(.caption2)
                        .accessibilityIdentifier("forum-photo-upload-diagnostics")
                }
        }
    }
}

@MainActor @Observable private final class ForumPhotoUploadCounts {
    var uploads = 0
    var mimeType = "none"
    var byteCount = 0
}

private actor ForumPhotoUploadRepository: ForumPageLoading {
    let page: ForumPageDocument
    let counts: ForumPhotoUploadCounts

    init(page: ForumPageDocument, counts: ForumPhotoUploadCounts) {
        self.page = page
        self.counts = counts
    }

    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageDocument { page }

    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageDocument {
        throw NSError(domain: "OfflinePhotoFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Posting is disabled in the photo fixture"])
    }

    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment {
        await MainActor.run {
            counts.uploads += 1
            counts.mimeType = mimeType
            counts.byteCount = file.data.count
        }
        let markup = configuration.kind == .threadAttachment ? "[attach]999001[/attach]" : "[attachimg]999001[/attachimg]"
        return ForumUploadedAttachment(id: "999001", name: file.name, markup: markup, values: [])
    }
}

private struct ForumSendCrashFixture: View {
    @State private var model: ForumPageSession
    @State private var counts: ForumSendCrashCounts
    @State private var showsComposer = false
    @State private var feedback: TransientFeedback?

    init() {
        let action = ProcessInfo.processInfo.environment["FORUM_SEND_ACTION"] ?? "reply"
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=\(action)&tid=123&pid=456&mobile=2")!
        let source = ProcessInfo.processInfo.environment["FORUM_SEND_INITIAL_SOURCE"] ?? ""
        let firstPost = ProcessInfo.processInfo.environment["FORUM_SEND_FIRST_POST"] == "1"
        let html = """
        <html><head><title>Offline Reply</title></head><body>
        <script>var isfirstpost = \(firstPost ? "1" : "0");</script>
        <form id="postform" method="post" action="forum.php?mod=post&amp;action=\(action)&amp;tid=123&amp;pid=456&amp;replysubmit=yes&amp;mobile=2">
        <input type="hidden" name="formhash" value="offline-fixture">
        <input type="text" name="subject" id="needsubject" value="Offline Subject">
        <textarea name="message" id="message">\(source)</textarea>
        <button type="submit" name="replysubmit" value="yes">Send Reply</button>
        </form></body></html>
        """
        let page = try! ForumPageParser.parse(html: html, url: url)
        let counts = ForumSendCrashCounts()
        _counts = State(wrappedValue: counts)
        _model = State(wrappedValue: ForumPageSession(url: url, repository: ForumSendCrashRepository(page: page, counts: counts)))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Offline Previous Page")
                    .accessibilityIdentifier("forum-feedback-previous-page")
                Button("Open Editor") { showsComposer = true }
                    .accessibilityIdentifier("forum-feedback-open-editor")
                diagnostics
            }
            .navigationTitle("Offline Thread")
            .navigationDestination(isPresented: $showsComposer) {
                ForumPageScreen(model: model, onSubmissionSucceeded: { feedback = $0 }, onURLTap: { _ in })
                    .forumNavigationBarStyle()
                    .safeAreaInset(edge: .bottom) { diagnostics }
            }
        }
        .transientMessage(feedback) { feedback = nil }
    }

    private var diagnostics: some View {
        Text(verbatim: "pending=\(model.pendingSubmission != nil);submitting=\(model.isSubmitting);success=\(model.submissionSucceeded);count=\(counts.submissions)")
            .font(.caption2)
            .accessibilityIdentifier("forum-send-diagnostics")
    }
}

@MainActor @Observable private final class ForumSendCrashCounts {
    var submissions = 0
}

private actor ForumSendCrashRepository: ForumPageLoading {
    let page: ForumPageDocument
    let counts: ForumSendCrashCounts
    init(page: ForumPageDocument, counts: ForumSendCrashCounts) { self.page = page; self.counts = counts }
    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageDocument { page }
    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageDocument {
        let attempt = await MainActor.run { counts.submissions += 1; return counts.submissions }
        try await Task.sleep(for: .seconds(1))
        if ProcessInfo.processInfo.environment["FORUM_SEND_FAIL"] == "1", attempt == 1 {
            throw NSError(domain: "OfflineFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offline submission failed"])
        }
        return ForumPageDocument(url: page.url, title: "Offline Result", message: "Offline submission captured 发表成功")
    }
    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment {
        throw ForumPageError.unsupportedUpload
    }
}

private struct MangaLongPressFixture: View {
    @State private var surface = MangaSurfaceAttachment()
    @State private var menuCount = 0
    private let image: UIImage

    init() {
        let width = Double(ProcessInfo.processInfo.environment["MANGA_TEST_IMAGE_WIDTH"] ?? "400") ?? 400
        let size = CGSize(width: width, height: 800)
        image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            MangaPagedReaderScaledImage(
                image: image, pageID: "layout", pageScaleMode: .fitHeight,
                initialHorizontalAlignment: .left, pageEdgeFillStyle: .system,
                isSurfaceInteractionEnabled: true, isZoomInteractionEnabled: true,
                allowsUnzoomedSurfacePan: true, surfaceInteraction: surface,
                onLongPress: { menuCount += 1 }
            )
            .frame(width: 400, height: 800)

            Text(diagnostics)
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black)
                .accessibilityIdentifier("manga-diagnostics")
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var diagnostics: String {
        let runtime = surface.runtime
        let values: [String: Double] = [
            "count": Double(menuCount),
            "loaded": runtime.imageLoaded ? 1 : 0,
            "viewportWidth": runtime.geometry.viewport.width,
            "viewportHeight": runtime.geometry.viewport.height,
            "menuMidX": runtime.menuFrame.midX,
            "menuWidth": runtime.menuFrame.width,
            "offsetX": runtime.transform.offset.width
        ]
        guard let data = try? JSONEncoder().encode(values) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
