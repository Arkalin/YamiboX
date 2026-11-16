import SwiftUI
import YamiboXCore

#if os(iOS)
struct MangaReaderSettingsSheet: View {
    // Plain reference (was `@ObservedObject`): the `@Observable` model's
    // tracked properties read in `body` register observation on their own.
    let model: MangaReaderViewModel
    let settingsStore: SettingsStore
    let settingsTarget: ReaderSettingsTarget
    let peripheralInput: ReaderPeripheralInputManager
    let controlAccent: Color
    let readerViewportSize: CGSize
    let readerTopInset: CGFloat
    let readerSupportsSpreads: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftSettings = MangaReaderSettings()
    @State private var baseline: MangaReaderSettings?
    @State private var isSaving = false
    @State private var saveFailure: String?
    @State private var isPeripheralSettingsPresented = false
    @State private var isGestureRegionPreviewPresented = false

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            let heroHeight = max(318, min(382, proxy.size.height * 0.38)) + topInset
            let palette = MangaReaderSettingsPalette(
                colorScheme: colorScheme,
                controlAccent: controlAccent
            )
            let readerContentSize = CGSize(
                width: readerViewportSize.width,
                height: max(readerViewportSize.height - MangaPagedLayoutPolicy.pagedContentTopInset(
                    settings: draftSettings,
                    topInset: readerTopInset
                ), 0)
            )
            // A narrow settings sheet must not turn a landscape reader spread into a single-page preview.
            let usesTwoPageSpread = MangaPagedLayoutPolicy.usesTwoPageSpread(
                settings: draftSettings,
                isPadDevice: readerSupportsSpreads,
                availableSize: readerContentSize
            )

            ZStack(alignment: .top) {
                MangaReaderSettingsBackground(
                    palette: palette,
                    heroHeight: heroHeight
                )

                VStack(spacing: 0) {
                    MangaReaderSettingsHero(
                        settings: draftSettings,
                        palette: palette,
                        topInset: topInset,
                        height: heroHeight,
                        usesTwoPageSpread: usesTwoPageSpread,
                        readerViewportSize: readerContentSize,
                        onClose: closePanel,
                        onConfirm: commitDraft
                    )

                    MangaReaderSettingsSections(
                        settings: $draftSettings,
                        palette: palette,
                        usesTwoPageSpread: usesTwoPageSpread,
                        onOpenPeripheralSettings: { isPeripheralSettingsPresented = true },
                        onOpenGestureRegions: { isGestureRegionPreviewPresented = true }
                    )
                }
            }
        }
        .background(Color.clear)
        // Sheets use a separate presentation host on recent iOS releases;
        // set the app accent again so UIKit/glass controls cannot fall back
        // to the system blue.
        .tint(controlAccent)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .failureAlert(
            L10n.string("common.operation_failed"), message: saveFailure,
            isPresented: .presentation(isPresented: { saveFailure != nil }, clearOnDismiss: { saveFailure = nil })
        ) {
            Button(L10n.string("common.ok")) { saveFailure = nil }
        }
        .onAppear(perform: loadDraftIfNeeded)
        .sheet(isPresented: $isPeripheralSettingsPresented) {
            ReaderPeripheralSettingsSheet(
                settingsStore: settingsStore,
                settingsTarget: settingsTarget,
                peripheralInput: peripheralInput
            )
        }
        .fullScreenCover(isPresented: $isGestureRegionPreviewPresented) {
            ReaderGestureRegionPreview(selection: draftSettings.gestureRegionLayout) {
                draftSettings.gestureRegionLayout = $0
            }
            .tint(controlAccent)
        }
    }

    private func loadDraftIfNeeded() {
        guard baseline == nil else { return }
        draftSettings = model.presentation.settings
        baseline = draftSettings
    }

    private func commitDraft() {
        guard let baseline, !isSaving else { return }
        let draft = draftSettings
        guard draft != baseline else { closePanel(); return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await model.saveViewportSettings(draft, for: settingsTarget)
                dismiss()
            } catch {
                saveFailure = error.localizedDescription
            }
        }
    }

    private func closePanel() {
        dismiss()
    }
}
#endif
