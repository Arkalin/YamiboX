import SwiftUI
import YamiboXCore

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
        .onDisappear { onSave(text) }
    }

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
