import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct NovelReaderChapterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    let onSelect: (NovelReaderChapter) -> Void
    let onSelectWebView: (Int) -> Void
    let isEmbeddedInReaderPanel: Bool
    let isActive: Bool

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
        onSelectWebView: @escaping (Int) -> Void,
        isEmbeddedInReaderPanel: Bool = false,
        isActive: Bool = true
    ) {
        self.model = model
        self.navigation = model.navigation
        self.onSelect = onSelect
        self.onSelectWebView = onSelectWebView
        self.isEmbeddedInReaderPanel = isEmbeddedInReaderPanel
        self.isActive = isActive
    }

    var body: some View {
        Group {
            if isEmbeddedInReaderPanel {
                chapterContent
            } else {
                NavigationStack {
                    chapterContent
                }
            }
        }
        // The chapter sheet and its popover get their own hosting controllers
        // on iOS 27, so inherit the app accent explicitly at this boundary.
        .tint(appTheme.controlAccent)
    }

    private var chapterContent: some View {
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

                                ForEach(navigation.visibleChapterDirectoryChapters, id: \.ordinal) { chapter in
                                    Button {
                                        onSelect(chapter)
                                        if !isEmbeddedInReaderPanel {
                                            dismiss()
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(chapter.title)
                                                .font(.body.weight(isCurrent(chapter) ? .semibold : .regular))
                                                .foregroundStyle(isCurrent(chapter) ? appTheme.controlAccent : .primary)
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
                                    .listRowBackground(isCurrent(chapter) ? appTheme.controlAccent.opacity(0.12) : Color.clear)
                                    .id(chapter.ordinal)
                                }

                            }
                        }
                        .listStyle(.plain)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isActive, model.maxView > 1 {
                        NovelReaderChapterWebPaginationBar(
                            model: model,
                            navigation: navigation,
                            showingWebPicker: $showingWebPicker,
                            onSelectWebView: onSelectWebView
                        )
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if isActive, !isEmbeddedInReaderPanel {
                        ToolbarItem(placement: .topBarLeading) {
                            ReaderToolbarIconButton(
                                systemName: "xmark",
                                title: L10n.string("common.done"),
                                action: { dismiss() }
                            )
                        }
                    }
                }
                .onAppear {
                    guard isActive else { return }
                    navigation.resetChapterDirectoryBrowsing()
                    scrollToCurrentChapter(using: scrollProxy)
                }
                .onChange(of: isActive) { _, isActive in
                    guard isActive else {
                        showingWebPicker = false
                        return
                    }
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

private struct NovelReaderChapterWebPaginationBar: View {
    let model: NovelReaderViewModel
    @ObservedObject var navigation: NovelReaderNavigationCoordinator
    @Binding var showingWebPicker: Bool
    let onSelectWebView: (Int) -> Void
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        HStack(spacing: 16) {
            Button {
                guard let previousView = navigation.previousChapterDirectoryWebView else { return }
                onSelectWebView(previousView)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L10n.string("reader.previous_web_page"))
            .disabled(navigation.previousChapterDirectoryWebView == nil)

            Button {
                showingWebPicker.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(L10n.string(
                        "reader.web_view_progress",
                        navigation.visibleChapterDirectoryView,
                        max(model.maxView, 1)
                    ))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showingWebPicker ? 180 : 0))
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 120, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(L10n.string("reader.select_web_page"))
            .popover(isPresented: $showingWebPicker, arrowEdge: .bottom) {
                NovelReaderChapterWebPicker(model: model, navigation: navigation) { view in
                    showingWebPicker = false
                    guard view != navigation.visibleChapterDirectoryView else { return }
                    onSelectWebView(view)
                }
                .presentationCompactAdaptation(.popover)
                .tint(appTheme.controlAccent)
            }

            Button {
                guard let nextView = navigation.nextChapterDirectoryWebView else { return }
                onSelectWebView(nextView)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L10n.string("reader.next_web_page"))
            .disabled(navigation.nextChapterDirectoryWebView == nil)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct NovelReaderChapterWebPicker: View {
    // Plain reference (was `@ObservedObject`): the `@Observable` model's
    // tracked properties read in `body` register observation on their own.
    let model: NovelReaderViewModel
    @ObservedObject var navigation: NovelReaderNavigationCoordinator
    let onSelect: (Int) -> Void
    @Environment(\.appTheme) private var appTheme

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
                                    .foregroundStyle(view == navigation.visibleChapterDirectoryView ? appTheme.controlAccent : Color.secondary)

                                Text(L10n.string(
                                    "reader.web_view_progress",
                                    view,
                                    max(model.maxView, 1)
                                ))
                                    .foregroundStyle(.primary)

                                Spacer(minLength: 0)

                                if view == model.visibleView {
                                    Text(L10n.string("common.current"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(appTheme.controlAccent)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(view == navigation.visibleChapterDirectoryView ? appTheme.controlAccent.opacity(0.12) : Color.clear)
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
