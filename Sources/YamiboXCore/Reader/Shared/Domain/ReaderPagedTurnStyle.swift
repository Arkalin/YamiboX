import Foundation

public enum ReaderPagedTurnStyle: String, Codable, Hashable, CaseIterable, Sendable {
    case slide
    case pageCurl
    case quickFade

    public var title: String {
        switch self {
        case .slide: L10n.string("reading_mode.slide")
        case .pageCurl: L10n.string("reading_mode.page_curl")
        case .quickFade: L10n.string("reading_mode.quick_fade")
        }
    }
}
