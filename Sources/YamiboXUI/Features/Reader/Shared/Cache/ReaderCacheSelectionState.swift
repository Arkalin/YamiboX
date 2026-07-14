import Foundation

/// Selection summary shared by the manga and novel reader cache sheets.
public struct ReaderCacheSelectionState: Equatable, Sendable {
    public var selectedTIDs: Set<String>
    public var uncachedSelectedTIDs: Set<String>
    public var removableSelectedTIDs: Set<String>
    public var canCache: Bool
    public var canDelete: Bool
    public var isAllSelected: Bool

    public init(
        selectedTIDs: Set<String>,
        uncachedSelectedTIDs: Set<String>,
        removableSelectedTIDs: Set<String>,
        canCache: Bool,
        canDelete: Bool,
        isAllSelected: Bool
    ) {
        self.selectedTIDs = selectedTIDs
        self.uncachedSelectedTIDs = uncachedSelectedTIDs
        self.removableSelectedTIDs = removableSelectedTIDs
        self.canCache = canCache
        self.canDelete = canDelete
        self.isAllSelected = isAllSelected
    }
}
