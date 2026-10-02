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
    @State private var isPeripheralSettingsPresented = false
    @State private var isForumFormatPresented = false
    @State private var isFontLibraryPresented = false
    @State private var fontProtectionID = UUID()
    private static let defaultPreviewText = L10n.string("reader.settings.preview_fallback")
    private static let previewCharacterCount = 200
    private static let previewTexts = Dictionary(uniqueKeysWithValues: ReaderTranslationMode.allCases.map { mode in
        let transformed = NovelTextTransformer.transform(defaultPreviewText, mode: mode)
        return (mode, String(transformed.prefix(previewCharacterCount)))
    })

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
            previewText: Self.previewTexts[draftSettings.translationMode]
                ?? String(Self.defaultPreviewText.prefix(Self.previewCharacterCount)),
            topInset: topInset,
            height: heroHeight,
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
    private func setTranslationMode(_ value: ReaderTranslationMode) {
        draftSettings.translationMode = value
    }
}
