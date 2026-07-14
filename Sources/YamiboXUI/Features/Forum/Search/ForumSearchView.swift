import SwiftUI
import YamiboXCore

struct ForumSearchView: View {
    @State private var model: ForumSearchViewModel

    let onThreadTap: (ForumThreadSummary) -> Void
    let onAuthorTap: (String, String?) -> Void
    let onURLSubmit: (URL) -> Void

    init(
        model: ForumSearchViewModel,
        onThreadTap: @escaping (ForumThreadSummary) -> Void,
        onAuthorTap: @escaping (String, String?) -> Void,
        onURLSubmit: @escaping (URL) -> Void
    ) {
        _model = State(wrappedValue: model)
        self.onThreadTap = onThreadTap
        self.onAuthorTap = onAuthorTap
        self.onURLSubmit = onURLSubmit
    }

    var body: some View {
        ForumSearchBodyView(
            query: $model.query,
            results: model.results,
            resultCountText: model.resultCountText,
            pageNavigation: model.pageNavigation,
            currentPage: model.currentPage,
            isLoading: model.isLoading,
            errorMessage: model.errorMessage,
            submit: submit,
            goToPage: goToPage,
            restorePreviousPage: model.canRestorePreviousPage
                ? { _ = model.restorePreviousPage() }
                : nil,
            onThreadTap: onThreadTap,
            onAuthorTap: onAuthorTap
        )
        .forumPageBackground()
        .tint(ForumColors.brownDeep)
        .navigationTitle(L10n.string("forum.search.title"))
    }

    private func submit() {
        let trimmedQuery = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        if let url = URL(string: trimmedQuery), ["http", "https"].contains(url.scheme?.lowercased()) {
            onURLSubmit(url)
            return
        }

        Task {
            await model.searchFirstPage()
        }
    }

    private func goToPage(_ page: Int) {
        Task {
            await model.goToPage(page)
        }
    }
}

private struct ForumSearchBodyView: View {
    @Binding var query: String

    let results: [ForumThreadSummary]
    let resultCountText: String?
    let pageNavigation: ForumPageNavigation?
    let currentPage: Int
    let isLoading: Bool
    let errorMessage: String?
    let submit: () -> Void
    let goToPage: (Int) -> Void
    let restorePreviousPage: (() -> Void)?
    let onThreadTap: (ForumThreadSummary) -> Void
    let onAuthorTap: (String, String?) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForumSearchInputView(query: $query, isLoading: isLoading, submit: submit)

                if isLoading && results.isEmpty {
                    ForumContentLoadingView(text: L10n.string("forum.search.loading"))
                } else if let errorMessage, results.isEmpty {
                    LoadFailureView(message: errorMessage, retry: submit)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                } else if results.isEmpty {
                    ForumSearchIdleView()
                } else {
                    if let resultCountText {
                        Text(resultCountText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ForumColors.secondaryText)
                    }

                    ForEach(results) { thread in
                        ForumThreadSummaryRowView(
                            thread: thread,
                            onThreadTap: {
                                onThreadTap(thread)
                            },
                            onAuthorTap: onAuthorTap
                        )
                    }

                    if let pageNavigation {
                        ForumPageNavigationBar(
                            navigation: pageNavigation,
                            currentPage: currentPage,
                            goToPage: goToPage,
                            restorePreviousPage: restorePreviousPage
                        )
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .forumPageBackground()
        .tint(ForumColors.brownDeep)
    }
}

private struct ForumSearchInputView: View {
    @Binding var query: String

    let isLoading: Bool
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField(L10n.string("forum.search.placeholder"), text: $query)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .submitLabel(.search)
                .onSubmit(submit)
                .textFieldStyle(.roundedBorder)

            Button(action: submit) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(ForumColors.brownDeep)
            .disabled(isLoading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(L10n.string("common.search"))
        }
    }
}


private struct ForumSearchIdleView: View {
    var body: some View {
        ContentUnavailableView(
            L10n.string("forum.search.idle_title"),
            systemImage: "magnifyingglass",
            description: Text(L10n.string("forum.search.idle_message"))
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}


