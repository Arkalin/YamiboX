import PhotosUI
import SwiftUI
import YamiboXCore

/// Owns the picker/editor lifecycle. Feature pages supply only their destination
/// and preview, never another feature's view model or presentation state.
struct CustomBackgroundSettingsRow<Preview: View>: View {
    let title: String
    let settings: CustomBackgroundSettings
    let imageStore: CustomBackgroundImageStore
    let persistence: CustomBackgroundPersistence
    let isBusy: Bool
    let onSaved: (CustomBackgroundSettings) -> Void
    var showsFramedPreview = false
    var supportsBlur = true
    var overlayVisibility: Bool? = nil
    var onOverlayVisibilitySaved: (Bool) -> Void = { _ in }
    @ViewBuilder var preview: (Data?, CustomBackgroundSettings, CGSize) -> Preview

    @State private var draft: CustomBackgroundEditorDraft?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingPicker = false
    @State private var isOpening = false
    @State private var isLoadingImage = false
    @State private var errorMessage: String?
    @State private var errorDetails: LoadFailureDetails?

    var body: some View {
        Button {
            guard !isOpening else { return }
            Task {
                isOpening = true
                defer { isOpening = false }
                let data = await imageStore.loadData(imageID: settings.imageID)
                draft = data.flatMap { CustomBackgroundEditorDraft.custom(imageData: $0, settings: settings) }
                    ?? CustomBackgroundEditorDraft(imageData: nil, imageSize: .zero, settings: .init())
                if !supportsBlur { draft?.settings.blurRadius = 0 }
                draft?.showsOverlay = overlayVisibility ?? true
            }
        } label: {
            HStack {
                Text(title).foregroundStyle(Color.primary)
                Spacer()
                Text(L10n.string(settings.isEnabled ? "custom_background.custom" : "custom_background.default"))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(Color.primary)
        .disabled(isBusy || isOpening)
        .fullScreenCover(item: $draft, onDismiss: {
            pickerItem = nil
            isLoadingImage = false
        }) { _ in
            CustomBackgroundEditorView(
                draft: Binding(get: { draft ?? .init(imageData: nil, imageSize: .zero, settings: .init()) }, set: { draft = $0 }),
                onCancel: { draft = nil },
                onChangeImage: { showingPicker = true },
                onApply: apply,
                showsFramedPreview: showsFramedPreview,
                supportsBlur: supportsBlur,
                isLoadingImage: isLoadingImage,
                supportsOverlayVisibility: overlayVisibility != nil,
                preview: preview
            )
            .photosPicker(isPresented: $showingPicker, selection: $pickerItem, matching: .images)
            .overlay {
                if isLoadingImage {
                    ProgressView().padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
                        .allowsHitTesting(false)
                }
            }
            .task(id: pickerItem) {
                guard let item = pickerItem else { return }
                let draftID = draft?.id
                isLoadingImage = true
                defer {
                    if draft?.id == draftID { pickerItem = nil; isLoadingImage = false }
                }
                do {
                    guard let source = try await item.loadTransferable(type: Data.self) else {
                        throw YamiboPersistenceError(context: L10n.string("custom_background.load_failed"))
                    }
                    let data = try await Task.detached(priority: .userInitiated) {
                        try CustomBackgroundImageProcessor.normalizedJPEGData(from: source)
                    }.value
                    guard !Task.isCancelled, var current = draft, current.id == draftID else { return }
                    guard current.replaceImage(with: data) else {
                        throw YamiboPersistenceError(context: L10n.string("custom_background.load_failed"))
                    }
                    draft = current
                } catch {
                    if draft?.id == draftID { report(error) }
                }
            }
            .failureAlert(L10n.string("common.operation_failed"), message: errorMessage, details: errorDetails,
                          isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(L10n.string("common.ok")) { errorMessage = nil }
            }
        }
    }

    private func apply(_ draft: CustomBackgroundEditorDraft) async -> Bool {
        do {
            let saved = try await persistence.apply(imageData: draft.imageData, settings: draft.settings,
                                                    overlayVisibility: overlayVisibility != nil ? draft.showsOverlay : nil)
            onSaved(saved)
            if overlayVisibility != nil { onOverlayVisibilitySaved(draft.showsOverlay) }
            self.draft = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func report(_ error: any Error) {
        guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
        errorMessage = error.localizedDescription
        errorDetails = LoadFailureDetails(error: error)
    }
}
