import SwiftUI
import YamiboXCore

// Owns one request's lifetime and dispatches its parsed response to a business
// screen. Loading and failure transitions do not replace the appearance task.
struct ForumPageScreen: View {
    @State private var model: ForumPageSession
    @State private var editorRegistry: ForumEditorRegistry
    @Environment(\.forumTheme) private var theme
    let onURLTap: (URL) -> Void
    let onSubmissionSucceeded: ((TransientFeedback) -> Void)?
    let onNavigationResult: (ForumPageLoadResult) -> Void

    init(model: ForumPageSession, editorRegistry: ForumEditorRegistry? = nil,
         onSubmissionSucceeded: ((TransientFeedback) -> Void)? = nil,
         onNavigationResult: @escaping (ForumPageLoadResult) -> Void = { _ in }, onURLTap: @escaping (URL) -> Void) {
        _model = State(wrappedValue: model)
        _editorRegistry = State(wrappedValue: editorRegistry ?? ForumEditorRegistry())
        self.onURLTap = onURLTap
        self.onSubmissionSucceeded = onSubmissionSucceeded
        self.onNavigationResult = onNavigationResult
    }

    var body: some View {
        ZStack { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(model.page?.title ?? L10n.string("forum.native.title"))
            .yamiboInlineNavigationTitleDisplayMode()
            .forumPageBackground()
            .tint(theme.accentText)
            .accessibilityIdentifier("forum-native-page")
            .transientMessage(model.transientFeedback) { model.transientFeedback = nil }
            .task { await model.load() }
            .sheet(isPresented: Binding(get: { model.page == nil && model.showsDrafts }, set: { if !$0 { model.showsDrafts = false } })) {
                ForumComposerDraftList(model: model)
            }
            .onChange(of: model.navigationResult) { _, result in
                guard let result else { return }
                model.navigationResult = nil
                onNavigationResult(result)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let document = model.page {
            switch document.purpose {
            case .postEditor:
                ForumPostEditorView(model: model, document: document, editorRegistry: editorRegistry,
                                    onSubmissionSucceeded: onSubmissionSucceeded, onURLTap: onURLTap)
            case .blogEditor:
                ForumBlogEditorView(model: model, document: document, editorRegistry: editorRegistry,
                                    onSubmissionSucceeded: onSubmissionSucceeded, onURLTap: onURLTap)
            case .actionForm:
                ForumActionFormView(model: model, document: document, editorRegistry: editorRegistry, onURLTap: onURLTap)
            case .document:
                List { ForumPageStatusSections(document: document, onURLTap: onURLTap) }
                    .refreshable { await model.refresh() }
            }
        } else if model.isLoading {
            ContentLoadingView(layout: .fillsPage)
        } else if model.requiresLoadConfirmation {
            ContentUnavailableView {
                Label(L10n.string("forum.native.confirm_action"), systemImage: "hand.raised")
            } description: {
                Text(L10n.string("forum.native.confirm_load"))
            } actions: {
                Button(L10n.string("forum.native.continue")) { Task { await model.load(confirmedAction: true) } }
                    .buttonStyle(.borderedProminent)
            }
        } else if let message = model.errorMessage {
            VStack(spacing: 16) {
                LoadFailureView(message: message, details: model.errorDetails, prominentRetry: true) {
                    Task { await model.load() }
                }
                if model.errorDetails?.requiresAuthentication == true {
                    Button(L10n.string("mine.web_login")) { onURLTap(YamiboRoute.login.url) }
                }
                if model.composerDraft.active == true {
                    Button(L10n.string("forum.composer.drafts"), systemImage: "doc.on.doc") { Task { await model.openDrafts() } }
                }
            }
            .padding()
        } else {
            ContentLoadingView(layout: .fillsPage)
        }
    }
}
