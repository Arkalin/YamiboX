import SwiftUI
import YamiboXCore
import UIKit

struct NovelReaderSettingsSheet: View {
    // Plain reference (was `@ObservedObject`): the `@Observable` model's
    // tracked properties read in `body` register observation on their own.
    let model: NovelReaderViewModel
    let settingsStore: SettingsStore
    let peripheralInput: ReaderPeripheralInputManager
    let controlAccent: Color
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftSettings = NovelReaderAppearanceSettings()
    @State private var hasLoadedDraft = false
    @State private var previewSourceText = ""
    @State private var previewTexts: [ReaderTranslationMode: String] = [:]
    @State private var isPeripheralSettingsPresented = false
    @State private var isForumFormatPresented = false
    @State private var isFontLibraryPresented = false
    @State private var fontProtectionID = UUID()
    @State private var tapZonesPreviewRequestID = 0
    private static let fallbackPreviewText = L10n.string("reader.settings.preview_fallback")
    private static let previewCharacterCount = 200

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            let heroHeight = max(300, min(356, proxy.size.height * 0.34)) + topInset
            let palette = NovelReaderSheetPalette(
                settings: draftSettings,
                colorScheme: colorScheme,
                controlAccent: controlAccent
            )

            ZStack(alignment: .top) {
                NovelReaderUnifiedSheetBackground(
                    palette: palette,
                    heroHeight: heroHeight
                )

                VStack(spacing: 0) {
                    heroSection(
                        topInset: topInset,
                        heroHeight: heroHeight,
                        palette: palette
                    )

                    settingsSections(palette: palette)
                }
            }
            .background(Color.clear)
        }
        .background(Color.clear)
        .tint(controlAccent)
        .onAppear(perform: loadDraftIfNeeded)
        .onChange(of: draftSettings.fontSelection) { _, selection in
            model.fontLibrary.protect(selection, owner: fontProtectionID)
        }
        .onDisappear { model.fontLibrary.protect(nil, owner: fontProtectionID) }
        .sheet(isPresented: $isFontLibraryPresented) {
            NovelReaderFontLibraryView(
                library: model.fontLibrary,
                selection: draftSettings.fontSelection,
                currentSelection: model.settings.fontSelection,
                onSelect: { selection in
                    draftSettings.fontSelection = selection
                    draftSettings = model.fontLibrary.resolving(draftSettings)
                }
            )
        }
        .sheet(isPresented: $isPeripheralSettingsPresented) {
            ReaderPeripheralSettingsSheet(
                settingsStore: settingsStore,
                peripheralInput: peripheralInput
            )
        }
        .sheet(isPresented: $isForumFormatPresented) {
            NovelReaderForumFormatSheet(settings: $draftSettings, controlAccent: controlAccent)
        }
    }

    private func heroSection(
        topInset: CGFloat,
        heroHeight: CGFloat,
        palette: NovelReaderSheetPalette
    ) -> some View {
        NovelReaderHeroSection(
            settings: model.fontLibrary.resolving(draftSettings),
            palette: palette,
            previewText: previewTexts[draftSettings.translationMode]
                ?? String(Self.fallbackPreviewText.prefix(Self.previewCharacterCount)),
            topInset: topInset,
            height: heroHeight,
            tapZonesPreviewRequestID: tapZonesPreviewRequestID,
            onClose: { dismiss() },
            onConfirm: commitDraft
        )
    }

    private func settingsSections(palette: NovelReaderSheetPalette) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                NovelReaderTextSection(
                    settings: draftSettings,
                    palette: palette,
                    onFontScaleChange: setFontScale,
                    fontTitle: model.fontLibrary.title(for: draftSettings.fontSelection),
                    onChooseFont: { isFontLibraryPresented = true },
                    onSelectOriginalText: { setTranslationMode(.none) },
                    onSelectSimplifiedText: { setTranslationMode(.simplified) },
                    onSelectTraditionalText: { setTranslationMode(.traditional) }
                )

                NovelReaderLayoutSection(
                    settings: draftSettings,
                    palette: palette,
                    onLineHeightChange: setLineHeightScale,
                    onCharacterSpacingChange: setCharacterSpacingScale,
                    onHorizontalPaddingChange: setHorizontalPadding
                )

                NovelReaderTextOptionsSection(
                    palette: palette,
                    usesJustifiedText: Binding(
                        get: { draftSettings.usesJustifiedText },
                        set: { draftSettings.usesJustifiedText = $0 }
                    ),
                    indentsParagraphFirstLine: Binding(
                        get: { draftSettings.indentsParagraphFirstLine },
                        set: { draftSettings.indentsParagraphFirstLine = $0 }
                    )
                )

                NovelReaderDisplaySection(
                    settings: draftSettings,
                    palette: palette,
                    colorScheme: colorScheme,
                    onBackgroundStyleChange: setBackgroundStyle,
                    onReadingModeChange: setReadingMode,
                    onPageTurnDirectionChange: setPageTurnDirection,
                    onSwapPageTurnTapZonesChange: setSwapPageTurnTapZones,
                    onImmersiveModeChange: { draftSettings.isImmersiveModeEnabled = $0 }
                )

                NovelReaderMiscSection(
                    palette: palette,
                    onOpenForumFormat: { isForumFormatPresented = true },
                    onOpenPeripheralSettings: { isPeripheralSettingsPresented = true }
                )
            }
            .padding(.top, 24)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
    }

    private func loadDraftIfNeeded() {
        guard !hasLoadedDraft else { return }
        draftSettings = model.settings
        previewSourceText = model.previewSourceText(fallback: Self.fallbackPreviewText)
        preparePreview(for: draftSettings.translationMode)
        model.fontLibrary.protect(draftSettings.fontSelection, owner: fontProtectionID)
        hasLoadedDraft = true
    }

    private func commitDraft() {
        let committedSettings = draftSettings
        dismiss()
        Task {
            await model.commitNovelTextAppearance(committedSettings)
        }
    }

    private func setFontScale(_ value: Double) { draftSettings.fontScale = value }
    private func setLineHeightScale(_ value: Double) { draftSettings.lineHeightScale = value }
    private func setCharacterSpacingScale(_ value: Double) { draftSettings.characterSpacingScale = value }
    private func setHorizontalPadding(_ value: Double) { draftSettings.horizontalPadding = value }
    private func setBackgroundStyle(_ value: ReaderBackgroundStyle) { draftSettings.backgroundStyle = value }
    private func setReadingMode(_ value: ReaderReadingMode, pagedTurnStyle: ReaderPagedTurnStyle) {
        draftSettings.readingMode = value
        if value == .paged {
            draftSettings.pagedTurnStyle = pagedTurnStyle
        }
    }
    private func setPageTurnDirection(_ value: ReaderPageTurnDirection) { draftSettings.pageTurnDirection = value }
    private func setSwapPageTurnTapZones(_ value: Bool) {
        draftSettings.swapsPageTurnTapZones = value
        tapZonesPreviewRequestID += 1
    }
    private func setTranslationMode(_ value: ReaderTranslationMode) {
        preparePreview(for: value)
        draftSettings.translationMode = value
    }

    private func preparePreview(for mode: ReaderTranslationMode) {
        guard previewTexts[mode] == nil else { return }
        // Preserve the complete conversion context at the position where the
        // sheet opened. Only the final short preview is cached per mode; font,
        // color and layout drafts must not rejoin/reconvert the forum page.
        let transformed = NovelTextTransformer.transform(previewSourceText, mode: mode)
        previewTexts[mode] = String(transformed.prefix(Self.previewCharacterCount))
    }
}
