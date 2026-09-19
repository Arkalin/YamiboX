import SwiftUI
import YamiboXCore

struct ForumThreadReaderActionBar: View {
    @Environment(\.forumTheme) private var theme
    let isFavorited: Bool
    let onReply: () -> Void
    let onFavorite: () -> Void
    let onFavoriteLongPress: () -> Void
    var onReaderModeSwitch: ((YamiboThreadReaderOverride) -> Void)? = nil
    var isSwitchingReaderMode = false
    var recommendedReaderKind: YamiboThreadKind = .unknown

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onReply) {
                Label(L10n.string("forum.thread.send_reply"), systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accentText)

            Button(action: onFavorite) {
                Label(
                    isFavorited ? L10n.string("forum.thread.favorited") : L10n.string("forum.thread.favorite"),
                    systemImage: isFavorited ? "star.fill" : "star"
                )
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isFavorited ? theme.warning : theme.accentText)
                .frame(width: 42, height: 34)
                .expandedHitTarget()
            }
            .buttonStyle(.bordered)
            .tint(theme.accentText)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in onFavoriteLongPress() })
            .accessibilityLabel(
                isFavorited ? L10n.string("forum.thread.favorited") : L10n.string("forum.thread.favorite")
            )

            if let onReaderModeSwitch {
                Menu {
                    Button {
                        onReaderModeSwitch(.novel)
                    } label: {
                        Label(
                            L10n.string(recommendedReaderKind == .novel
                                ? "reader.open_as_novel.recommended"
                                : "reader.open_as_novel"),
                            systemImage: "book"
                        )
                    }
                    Button {
                        onReaderModeSwitch(.manga)
                    } label: {
                        Label(
                            L10n.string(recommendedReaderKind == .manga
                                ? "reader.open_as_manga.recommended"
                                : "reader.open_as_manga"),
                            systemImage: "photo.on.rectangle"
                        )
                    }
                } label: {
                    Label(L10n.string("reader.switch_mode"), systemImage: "arrow.left.arrow.right")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(theme.accentText)
                        .frame(width: 42, height: 34)
                        .expandedHitTarget()
                }
                .buttonStyle(.bordered)
                .tint(theme.accentText)
                .disabled(isSwitchingReaderMode)
                .accessibilityLabel(L10n.string("reader.switch_mode"))
            }
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial)
    }
}
