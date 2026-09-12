import Foundation
import YamiboXCore

#if os(iOS)
struct MangaImageActionTarget: Identifiable {
    let page: MangaReaderPageProjection

    var id: String {
        page.id
    }
}

struct MangaImageSaveFeedback: Identifiable {
    enum Kind {
        case success
        case custom(title: String, message: String)
        case failure(String)
    }

    let id = UUID()
    let kind: Kind
    var details: LoadFailureDetails? = nil

    static var success: MangaImageSaveFeedback { MangaImageSaveFeedback(kind: .success) }

    static func custom(title: String, message: String) -> MangaImageSaveFeedback {
        MangaImageSaveFeedback(kind: .custom(title: title, message: message))
    }

    static func failure(message: String, details: LoadFailureDetails? = nil) -> MangaImageSaveFeedback {
        MangaImageSaveFeedback(kind: .failure(message), details: details ?? LoadFailureDetails(message: message))
    }

    var transientFeedback: TransientFeedback {
        TransientFeedback(
            message: [title, message].filter { !$0.isEmpty }.joined(separator: "\n"),
            details: details,
            id: id
        )
    }

    var title: String {
        switch kind {
        case .success:
            L10n.string("image.save_success_title")
        case let .custom(title, _):
            title
        case .failure:
            L10n.string("common.operation_failed")
        }
    }

    var message: String {
        switch kind {
        case .success:
            L10n.string("image.save_success_message")
        case let .custom(_, message):
            message
        case let .failure(message):
            message
        }
    }
}

struct MangaImageSavePresentationState {
    var actionTarget: MangaImageActionTarget?
    var isActionDialogPresented = false
    var feedback: MangaImageSaveFeedback?

    mutating func presentActions(for page: MangaReaderPageProjection) {
        actionTarget = MangaImageActionTarget(page: page)
        isActionDialogPresented = true
    }

    mutating func setActionDialogPresented(_ isPresented: Bool) {
        isActionDialogPresented = isPresented
    }

    mutating func clearActionTarget() {
        actionTarget = nil
    }

    mutating func finishSave(with nextFeedback: MangaImageSaveFeedback) {
        feedback = nextFeedback
    }

    mutating func clearFeedback(id: MangaImageSaveFeedback.ID) {
        guard feedback?.id == id else { return }
        feedback = nil
    }
}
#endif
