import SwiftUI
import YamiboXCore

/// Shared scaffold for the name-entry editor sheets (category, collection,
/// tag): a form whose first row is the name field, with cancel/done in the
/// toolbar and done disabled while the trimmed name is empty. Extra fields
/// (color pickers etc.) keep their state in the caller and are injected
/// below the name row.
struct FavoriteNameEditorSheet<ExtraFields: View>: View {
    let title: String
    let fieldLabel: String
    var isSaving = false
    let onCancel: () -> Void
    let onSave: (String) async -> Void
    @ViewBuilder let extraFields: () -> ExtraFields

    @State private var name: String

    init(
        title: String,
        fieldLabel: String,
        initialName: String,
        isSaving: Bool = false,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) async -> Void,
        @ViewBuilder extraFields: @escaping () -> ExtraFields
    ) {
        self.title = title
        self.fieldLabel = fieldLabel
        self.isSaving = isSaving
        self.onCancel = onCancel
        self.onSave = onSave
        self.extraFields = extraFields
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(fieldLabel, text: $name)
                extraFields()
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done")) {
                        Task { await onSave(name) }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
    }
}

extension FavoriteNameEditorSheet where ExtraFields == EmptyView {
    init(
        title: String,
        fieldLabel: String,
        initialName: String,
        isSaving: Bool = false,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) async -> Void
    ) {
        self.init(
            title: title,
            fieldLabel: fieldLabel,
            initialName: initialName,
            isSaving: isSaving,
            onCancel: onCancel,
            onSave: onSave,
            extraFields: { EmptyView() }
        )
    }
}
