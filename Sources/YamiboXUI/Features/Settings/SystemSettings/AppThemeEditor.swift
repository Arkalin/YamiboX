import SwiftUI
import YamiboXCore

struct AppThemeEditor: View {
    let initial: AppThemeDefinition
    let isNew: Bool
    let usesAccentSurfaces: Bool
    let save: (AppThemeDefinition) async throws -> Void
    let delete: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppThemeDefinition
    @State private var showsColorPicker = false
    @State private var confirmsDelete = false
    @State private var confirmsDiscard = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    init(
        initial: AppThemeDefinition,
        isNew: Bool,
        usesAccentSurfaces: Bool,
        save: @escaping (AppThemeDefinition) async throws -> Void,
        delete: @escaping (String) async throws -> Void
    ) {
        self.initial = initial
        self.isNew = isNew
        self.usesAccentSurfaces = usesAccentSurfaces
        self.save = save
        self.delete = delete
        _draft = State(initialValue: initial)
    }

    private var hasChanges: Bool { draft != initial }
    private var validName: Bool { !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var previewTheme: ForumTheme {
        .theme(for: AppAppearanceSettings(
            themeLibrary: AppThemeLibrary(themes: [draft], selectedID: draft.id),
            usesAccentSurfaces: usesAccentSurfaces
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForumThemePreview(theme: previewTheme)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.string("settings.app_theme.preview"))
                        .padding(.vertical, 6)
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                Section {
                    TextField(L10n.string("settings.app_theme.name"), text: $draft.name)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .onSubmit { isNameFocused = false }
                        .onChange(of: draft.name) { _, name in
                            if name.count > 40 { draft.name = String(name.prefix(40)) }
                        }
                    Button {
                        isNameFocused = false
                        showsColorPicker = true
                    } label: {
                        HStack {
                            Text(L10n.string("settings.app_theme.edit_color"))
                                .foregroundStyle(.primary)
                            Spacer()
                            Circle()
                                .fill(Color(hex: draft.colorHex))
                                .overlay(Circle().strokeBorder(.secondary.opacity(0.25), lineWidth: 0.5))
                                .frame(width: 28, height: 28)
                                .accessibilityHidden(true)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Text(L10n.string("settings.app_theme.details"))
                } footer: {
                    Text(L10n.string("settings.app_theme.editor_footer"))
                }

                if !isNew && !initial.isBuiltIn {
                    Section {
                        Button(L10n.string("settings.app_theme.delete"), role: .destructive) {
                            isNameFocused = false
                            confirmsDelete = true
                        }
                    }
                }
            }
            .disabled(isSaving || initial.isBuiltIn)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(L10n.string(isNew ? "settings.app_theme.add" : "settings.app_theme.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("common.cancel")) {
                        if hasChanges { confirmsDiscard = true } else { dismiss() }
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        persist(deleting: false)
                    } label: {
                        if isSaving { ProgressView() } else { Text(L10n.string("common.save")).fontWeight(.semibold) }
                    }
                    .disabled(isSaving || !validName || (!isNew && !hasChanges) || initial.isBuiltIn)
                }
            }
            .sheet(isPresented: $showsColorPicker) {
                ThemeColorPicker(colorHex: $draft.colorHex)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(hasChanges || isSaving)
        .confirmationDialog(L10n.string("settings.app_theme.delete_confirm"), isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(L10n.string("common.delete"), role: .destructive) { persist(deleting: true) }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("settings.app_theme.delete_message"))
        }
        .confirmationDialog(L10n.string("settings.navigation.discard_title"), isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button(L10n.string("settings.navigation.discard"), role: .destructive) { dismiss() }
            Button(L10n.string("settings.navigation.continue_editing"), role: .cancel) {}
        }
        .alert(L10n.string("common.operation_failed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L10n.string("common.ok"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func persist(deleting: Bool) {
        guard !initial.isBuiltIn else { return }
        isNameFocused = false
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                if deleting { try await delete(initial.id) }
                else { try await save(draft.normalized) }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
