import SwiftUI
import YamiboXCore

struct ForumTagView: View {
    @Environment(\.forumTheme) private var theme
    @Environment(\.forumBlacklist) private var blacklist
    @State private var model: ForumTagViewModel
    @State private var query = ""
    let onTagTap: (ForumTagTarget) -> Void
    let onThreadTap: (ForumThreadSummary) -> Void
    let onAuthorTap: (String, String?) -> Void

    init(model: ForumTagViewModel, onTagTap: @escaping (ForumTagTarget) -> Void,
         onThreadTap: @escaping (ForumThreadSummary) -> Void, onAuthorTap: @escaping (String, String?) -> Void) {
        _model = State(wrappedValue: model)
        self.onTagTap = onTagTap
        self.onThreadTap = onThreadTap
        self.onAuthorTap = onAuthorTap
    }

    var body: some View {
        ForumKeyboardBrowser(threadIDs: visibleThreads.map(\.tid), onOpen: { id in
            if let thread = visibleThreads.first(where: { $0.tid == id }) { onThreadTap(thread) }
        }) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Color.clear.frame(height: 0).id("tags-top")
                        if model.target == .index { searchInput }
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .refreshableWithTopIndicator(isRefreshing: model.isLoading && model.page != nil) {
                    await model.refresh()
                }
                .onChange(of: model.currentPage) { _, _ in proxy.scrollTo("tags-top", anchor: .top) }
            }
        }
        .forumPageBackground()
        .tint(theme.accentText)
        .navigationTitle(title)
        .yamiboInlineNavigationTitleDisplayMode()
        .toolbar {
            if model.target != .index {
                ToolbarItem(placement: .primaryAction) {
                    Button { onTagTap(.index) } label: { Image(systemName: "tag") }
                        .accessibilityLabel(L10n.string("forum.tags.title"))
                }
            }
        }
        .task { await model.load() }
        .onDisappear { model.cancel() }
    }

    private var title: String {
        if let name = model.page?.tag?.name { return name }
        if case let .name(name) = model.target { return name }
        return L10n.string("forum.tags.title")
    }

    private var searchInput: some View {
        HStack(spacing: 10) {
            TextField(L10n.string("forum.tags.search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit(search)
            Button(action: search) { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderedProminent)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(L10n.string("common.search"))
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.page == nil {
            ContentLoadingView(text: L10n.string("common.loading"))
        } else if let error = model.errorMessage, model.page == nil {
            failure(error)
        } else if let page = model.page {
            if let error = model.errorMessage { failure(error) }
            if model.target == .index {
                if page.tags.isEmpty {
                    empty(L10n.string("forum.tags.empty"))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 12) {
                        ForEach(page.tags) { tag in
                            Button { onTagTap(.id(tag.id)) } label: {
                                Label(tag.name, systemImage: "tag")
                                    .font(.body)
                                    .foregroundStyle(theme.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .forumCardBackground()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text(L10n.string("forum.tags.related_threads"))
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                if page.threads.isEmpty { empty(L10n.string("forum.tags.no_threads")) }
                if !page.threads.isEmpty && visibleThreads.isEmpty { ForumBlacklistEmptyView() }
                ForEach(visibleThreads) { thread in
                    ForumThreadSummaryRowView(thread: thread, onThreadTap: { onThreadTap(thread) }, onAuthorTap: onAuthorTap)
                }
                ForumPageNavigationBar(navigation: page.pageNavigation, currentPage: model.currentPage, goToPage: { number in
                    Task { await model.goToPage(number) }
                }, hidesOnSinglePage: true)
                    .disabled(model.isLoading)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        LoadFailureView(message: message, details: model.errorDetails) { Task { await model.retry() } }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private var visibleThreads: [ForumThreadSummary] {
        (model.page?.threads ?? []).filter { blacklist?.contains($0.authorID) != true }
    }

    private func empty(_ message: String) -> some View {
        ContentUnavailableView(message, systemImage: "tag")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private func search() {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onTagTap(.name(name))
    }
}
