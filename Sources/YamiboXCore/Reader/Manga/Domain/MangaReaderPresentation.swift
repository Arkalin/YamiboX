import Foundation

public struct MangaReaderPresentation: Hashable, Sendable {
    public var state: MangaReaderPresentationState
    public var settings: MangaReaderSettings

    public init(
        state: MangaReaderPresentationState,
        settings: MangaReaderSettings = MangaReaderSettings()
    ) {
        self.state = state
        self.settings = settings
    }
}

public enum MangaReaderPresentationState: Hashable, Sendable {
    case loading(MangaReaderLoadingPresentation)
    case loaded(MangaReaderLoadedPresentation)
    case failed(MangaReaderErrorPresentation)
}

public struct MangaReaderLoadingPresentation: Hashable, Sendable {
    public var title: String

    public init(title: String) {
        self.title = title
    }
}

public struct MangaReaderLoadedPresentation: Hashable, Sendable {
    public var title: String
    public var directoryTitle: String
    public var pages: [MangaReaderPageProjection]
    public var currentPage: MangaReaderPageProjection?
    public var currentPageIndex: Int?
    public var readingPosition: MangaReadingPosition?
    public var directoryPanel: MangaDirectoryPanelPresentation
    public var viewportPlacement: MangaNovelReaderViewportPlacement?

    public init(
        title: String,
        directoryTitle: String,
        pages: [MangaReaderPageProjection],
        currentPage: MangaReaderPageProjection?,
        currentPageIndex: Int?,
        readingPosition: MangaReadingPosition?,
        directoryPanel: MangaDirectoryPanelPresentation = MangaDirectoryPanelPresentation(),
        viewportPlacement: MangaNovelReaderViewportPlacement? = nil
    ) {
        self.title = title
        self.directoryTitle = directoryTitle
        self.pages = pages
        self.currentPage = currentPage
        self.currentPageIndex = currentPageIndex
        self.readingPosition = readingPosition
        self.directoryPanel = directoryPanel
        self.viewportPlacement = viewportPlacement
    }
}

public struct MangaDirectoryPanelCommandState: Hashable, Sendable {
    public var isUpdating: Bool
    public var cooldownRemaining: Int
    public var forcedSearchShortcutRemaining: Int?
    public var errorMessage: String?

    public init(
        isUpdating: Bool = false,
        cooldownRemaining: Int = 0,
        forcedSearchShortcutRemaining: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.isUpdating = isUpdating
        self.cooldownRemaining = max(0, cooldownRemaining)
        self.forcedSearchShortcutRemaining = forcedSearchShortcutRemaining.map { max(0, $0) }
        self.errorMessage = errorMessage
    }
}

public struct MangaDirectoryPanelPresentation: Hashable, Sendable {
    public var directoryTitle: String
    public var displayChapters: [MangaChapter]
    public var currentChapterTID: String?
    public var latestChapterText: String?
    public var sortOrder: MangaDirectorySortOrder
    public var updateButtonTitle: String
    public var isUpdateButtonEnabled: Bool
    public var isSearchMode: Bool
    public var shouldForceSearchOnUpdate: Bool
    public var isUpdating: Bool
    public var editDraft: MangaDirectoryEditDraft?
    public var errorMessage: String?

    public init(
        directoryTitle: String = "",
        displayChapters: [MangaChapter] = [],
        currentChapterTID: String? = nil,
        latestChapterText: String? = nil,
        sortOrder: MangaDirectorySortOrder = .ascending,
        updateButtonTitle: String = "",
        isUpdateButtonEnabled: Bool = false,
        isSearchMode: Bool = false,
        shouldForceSearchOnUpdate: Bool = false,
        isUpdating: Bool = false,
        editDraft: MangaDirectoryEditDraft? = nil,
        errorMessage: String? = nil
    ) {
        self.directoryTitle = directoryTitle
        self.displayChapters = displayChapters
        self.currentChapterTID = currentChapterTID
        self.latestChapterText = latestChapterText
        self.sortOrder = sortOrder
        self.updateButtonTitle = updateButtonTitle
        self.isUpdateButtonEnabled = isUpdateButtonEnabled
        self.isSearchMode = isSearchMode
        self.shouldForceSearchOnUpdate = shouldForceSearchOnUpdate
        self.isUpdating = isUpdating
        self.editDraft = editDraft
        self.errorMessage = errorMessage
    }
}

public struct MangaNovelReaderViewportPlacement: Hashable, Sendable {
    public var targetPageIndex: Int
    public var animated: Bool
    public var revision: Int

    public init(targetPageIndex: Int, animated: Bool = false, revision: Int) {
        self.targetPageIndex = max(0, targetPageIndex)
        self.animated = animated
        self.revision = revision
    }
}

public struct MangaReaderErrorPresentation: Hashable, Sendable {
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}
