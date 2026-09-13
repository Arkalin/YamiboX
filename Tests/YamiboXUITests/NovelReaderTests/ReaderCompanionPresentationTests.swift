import Testing
@testable import YamiboXUI

@Test(arguments: [NovelReaderPresentedSheet.annotations, .chapterComments])
func readerCompanionsUseTheLargePanelHost(_ panel: NovelReaderPresentedSheet) {
    #expect(panel.isCompanionPanel)
    let presentation: NovelReaderPresentedSheet? = panel
    #expect(presentation.isCompanionPresented)
    #expect(presentation.modalSheet == nil)
}

@Test(arguments: [NovelReaderPresentedSheet.settings, .cachePanel, .cacheProgress])
func completeReaderSettingsAndCacheRemainModal(_ sheet: NovelReaderPresentedSheet) {
    #expect(!sheet.isCompanionPanel)
    let presentation: NovelReaderPresentedSheet? = sheet
    #expect(!presentation.isCompanionPresented)
    #expect(presentation.modalSheet == sheet)
}

@Test func novelReaderPresentationRoutesToExactlyOnePresentationHost() {
    var presentation: NovelReaderPresentedSheet? = .annotations
    #expect(presentation.isCompanionPresented)
    #expect(presentation.modalSheet == nil)

    presentation.modalSheet = .settings
    #expect(!presentation.isCompanionPresented)
    #expect(presentation.modalSheet == .settings)

    presentation.modalSheet = nil
    #expect(presentation == nil)
    #expect(!presentation.isCompanionPresented)
}

@Test func dismissingPreviousModalDoesNotDismissANewCompanion() {
    var presentation: NovelReaderPresentedSheet? = .chapterComments
    presentation.modalSheet = nil
    #expect(presentation == .chapterComments)
    presentation.isCompanionPresented = false
    #expect(presentation == nil)
}

@Test func dismissingPreviousCompanionDoesNotDismissANewModal() {
    var presentation: NovelReaderPresentedSheet? = .settings
    presentation.isCompanionPresented = false
    #expect(presentation == .settings)
}

@Test func mangaCompanionDestinationIsExclusiveAndCanBeDismissed() {
    var presentation: MangaReaderCompanion? = .annotations
    #expect(presentation.isPresented)
    presentation = .comments
    #expect(presentation == .comments)
    presentation.isPresented = false
    #expect(presentation == nil)
}
