import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct NovelReaderChapterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let onSelect: (NovelReaderChapter) -> Void
    let onSelectWebView: (Int) -> Void

    // Plain reference (was `@ObservedObject`): the `@Observable` model's
    // tracked properties read in `body` register observation on their own.
    // `navigation` stays `@ObservedObject` — the coordinator is still an
    // `ObservableObject` with `@Published` state.
    let model: NovelReaderViewModel
    @ObservedObject private var navigation: NovelReaderNavigationCoordinator
    @State private var showingWebPicker = false

    init(
        model: NovelReaderViewModel,
        onSelect: @escaping (NovelReaderChapter) -> Void,
        onSelectWebView: @escaping (Int) -> Void
    ) {
        self.model = model
        self.navigation = model.navigation
        self.onSelect = onSelect
        self.onSelectWebView = onSelectWebView
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ZStack {
                    if navigation.chapterDirectory.isLoading {
                        Text(L10n.string("common.loading"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            Section {
                                if let error = navigation.chapterDirectory.error {
                                    Label(error, systemImage: "exclamationmark.triangle")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }

                                if let previousView = navigation.previousChapterDirectoryWebView {
                                    NovelReaderChapterWebNavigationButton(
                                        title: L10n.string("reader.go_previous_web_page"),
                                        systemImage: "chevron.up",
                                        action: { onSelectWebView(previousView) }
                                    )
                                }

                                ForEach(navigation.visibleChapterDirectoryChapters, id: \.ordinal) { chapter in
                                    Button {
                                        onSelect(chapter)
                                        dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(chapter.title)
                                                .font(.body.weight(isCurrent(chapter) ? .semibold : .regular))
                                                .foregroundStyle(isCurrent(chapter) ? Color.accentColor : .primary)
                                                .lineLimit(1)
                                            Text(chapterLocationText(for: chapter))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .listRowBackground(isCurrent(chapter) ? Color.accentColor.opacity(0.12) : Color.clear)
                                    .id(chapter.ordinal)
                                }

                                if let nextView = navigation.nextChapterDirectoryWebView {
                                    NovelReaderChapterWebNavigationButton(
                                        title: L10n.string("reader.go_next_web_page"),
                                        systemImage: "chevron.down",
                                        action: { onSelectWebView(nextView) }
                                    )
                                }
                            }
                        }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Button {
                            guard model.maxView > 1 else { return }
                            showingWebPicker.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Text(navigation.chapterDirectoryWebTitle)
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .rotationEffect(.degrees(showingWebPicker ? 180 : 0))
                            }
                            .font(.headline)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.maxView <= 1)
                        .popover(isPresented: $showingWebPicker, arrowEdge: .top) {
                            NovelReaderChapterWebPicker(model: model, navigation: navigation) { view in
                                showingWebPicker = false
                                guard view != navigation.visibleChapterDirectoryView else { return }
                                onSelectWebView(view)
                            }
                            .presentationCompactAdaptation(.popover)
                        }
                        .accessibilityLabel(navigation.chapterDirectoryWebTitle)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        ReaderToolbarIconButton(
                            systemName: "xmark",
                            title: L10n.string("common.done"),
                            action: { dismiss() }
                        )
                    }
                }
                .onAppear {
                    navigation.resetChapterDirectoryBrowsing()
                    scrollToCurrentChapter(using: scrollProxy)
                }
                .onChange(of: model.currentChapterIndex) { _, _ in
                    scrollToCurrentChapter(using: scrollProxy)
                }
                .onChange(of: model.visibleView) { _, _ in
                    showingWebPicker = false
                    scrollToCurrentChapter(using: scrollProxy)
                }
                .onChange(of: navigation.visibleChapterDirectoryView) { _, _ in
                    scrollToCurrentChapter(using: scrollProxy)
                }
                .onChange(of: model.maxView) { _, newValue in
                    if newValue <= 1 {
                        showingWebPicker = false
                    }
                }
            }
        }
    }

    private func isCurrent(_ chapter: NovelReaderChapter) -> Bool {
        navigation.isCurrentChapterDirectoryChapter(chapter)
    }

    private func chapterLocationText(for chapter: NovelReaderChapter) -> String {
        if model.settings.readingMode == .vertical {
            guard navigation.visibleChapterDirectoryPageCount > 1 else { return "0%" }
            let fraction = Double(chapter.startIndex) / Double(navigation.visibleChapterDirectoryPageCount - 1)
            return "\(Int((fraction * 100).rounded()))%"
        }
        return L10n.string("reader.page_number_spaced", chapter.startIndex + 1)
    }

    private func scrollToCurrentChapter(using proxy: ScrollViewProxy) {
        guard let currentChapterIndex = navigation.currentChapterDirectoryIndex,
              navigation.visibleChapterDirectoryChapters.indices.contains(currentChapterIndex) else { return }
        let targetIndex = max(currentChapterIndex - 3, 0)
        let targetChapter = navigation.visibleChapterDirectoryChapters[targetIndex]
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(targetChapter.ordinal, anchor: .top)
        }
    }
}

private struct NovelReaderChapterWebNavigationButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

private struct NovelReaderChapterWebPicker: View {
    // Plain reference (was `@ObservedObject`): the `@Observable` model's
    // tracked properties read in `body` register observation on their own.
    let model: NovelReaderViewModel
    @ObservedObject var navigation: NovelReaderNavigationCoordinator
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(1 ... model.maxView, id: \.self) { view in
                        Button {
                            onSelect(view)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: view == navigation.visibleChapterDirectoryView ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(view == navigation.visibleChapterDirectoryView ? Color.accentColor : Color.secondary)

                                Text(L10n.string("reader.page_number_spaced", view))
                                    .foregroundStyle(.primary)

                                Spacer(minLength: 0)

                                if view == model.visibleView {
                                    Text(L10n.string("common.current"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(view == navigation.visibleChapterDirectoryView ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(view)
                    }
                }
                .padding(8)
            }
            .frame(width: 200)
            .frame(maxHeight: 260)
            .onAppear {
                scrollToCurrentView(using: proxy)
            }
            .onChange(of: navigation.visibleChapterDirectoryView) { _, _ in
                scrollToCurrentView(using: proxy)
            }
        }
    }

    private func scrollToCurrentView(using proxy: ScrollViewProxy) {
        guard model.maxView > 0 else { return }
        let target = max(navigation.visibleChapterDirectoryView - 2, 1)
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .top)
        }
    }
}
#endif
