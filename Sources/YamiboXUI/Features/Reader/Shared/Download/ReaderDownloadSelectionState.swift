import Foundation

/// Selection summary shared by the manga and novel reader download sheets.
public struct ReaderDownloadSelectionState: Equatable, Sendable {
    public var selectedTIDs: Set<String>
    public var notDownloadedSelectedTIDs: Set<String>
    public var removableSelectedTIDs: Set<String>
    public var canDownload: Bool
    public var canDelete: Bool
    public var isAllSelected: Bool

    public init(
        selectedTIDs: Set<String>,
        notDownloadedSelectedTIDs: Set<String>,
        removableSelectedTIDs: Set<String>,
        canDownload: Bool,
        canDelete: Bool,
        isAllSelected: Bool
    ) {
        self.selectedTIDs = selectedTIDs
        self.notDownloadedSelectedTIDs = notDownloadedSelectedTIDs
        self.removableSelectedTIDs = removableSelectedTIDs
        self.canDownload = canDownload
        self.canDelete = canDelete
        self.isAllSelected = isAllSelected
    }
}
