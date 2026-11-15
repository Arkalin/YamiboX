import SwiftUI
import YamiboXCore

/// Shared correction form for a manga directory's identity (clean book name +
/// search keywords). Presented from both the reader's directory sheet and the
/// forum manga detail page.
struct MangaDirectoryCorrectionSheet: View {
    /// Preferred detents for presenters: medium fits the form at standard
    /// type sizes; large keeps every field reachable (the form scrolls) when
    /// accessibility text sizes need more room than a fixed height allows.
    static let presentationDetents: Set<PresentationDetent> = [.medium, .large]

    @Binding var draft: MangaDirectoryEditDraft
    let onSaveCorrection: (MangaDirectoryEditDraft) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                MangaDirectoryCorrectionFields(
                    draft: $draft
                )
            }
            .navigationTitle(L10n.string("manga.correction_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.string("common.close"))
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onSaveCorrection(trimmedDraft)
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(trimmedDraft.cleanBookName.isEmpty)
                    .accessibilityLabel(L10n.string("manga.save_correction"))
                }
            }
        }
    }

    private var trimmedDraft: MangaDirectoryEditDraft {
        MangaDirectoryEditDraft(
            cleanBookName: draft.cleanBookName.trimmingCharacters(in: .whitespacesAndNewlines),
            primaryKeyword: draft.primaryKeyword.trimmingCharacters(in: .whitespacesAndNewlines),
            secondaryKeyword: draft.secondaryKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

private struct MangaDirectoryCorrectionFields: View {
    @Binding var draft: MangaDirectoryEditDraft

    var body: some View {
        Section(L10n.string("manga.name")) {
            TextField("", text: $draft.cleanBookName)
                .accessibilityLabel(L10n.string("manga.name"))
        }

        Section(L10n.string("manga.keywords")) {
            TextField(L10n.string("manga.keyword_primary"), text: $draft.primaryKeyword)

            TextField(L10n.string("manga.keyword_secondary"), text: $draft.secondaryKeyword)
        }
    }
}
