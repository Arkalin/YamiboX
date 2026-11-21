import YamiboXCore

enum MessageUnreadBadge {
    static func text(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    static func accessibilityValue(for count: Int) -> String {
        count > 0 ? L10n.string("message_center.unread_accessibility", count) : ""
    }
}
