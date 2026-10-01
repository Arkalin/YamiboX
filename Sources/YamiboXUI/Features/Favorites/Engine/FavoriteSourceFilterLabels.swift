import Foundation
import YamiboXCore

/// First usable item name for each board, shared by filter rows and chips.
/// Filter identity ignores its label, so a retained ID-only filter must still
/// see names supplied by newer items in the library.
struct FavoriteSourceFilterLabels {
    private var itemNamesByBoardID: [String: String] = [:]

    init(items: [FavoriteItem]) {
        for item in items {
            let explicitID = item.forumID
            let sourceID = item.sourceGroup.forumID
            if let explicitID {
                recordName(from: item, for: explicitID)
            }
            // Decoding can retain inconsistent metadata: matches(_:) accepts
            // either ID, so index both without normalizing the explicit one.
            if let sourceID, sourceID != explicitID {
                recordName(from: item, for: sourceID)
            }
        }
    }

    func label(for filter: LocalFavoriteSourceFilter, boardReaderSettings: BoardReaderSettings) -> String {
        guard case let .forumBoard(id, label) = filter else { return filter.displayLabel }
        return itemNamesByBoardID[id]
            ?? Self.usableName(boardReaderSettings.entry(forumID: id)?.boardName, for: id)
            ?? Self.usableName(label, for: id)
            ?? Self.usableName(BoardReaderSettings.factoryDefault.entry(forumID: id)?.boardName, for: id)
            ?? L10n.string("settings.board_reader.board_placeholder", id)
    }

    private mutating func recordName(from item: FavoriteItem, for id: String) {
        guard itemNamesByBoardID[id] == nil else { return }
        itemNamesByBoardID[id] = Self.usableName(item.forumName, for: id)
            ?? Self.usableName(item.sourceGroup.forumName, for: id)
    }

    private static func usableName(_ value: String?, for id: String) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name != id else { return nil }
        return name
    }
}
