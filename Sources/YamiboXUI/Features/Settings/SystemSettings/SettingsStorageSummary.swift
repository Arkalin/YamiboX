import Foundation
import YamiboXCore

enum SettingsStorageCategory: String, CaseIterable, Identifiable {
    case webReader, images, other, covers, progress, history, directories, offline

    var id: Self { self }

    var title: String {
        L10n.string("settings.storage_category.\(rawValue)")
    }
}

struct SettingsStorageCategoryUsage: Identifiable, Equatable {
    let category: SettingsStorageCategory
    let bytes: Int?

    var id: SettingsStorageCategory { category }
}

struct SettingsStorageSummary: Equatable {
    let categories: [SettingsStorageCategoryUsage]
    let hasLoaded: Bool

    /// Unknown categories must not silently turn a partial sum into a total.
    var totalBytes: Int? {
        guard hasLoaded, categories.allSatisfy({ $0.bytes != nil }) else { return nil }
        return categories.reduce(0) { $0 + max(0, $1.bytes ?? 0) }
    }

    var totalLabel: String {
        guard let totalBytes else {
            return L10n.string(hasLoaded ? "settings.storage_usage_unavailable" : "settings.storage_usage_calculating")
        }
        let label = SettingsStorageUsage.cacheLabel(for: totalBytes)
        return totalBytes == 0 ? label : L10n.string("settings.storage_usage_total_value", label)
    }

    func fraction(for category: SettingsStorageCategoryUsage) -> Double {
        guard let totalBytes, totalBytes > 0 else { return 0 }
        return Double(max(0, category.bytes ?? 0)) / Double(totalBytes)
    }
}
