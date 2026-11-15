import Observation
import YamiboXCore

@MainActor
@Observable
final class MangaReaderSessionState {
    let model: MangaReaderViewModel
    let viewportHandoff = MangaViewportHandoff()
    var isDismissing = false
    var isChromeVisible = true
    var companionPanel: MangaReaderCompanion?
    var forumThreadOverlayItem: ForumThreadOverlayItem?
    var isSettingsPresented = false
    var isDownloadPresented = false
    var rememberedAnnotationSegment: ReaderAnnotationSegment?
    var readerLibraryTab: ReaderLibraryPanelTab = .bookmarks
    var likedItemForActionTarget: LikeItem?
    var noteEditTarget: LikeItem?
    var imageSavePresentation = MangaImageSavePresentationState()
    var isPhotoPermissionAlertPresented = false
    var canRestoreMangaCover = false
    var isSavingImage = false

    @ObservationIgnored private var preparation: Task<Void, Never>?

    init(model: MangaReaderViewModel) {
        self.model = model
    }

    deinit { preparation?.cancel() }

    func prepareIfNeeded() {
        guard preparation == nil else { return }
        preparation = Task { [model] in
            await model.prepare()
        }
    }

    func end() {
        preparation?.cancel()
        preparation = nil
    }
}
