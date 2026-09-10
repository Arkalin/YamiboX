import SwiftUI
import YamiboXCore

struct ForumEmoticonPicker: View {
    var categories: [ForumEmoticonCategory] = ForumEmoticonCatalog.categories
    let onSelect: (ForumEmoticon) -> Void
    @State private var selectedCategory = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.forumTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var category: ForumEmoticonCategory? {
        categories.first { $0.id == selectedCategory } ?? categories.first
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L10n.string("forum.native.emoticon_category"), selection: Binding(
                    get: { category?.id ?? "" }, set: { selectedCategory = $0 }
                )) {
                    ForEach(categories) { category in Text(category.name).tag(category.id) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityIdentifier("native-emoticon-category")
                Divider()
                if let category {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 88), spacing: 12)], spacing: 12) {
                            ForEach(Array(category.items.enumerated()), id: \.element.id) { index, item in
                                Button { onSelect(item) } label: {
                                    YamiboRemoteImage(
                                        source: YamiboImageSource(url: item.imageURL, refererPageURL: YamiboDomain.baseURL),
                                        animates: !reduceMotion
                                    ) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: {
                                        ProgressView().controlSize(.small)
                                    } failure: {
                                        Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                                    }
                                    .frame(width: 48, height: 48)
                                    .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.string("forum.native.emoticon_item", category.name, index + 1))
                                .accessibilityIdentifier("native-emoticon-\(item.code)")
                            }
                        }
                        .padding(16)
                    }
                    .id(category.id)
                } else {
                    ContentUnavailableView(L10n.string("forum.native.emoticons_empty"), systemImage: "face.smiling")
                }
            }
            .navigationTitle(L10n.string("forum.native.emoticons"))
            .yamiboInlineNavigationTitleDisplayMode()
            .forumPageBackground()
            .forumNavigationBarStyle()
            .tint(theme.accentText)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.string("common.close"))
                }
            }
            .accessibilityIdentifier("native-emoticon-picker")
        }
    }
}
