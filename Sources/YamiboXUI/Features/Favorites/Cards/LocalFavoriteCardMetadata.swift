import SwiftUI
import YamiboXCore

/// Two plain text lines mirroring the Android card: a reading line with the
/// progress merged in ("最近阅读 3天前 · 62%"), and a content update line.
/// Lines without data simply do not render.
struct LocalFavoriteCardTimeLines: View {
    let card: FavoriteCardProjection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let readingLine {
                Text(readingLine)
                    .lineLimit(1)
            }
            if let updatedLine {
                Text(updatedLine)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var readingLine: String? {
        guard let recentReadingAt = card.recentReadingAt else { return nil }
        var line = L10n.string(
            "favorites.card.recent_read",
            LocalFavoriteRelativeDate.string(from: recentReadingAt)
        )
        if let progress = progressSuffix {
            line += " · \(progress)"
        }
        return line
    }

    /// Manga shows the chapter/page position, novels the surface percent.
    private var progressSuffix: String? {
        if card.item.target.kind == .mangaThread {
            return card.chapterPageProgress
        }
        guard let percent = card.progressPercent else { return nil }
        return "\(percent)%"
    }

    private var updatedLine: String? {
        guard let lastUpdatedAt = card.lastUpdatedAt else { return nil }
        return L10n.string(
            "favorites.card.last_updated",
            LocalFavoriteRelativeDate.string(from: lastUpdatedAt)
        )
    }
}

/// Relative wording within a week ("3天前"), calendar dates beyond it, with
/// the year attached once it differs from the current one.
@MainActor
enum LocalFavoriteRelativeDate {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let sameYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter
    }()

    private static let otherYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMd")
        return formatter
    }()

    static func string(from date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        if date > weekAgo, date <= now {
            // Collapse the whole sub-minute range to "刚刚" instead of
            // letting RelativeDateTimeFormatter spell out seconds (and,
            // right at zero difference, misfire as "0秒后").
            guard now.timeIntervalSince(date) >= 60 else {
                return L10n.string("common.just_now")
            }
            return relativeFormatter.localizedString(for: date, relativeTo: now)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return sameYearFormatter.string(from: date)
        }
        return otherYearFormatter.string(from: date)
    }
}

/// Row of up to three tag chips with a "+N" overflow marker.
struct LocalFavoriteTagChipRow: View {
    let tags: [FavoriteTag]

    private static let visibleLimit = 3

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 6) {
                ForEach(tags.prefix(Self.visibleLimit)) { tag in
                    Text(tag.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tag.color.iconTextColor)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(tag.color.swiftUIColor, in: Capsule())
                }
                if tags.count > Self.visibleLimit {
                    Text("+\(tags.count - Self.visibleLimit)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
