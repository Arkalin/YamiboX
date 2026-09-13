import SwiftUI
import YamiboXCore

struct CreditLogView: View {
    @Environment(\.forumTheme) private var theme
    @State private var model: CreditLogViewModel
    let onURLTap: (URL) -> Void

    init(model: CreditLogViewModel, onURLTap: @escaping (URL) -> Void) {
        _model = State(wrappedValue: model)
        self.onURLTap = onURLTap
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.string("credit_log.filter"), selection: Binding(
                get: { model.selectedFilter },
                set: { filter in Task { await model.selectFilter(filter) } }
            )) {
                ForEach(CreditLogFilter.allCases, id: \.self) { filter in
                    Text(CreditLogViewModel.title(for: filter)).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityIdentifier("credit-log-filter")

            ScrollViewReader { proxy in
                List {
                    Color.clear
                        .frame(height: 1)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(theme.pageBackground)
                        .accessibilityHidden(true)
                        .id("credit-log-top")

                    if let details = model.errorDetails {
                        LoadFailureView(message: details.summary, details: details) {
                            Task { await model.retry() }
                        }
                        .disabled(model.isLoading)
                        .listRowBackground(theme.pageBackground)
                        .listRowSeparator(.hidden)
                    }

                    if let content = model.content {
                        if content.entries.isEmpty {
                            ContentUnavailableView(model.emptyMessage, systemImage: "list.bullet.rectangle")
                                .listRowBackground(theme.pageBackground)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(content.entries) { entry in
                            CreditLogRowView(entry: entry, onURLTap: onURLTap)
                                .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                                .listRowBackground(theme.surface)
                                .listRowSeparatorTint(theme.divider)
                        }
                        ForumPageNavigationBar(
                            navigation: content.pageNavigation,
                            currentPage: model.currentPage,
                            goToPage: { page in Task { await model.goToPage(page) } },
                            hidesOnSinglePage: true
                        )
                        .disabled(model.isLoading)
                        .listRowBackground(theme.pageBackground)
                        .listRowSeparator(.hidden)
                    } else if model.errorDetails == nil {
                        ContentLoadingView()
                            .frame(maxWidth: .infinity)
                            .listRowBackground(theme.pageBackground)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)
                .scrollContentBackground(.hidden)
                .refreshableWithTopIndicator(isRefreshing: model.isLoading && model.content != nil) {
                    await model.refresh()
                }
                .onChange(of: model.scrollIdentity) {
                    proxy.scrollTo("credit-log-top", anchor: .top)
                }
                .onChange(of: model.errorDetails != nil) { _, hasError in
                    if hasError { proxy.scrollTo("credit-log-top", anchor: .top) }
                }
            }
        }
        .forumPageBackground()
        .tint(theme.accentText)
        .navigationTitle(L10n.string("credit_log.title"))
        .yamiboInlineNavigationTitleDisplayMode()
        .task { await model.load() }
    }
}

struct CreditLogRowView: View {
    let entry: CreditLogEntry
    let onURLTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CreditLogHeadingView(operation: entry.operation, changes: entry.changes)
            CreditLogDetailsView(description: entry.description, timeText: entry.timeText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
            onURLTap(url)
            return .handled
        })
        .accessibilityElement(children: .contain)
    }
}

private struct CreditLogHeadingView: View {
    @Environment(\.forumTheme) private var theme
    let operation: String
    let changes: [CreditLogChange]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(operation).fixedSize()
                Spacer(minLength: 0)
                CreditLogChangesView(changes: changes, alignment: .trailing).fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(operation)
                CreditLogChangesView(changes: changes, alignment: .leading)
            }
        }
        .font(.body)
        .foregroundStyle(theme.primaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CreditLogChangesView: View {
    @Environment(\.forumTheme) private var theme
    let changes: [CreditLogChange]
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                Text("\(Text(change.name))\(Text(change.valueText.isEmpty ? "" : " " + change.valueText).foregroundColor((change.amount ?? 0) > 0 ? theme.accentText : theme.secondaryText))")
                    .monospacedDigit()
            }
        }
    }
}

private struct CreditLogDetailsView: View {
    @Environment(\.forumTheme) private var theme
    let description: ForumThreadTextBlock
    let timeText: String

    var body: some View {
        let attributed = ForumThreadTextBlockFormatter(block: description, theme: theme).attributedText
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(attributed).fixedSize()
                Spacer(minLength: 0)
                Text(timeText).fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                if !description.text.isEmpty { Text(attributed) }
                Text(timeText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.subheadline)
        .foregroundStyle(theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
}
