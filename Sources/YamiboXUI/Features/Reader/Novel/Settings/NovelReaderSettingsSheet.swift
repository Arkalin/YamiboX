import SwiftUI
import YamiboXCore
import UIKit

struct NovelReaderSettingsSheet: View {
    @ObservedObject var model: NovelReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftSettings = NovelReaderAppearanceSettings()
    @State private var hasLoadedDraft = false
    private static let fallbackPreviewText = L10n.string("reader.settings.preview_fallback")
    private static let previewCharacterCount = 200

    private var showsTwoPageToggle: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && draftSettings.readingMode == .paged
    }

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            let heroHeight = max(300, min(356, proxy.size.height * 0.34)) + topInset
            let palette = NovelReaderSheetPalette(settings: draftSettings, colorScheme: colorScheme)

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
        .onAppear(perform: loadDraftIfNeeded)
    }

    private func heroSection(
        topInset: CGFloat,
        heroHeight: CGFloat,
        palette: NovelReaderSheetPalette
    ) -> some View {
        NovelReaderHeroSection(
            settings: draftSettings,
            palette: palette,
            previewText: model.previewText(
                translationMode: draftSettings.translationMode,
                characterCount: Self.previewCharacterCount,
                fallback: Self.fallbackPreviewText
            ),
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
                    onFontFamilyChange: setFontFamily,
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
                    showsTwoPageToggle: showsTwoPageToggle,
                    showsTwoPagesInLandscapeOnPad: Binding(
                        get: { draftSettings.showsTwoPagesInLandscapeOnPad },
                        set: { draftSettings.showsTwoPagesInLandscapeOnPad = $0 }
                    ),
                    onBackgroundStyleChange: setBackgroundStyle,
                    onReadingModeChange: setReadingMode,
                    onPageTurnDirectionChange: setPageTurnDirection
                )

                NovelReaderMiscSection(
                    palette: palette,
                    loadsInlineImages: draftSettings.loadsInlineImages,
                    showsAuthorRepliesToOthers: draftSettings.showsAuthorRepliesToOthers,
                    onLoadsInlineImagesChange: setImageLoading,
                    onShowsAuthorRepliesToOthersChange: setAuthorReplyVisibility
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
    private func setFontFamily(_ value: ReaderFontFamily) { draftSettings.fontFamily = value }
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
    private func setTranslationMode(_ value: ReaderTranslationMode) { draftSettings.translationMode = value }
    private func setImageLoading(_ value: Bool) { draftSettings.loadsInlineImages = value }
    private func setAuthorReplyVisibility(_ value: Bool) { draftSettings.showsAuthorRepliesToOthers = value }
}
