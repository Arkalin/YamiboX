import SwiftUI
import YamiboXCore

struct SettingsStorageSummaryView: View {
    let summary: SettingsStorageSummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.string("settings.storage_usage_total"))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer(minLength: 12)
                    Text(summary.totalLabel)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("settings.storage_usage_total"))
                        .foregroundStyle(.secondary)
                    Text(summary.totalLabel)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)

            SettingsStorageDistributionBar(summary: summary)

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), alignment: .leading),
                    count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
                ),
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(summary.categories) { usage in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(usage.category.color)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(usage.category.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(usage.category.title)
                    .accessibilityValue(usage.bytes.map(SettingsStorageUsage.cacheLabel(for:))
                        ?? L10n.string(summary.hasLoaded
                            ? "settings.storage_usage_unavailable" : "settings.storage_usage_calculating"))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SettingsStorageDistributionBar: View {
    let summary: SettingsStorageSummary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(summary.categories) { usage in
                    Rectangle()
                        .fill(usage.category.color)
                        .frame(width: geometry.size.width * summary.fraction(for: usage))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
        }
        .frame(height: 12)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: summary)
        .accessibilityHidden(true)
    }
}

private extension SettingsStorageCategory {
    var color: Color {
        switch self {
        case .webReader: .blue
        case .images: .teal
        case .other: .gray
        case .covers: .pink
        case .progress: .green
        case .history: .cyan
        case .directories: .indigo
        case .offline: .orange
        }
    }
}
