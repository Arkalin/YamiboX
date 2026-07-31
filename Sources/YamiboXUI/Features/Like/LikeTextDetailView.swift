import SwiftUI
import UIKit
import YamiboXCore

/// Full-screen read view for one liked text excerpt. Tapping a text card in
/// `LikeWorkItemsView` opens this instead of jumping straight to the
/// original reading position — the jump only happens if the user picks
/// "跳转原文" from this view's menu.
struct LikeTextDetailView: View {
    let chapterInfo: String?
    let onSaveNote: (String?) -> Void
    let onJumpToOriginal: () -> Void

    @State private var displayedItem: LikeItem
    @State private var noteEditTarget: LikeItem?
    @Environment(\.dismiss) private var dismiss

    init(
        item: LikeItem,
        chapterInfo: String?,
        onSaveNote: @escaping (String?) -> Void,
        onJumpToOriginal: @escaping () -> Void
    ) {
        self.chapterInfo = chapterInfo
        self.onSaveNote = onSaveNote
        self.onJumpToOriginal = onJumpToOriginal
        _displayedItem = State(initialValue: item)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(LikeStyleAppearance.inlineExcerptLine(for: displayedItem))
                        .font(.title3)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if displayedItem.hasNote, let note = displayedItem.note {
                        Text(note)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(LocalFavoriteRelativeDate.string(from: displayedItem.createdAt))
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
                            UIPasteboard.general.string = displayedItem.excerptText
                        } label: {
                            Label(L10n.string("likes.copy_excerpt"), systemImage: "doc.on.doc")
                        }
                        Button {
                            noteEditTarget = displayedItem
                        } label: {
                            Label(
                                L10n.string(displayedItem.hasNote ? "likes.edit_note" : "likes.add_note"),
                                systemImage: "note.text"
                            )
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
        .sheet(item: $noteEditTarget) { target in
            LikeNoteEditorSheet(item: target) { note in
                var updatedItem = displayedItem
                updatedItem.note = normalizedNote(note)
                displayedItem = updatedItem
                onSaveNote(note)
            }
        }
    }

    private func normalizedNote(_ note: String?) -> String? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
