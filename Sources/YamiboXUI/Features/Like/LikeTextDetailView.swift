import SwiftUI
import UIKit
import YamiboXCore

/// Full-screen read view for one liked text excerpt. Tapping a text card in
/// `LikeWorkItemsView` opens this instead of jumping straight to the
/// original reading position — the jump only happens if the user picks
/// "跳转原文" from this view's menu.
struct LikeTextDetailView: View {
    let item: LikeItem
    let chapterInfo: String?
    let onJumpToOriginal: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.excerptText ?? "")
                        .font(.title3)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(LocalFavoriteRelativeDate.string(from: item.createdAt))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(20)
            }
            .navigationTitle(chapterInfo ?? L10n.string("likes.excerpt_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = item.excerptText
                        } label: {
                            Label(L10n.string("likes.copy_excerpt"), systemImage: "doc.on.doc")
                        }
                        Button(action: onJumpToOriginal) {
                            Label(L10n.string("likes.jump_to_original"), systemImage: "book.closed")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(L10n.string("common.more"))
                }
            }
        }
    }
}
