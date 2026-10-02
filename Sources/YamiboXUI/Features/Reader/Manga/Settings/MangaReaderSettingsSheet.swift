import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaReaderSettingsSheet: View {
    // Plain reference (was `@ObservedObject`): the `@Observable` model's
    // tracked properties read in `body` register observation on their own.
    let model: MangaReaderViewModel
    let settingsStore: SettingsStore
    let peripheralInput: ReaderPeripheralInputManager
    let controlAccent: Color
    let readerViewportSize: CGSize
    let readerTopInset: CGFloat
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftSettings = MangaReaderSettings()
    @State private var hasLoadedDraft = false
    @State private var isPeripheralSettingsPresented = false
    @State private var tapZonesPreviewRequestID = 0

    private var isPadDevice: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

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
                isPadDevice: isPadDevice,
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
                        tapZonesPreviewRequestID: tapZonesPreviewRequestID,
                        onClose: { dismiss() },
                        onConfirm: commitDraft
                    )

                    MangaReaderSettingsSections(
                        settings: $draftSettings,
                        palette: palette,
                        usesTwoPageSpread: usesTwoPageSpread,
                        onSwapPageTurnTapZonesChange: { value in
                            draftSettings.swapsPageTurnTapZones = value
                            tapZonesPreviewRequestID += 1
                        },
                        onOpenPeripheralSettings: { isPeripheralSettingsPresented = true }
                    )
                }
            }
        }
        .background(Color.clear)
        // Sheets use a separate presentation host on recent iOS releases;
        // set the app accent again so UIKit/glass controls cannot fall back
        // to the system blue.
        .tint(controlAccent)
        .onAppear(perform: loadDraftIfNeeded)
        .sheet(isPresented: $isPeripheralSettingsPresented) {
            ReaderPeripheralSettingsSheet(
                settingsStore: settingsStore,
                peripheralInput: peripheralInput
            )
        }
    }

    private func loadDraftIfNeeded() {
        guard !hasLoadedDraft else { return }
        draftSettings = model.presentation.settings
        hasLoadedDraft = true
    }

    private func commitDraft() {
        let committedSettings = draftSettings
        dismiss()
        model.applySettings(committedSettings)
    }
}
#endif
