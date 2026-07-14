import Foundation

enum NovelReaderChromeMode: Equatable {
    case loading
    case error
    case visible
    case immersiveHidden

    var showsChrome: Bool {
        self != .immersiveHidden
    }
}

struct NovelReaderChromeState: Equatable {
    private(set) var mode: NovelReaderChromeMode = .loading
    private(set) var showsChrome = true
    private(set) var hasCompletedInitialAutoHide = false
    private(set) var overlayRestoreMode: NovelReaderChromeMode?

    init(showsChrome: Bool = true) {
        self.showsChrome = showsChrome
    }

    mutating func update(
        isLoading: Bool,
        errorMessage: String?,
        hasPages: Bool,
        hasPresentedOverlay: Bool,
        usesVerticalReadingMode: Bool = false
    ) {
        if hasPresentedOverlay {
            if overlayRestoreMode == nil {
                overlayRestoreMode = mode
            }
            mode = .visible
            showsChrome = true
            return
        }

        if let overlayRestoreMode {
            mode = overlayRestoreMode
            self.overlayRestoreMode = nil
            showsChrome = mode.showsChrome
        }

        if isLoading && !hasPages {
            hasCompletedInitialAutoHide = false
            mode = .loading
            showsChrome = !usesVerticalReadingMode
            return
        }

        if errorMessage != nil && !hasPages {
            hasCompletedInitialAutoHide = false
            mode = .error
            showsChrome = true
            return
        }

        guard hasPages else {
            hasCompletedInitialAutoHide = false
            return
        }

        guard !hasCompletedInitialAutoHide else { return }
        hasCompletedInitialAutoHide = true
        mode = .immersiveHidden
        showsChrome = false
    }

    mutating func toggleChrome() {
        mode = mode == .immersiveHidden ? .visible : .immersiveHidden
        showsChrome = mode.showsChrome
    }

    mutating func hideChrome() {
        mode = .immersiveHidden
        showsChrome = false
    }

    mutating func showChrome() {
        mode = .visible
        showsChrome = true
    }
}
