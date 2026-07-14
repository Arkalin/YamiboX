import SwiftUI
import YamiboXCore
import WebKit

@MainActor
public final class ForumBrowserModel: ObservableObject {
    @Published public private(set) var currentURL: URL?
    @Published public private(set) var pageTitle = ""
    @Published public private(set) var isLoading = false

    private weak var webView: WKWebView?

    public init(initialURL: URL) {
        self.currentURL = initialURL
    }

    public func attach(webView: WKWebView) {
        self.webView = webView
    }

    public func load(_ url: URL) {
        currentURL = url
        webView?.load(URLRequest(url: url))
    }

    public func sync(with webView: WKWebView) {
        currentURL = webView.url ?? currentURL
        pageTitle = webView.title ?? pageTitle
        isLoading = webView.isLoading
    }
}

public struct ForumBrowserView: View {
    @StateObject private var model: ForumBrowserModel
    private let sessionStore: SessionStore
    private let appModel: YamiboAppModel
    private let listensToForumNavigationRequest: Bool

    public init(
        url: URL,
        sessionStore: SessionStore,
        appModel: YamiboAppModel,
        listensToForumNavigationRequest: Bool = true
    ) {
        _model = StateObject(wrappedValue: ForumBrowserModel(initialURL: url))
        self.sessionStore = sessionStore
        self.appModel = appModel
        self.listensToForumNavigationRequest = listensToForumNavigationRequest
    }

    public var body: some View {
        ZStack(alignment: .top) {
            IOSForumWebView(
                model: model,
                sessionStore: sessionStore,
                isSelected: appModel.selectedTab == .forum
            )
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 8)
            }
        }
        .forumPageBackground()
        .tint(ForumColors.brownDeep)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ForumBrowserNavigationTitle(
                    title: model.pageTitle,
                    urlText: model.currentURL?.absoluteString
                )
            }
        }
        .yamiboInlineNavigationTitleDisplayMode()
        .onChange(of: appModel.forumNavigationRequest?.id) { _, _ in
            guard listensToForumNavigationRequest else { return }
            if let request = appModel.forumNavigationRequest {
                model.load(request.url)
            }
        }
    }
}

struct ForumBrowserNavigationTitle: View {
    let title: String
    let urlText: String?

    var body: some View {
        VStack(spacing: 1) {
            Text(resolvedTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(urlText ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("forum-browser-navigation-title")
    }

    private var resolvedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.string("forum.default_title")
            : title
    }
}
