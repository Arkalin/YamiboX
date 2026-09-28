import Foundation

public enum LocalFavoriteLibrarySortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case organization
    case contentUpdatedAt
    case yamiboRemoteOrder
    case displayTitle
    case sourceGroup
    case lastReadAt

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .organization:
            L10n.string("favorites.sort.manual")
        case .contentUpdatedAt:
            L10n.string("favorites.sort.updated_at")
        case .yamiboRemoteOrder:
            L10n.string("favorites.sort.remote_order")
        case .displayTitle:
            L10n.string("favorites.sort.title")
        case .sourceGroup:
            L10n.string("favorites.source_group")
        case .lastReadAt:
            L10n.string("favorites.sort.recent_read")
        }
    }
}
