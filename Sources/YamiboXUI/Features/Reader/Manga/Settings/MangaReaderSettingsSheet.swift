import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaReaderSettingsSheet: View {
    // Plain reference (was `@ObservedObject`): the `@Observable` model's
    // tracked properties read in `body` register observation on their own.
    let model: MangaReaderViewModel
    let appModel: YamiboAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftSettings = MangaReaderSettings()
    @State private var hasLoadedDraft = false
    @State private var isPeripheralSettingsPresented = false

    private var isPadDevice: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            let heroHeight = max(318, min(382, proxy.size.height * 0.38)) + topInset
            let palette = MangaReaderSettingsPalette(colorScheme: colorScheme)
            let usesTwoPageSpread = MangaPagedLayoutPolicy.usesTwoPageSpread(
                settings: draftSettings,
                isPadDevice: isPadDevice,
                availableSize: proxy.size
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
                        onClose: { dismiss() },
                        onConfirm: commitDraft
                    )

                    MangaReaderSettingsSections(
                        settings: $draftSettings,
                        palette: palette,
                        isPadDevice: isPadDevice,
                        usesTwoPageSpread: usesTwoPageSpread,
                        onOpenPeripheralSettings: { isPeripheralSettingsPresented = true }
                    )
                }
            }
        }
        .background(Color.clear)
        // Sheets use a separate presentation host on recent iOS releases;
        // set the reader-owned accent again so UIKit/glass controls cannot
        // fall back to the system blue.
        .tint(ReaderTheme.accent)
        .onAppear(perform: loadDraftIfNeeded)
        .sheet(isPresented: $isPeripheralSettingsPresented) {
            ReaderPeripheralSettingsSheet(
                dependencies: appModel.appContext.settingsDependencies,
                peripheralInput: appModel.peripheralInput
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
