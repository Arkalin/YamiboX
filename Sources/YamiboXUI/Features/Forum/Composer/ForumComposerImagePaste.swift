import SwiftUI
import YamiboXCore

struct ForumComposerImageUploadAction: Sendable {
    let configuration: ForumUploadConfiguration
    let isBusy: Bool
    let upload: @MainActor @Sendable (ForumUploadImage, ForumBBCodeSession) async -> Void
}

private struct ForumComposerImageUploadKey: EnvironmentKey {
    static let defaultValue: ForumComposerImageUploadAction? = nil
}

extension EnvironmentValues {
    var forumComposerImageUpload: ForumComposerImageUploadAction? {
        get { self[ForumComposerImageUploadKey.self] }
        set { self[ForumComposerImageUploadKey.self] = newValue }
    }
}

struct ForumComposerImagePaste: ViewModifier {
    let session: ForumBBCodeSession
    var isFullScreen = false
    @Environment(\.forumComposerImageUpload) private var uploadAction
    @State private var handlerID = UUID()
    @State private var request: Request?
    @State private var prepared: ForumUploadImage?
    @State private var preparing = false

    private struct Request: Identifiable {
        let id = UUID()
        let data: Data
        let anchor: UUID
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                if session.isFullScreen == isFullScreen { installHandler() }
            }
            .onChange(of: session.isFullScreen) { _, value in if value == isFullScreen { installHandler() } }
            .onDisappear {
                discard()
                if session.imagePasteHandlerID == handlerID { session.onPasteImage = nil; session.imagePasteHandlerID = nil }
            }
            .task(id: request?.id) {
                guard let request else { return }
                guard let uploadAction, !uploadAction.isBusy else {
                    session.errorMessage = ForumPageError.unsupportedUpload.localizedDescription
                    discard()
                    return
                }
                preparing = true
                defer { preparing = false }
                do {
                    let image = try await ForumUploadImageProcessor.shared.prepare(request.data, configuration: uploadAction.configuration)
                    try Task.checkCancellation()
                    prepared = image
                } catch {
                    if !Task.isCancelled { session.errorMessage = error.localizedDescription; discard() }
                }
            }
            .overlay(alignment: .topTrailing) { if preparing { ProgressView().padding(8).allowsHitTesting(false) } }
            .confirmationDialog(L10n.string("forum.native.upload"), isPresented: Binding(get: { prepared != nil }, set: { if !$0 { discard() } }), titleVisibility: .visible) {
                if let prepared, let request, let uploadAction {
                    Button(L10n.string("forum.native.upload")) {
                        guard let selection = session.bookmarkedSelection(request.anchor) else {
                            session.errorMessage = L10n.string("forum.composer.anchor_missing"); discard(); return
                        }
                        session.restoreState(sourceMode: session.sourceMode, selection: selection)
                        discard()
                        Task { await uploadAction.upload(prepared, session) }
                    }.disabled(uploadAction.isBusy)
                }
                Button(L10n.string("common.cancel"), role: .cancel) { discard() }
            } message: {
                if let prepared {
                    Text(prepared.file.name + "\n" + Int64(prepared.file.data.count).formatted(.byteCount(style: .file)))
                }
            }
    }

    private func installHandler() {
        session.imagePasteHandlerID = handlerID
        session.onPasteImage = { data in
            discard()
            request = .init(data: data, anchor: session.bookmark())
        }
    }

    private func discard() {
        if let request { session.removeBookmark(request.anchor) }
        request = nil; prepared = nil
    }
}
