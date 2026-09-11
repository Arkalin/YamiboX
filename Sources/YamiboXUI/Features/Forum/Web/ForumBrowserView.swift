import SwiftUI
import YamiboXCore
import WebKit

@MainActor
public final class ForumBrowserModel: ObservableObject {
    @Published public private(set) var currentURL: URL?
    @Published public private(set) var pageTitle = ""
    @Published public private(set) var isLoading = false

    private weak var webView: WKWebView?
    private let onNativeNavigation: @MainActor (URL) -> Void
    private var suppressesNativeRouting: Bool

    public init(initialURL: URL, nativeFallback: Bool = false, onNativeNavigation: @escaping @MainActor (URL) -> Void = { _ in }) {
        self.currentURL = initialURL
        self.onNativeNavigation = onNativeNavigation
        self.suppressesNativeRouting = nativeFallback
    }

    public func attach(webView: WKWebView) {
        self.webView = webView
    }

    public func load(_ url: URL) {
        guard !shouldRouteNatively(url, method: "GET", isMainFrame: true) else {
            openNative(url)
            return
        }
        currentURL = url
        webView?.load(URLRequest(url: url))
    }

    func rearmNativeRouting() { suppressesNativeRouting = false }

    func shouldRouteNatively(_ url: URL, method: String?, isMainFrame: Bool, isUserLink: Bool = false) -> Bool {
        guard isMainFrame else { return false }
        if isUserLink { rearmNativeRouting() }
        return !suppressesNativeRouting && (method ?? "GET").uppercased() == "GET"
            && ForumRouteResolver.supportsNativePage(url)
    }

    public func openNative(_ url: URL) {
        isLoading = false
        onNativeNavigation(url)
    }

    public func reload() {
        webView?.reload()
    }

    public func sync(with webView: WKWebView) {
        currentURL = webView.url ?? currentURL
        pageTitle = webView.title ?? pageTitle
        isLoading = webView.isLoading
    }
}

public struct ForumBrowserView: View {
    @Environment(\.forumTheme) private var theme
    @StateObject private var model: ForumBrowserModel
    private let sessionStore: SessionStore
    private let appModel: YamiboAppModel
    private let listensToForumNavigationRequest: Bool

    public init(
        url: URL,
        sessionStore: SessionStore,
        appModel: YamiboAppModel,
        listensToForumNavigationRequest: Bool = true,
        nativeFallback: Bool = false,
        onNativeNavigation: (@MainActor (URL) -> Void)? = nil
    ) {
        _model = StateObject(wrappedValue: ForumBrowserModel(initialURL: url, nativeFallback: nativeFallback, onNativeNavigation: onNativeNavigation ?? { appModel.openForumURL($0) }))
        self.sessionStore = sessionStore
        self.appModel = appModel
        self.listensToForumNavigationRequest = listensToForumNavigationRequest
    }

    public var body: some View {
        ZStack(alignment: .top) {
            IOSForumWebView(
                model: model,
                sessionStore: sessionStore,
                isSelected: true
            )
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 8)
            }
        }
        .forumPageBackground()
        .tint(theme.accentText)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ForumBrowserNavigationTitle(
                    title: model.pageTitle,
                    urlText: model.currentURL?.absoluteString
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: model.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(L10n.string("common.refresh"))
                .help(L10n.string("common.refresh"))
                .accessibilityIdentifier("forum-browser-refresh")
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
    @Environment(\.forumTheme) private var theme
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
