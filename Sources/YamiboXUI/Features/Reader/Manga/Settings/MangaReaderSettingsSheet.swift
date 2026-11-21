import SwiftUI
import YamiboXCore

#if os(iOS)
struct MangaReaderSettingsSheet: View {
    let model: MangaReaderViewModel
    let settingsStore: SettingsStore
    let settingsTarget: ReaderSettingsTarget
    let peripheralInput: ReaderPeripheralInputManager
    let controlAccent: Color
    let readerViewportSize: CGSize
    let readerTopInset: CGFloat
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftSettings = MangaReaderSettings()
    @State private var baseline: MangaReaderSettings?
    @State private var isSaving = false
    @State private var saveFailure: String?
    @State private var saveFailureIdentity = UUID()
    @State private var isPeripheralSettingsPresented = false
    @State private var isGestureRegionPreviewPresented = false

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            let layout = CompactLandscapeLayout(size: proxy.size)
            let isCompact = proxy.size.height < 500
            let heroHeight = layout.isSideBySide ? proxy.size.height : (isCompact
                ? min(160, proxy.size.height * 0.4)
                : max(318, min(382, proxy.size.height * 0.38))) + topInset
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
                availableSize: readerContentSize
            )

            ZStack(alignment: .top) {
                MangaReaderSettingsBackground(
                    palette: palette,
                    heroHeight: heroHeight,
                    heroWidth: layout.isSideBySide ? layout.leadingWidth : nil
                )

                layout.stack {
                    MangaReaderSettingsHero(
                        settings: draftSettings,
                        palette: palette,
                        topInset: topInset,
                        height: heroHeight,
                        isCompact: isCompact,
                        usesTwoPageSpread: usesTwoPageSpread,
                        readerViewportSize: readerContentSize,
                        onClose: closePanel,
                        onConfirm: commitDraft
                    )
                    .frame(width: layout.isSideBySide ? layout.leadingWidth : nil)

                    MangaReaderSettingsSections(
                        settings: $draftSettings,
                        palette: palette,
                        usesTwoPageSpread: usesTwoPageSpread,
                        onOpenPeripheralSettings: { isPeripheralSettingsPresented = true },
                        onOpenGestureRegions: { isGestureRegionPreviewPresented = true }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            isPresented: .presentation(isPresented: { saveFailure != nil }, identity: { saveFailureIdentity }, clearOnDismiss: { saveFailure = nil })
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
                saveFailureIdentity = UUID()
                saveFailure = error.localizedDescription
            }
        }
    }

    private func closePanel() {
        dismiss()
    }
}
#endif
