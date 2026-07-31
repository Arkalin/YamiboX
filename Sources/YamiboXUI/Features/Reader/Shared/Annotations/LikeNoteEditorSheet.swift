import SwiftUI
import YamiboXCore

/// Note editor for one annotation.
///
/// A medium-detent sheet rather than a push or an inline popover: the reader is
/// full-screen and immersive so a push would break it, and once the keyboard is
/// up an inline popover has no room left.
///
/// There is no Cancel. Closing the sheet — Done, swipe-down, anything — saves.
/// The alternative costs a written note to a stray swipe, and losing text the
/// user typed is not recoverable while re-editing is.
struct LikeNoteEditorSheet: View {
    let item: LikeItem
    let onSave: (String?) -> Void

    @State private var text: String
    @FocusState private var isEditorFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(item: LikeItem, onSave: @escaping (String?) -> Void) {
        self.item = item
        self.onSave = onSave
        self._text = State(initialValue: item.note ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                excerptHeader
                Divider()
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .focused($isEditorFocused)
            }
            .navigationTitle(L10n.string("likes.note_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            isEditorFocused = true
        }
        // The single save path: whatever dismissed the sheet, the text lands.
        .onDisappear { onSave(text) }
    }

    /// The annotated text stays visible while writing — otherwise the user is
    /// commenting on something they can no longer see.
    @ViewBuilder
    private var excerptHeader: some View {
        if let excerpt = item.excerptText, !excerpt.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(LikeStyleAppearance.swatchColor(for: item.style).opacity(0.75))
                    .frame(width: 3)
                Text(excerpt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}
