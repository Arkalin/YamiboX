import Foundation
@preconcurrency import GRDB

/// Rewrites only this feature's references using the caller's transaction.
enum FavoriteLibraryIdentityRemapping {
    static func normalize(_ document: FavoriteLibraryDocument, identities: MangaDirectoryIdentitySnapshot, legacy: Bool) -> FavoriteLibraryDocument {
        var result = document
        for index in result.items.indices {
            if case let .smartManga(id, name) = result.items[index].sourceGroup {
                result.items[index].sourceGroup = .smartManga(
                    mangaID: identities.resolve(id, name: name, legacy: legacy), cleanBookName: name)
            }
        }
        return result
    }

    private static func normalize(_ target: FavoriteUpdateTargetKey, identities: MangaDirectoryIdentitySnapshot, legacy: Bool) -> FavoriteUpdateTargetKey {
        switch target {
        case .favorite: return target
        case let .mangaDirectory(id):
            return .mangaDirectory(directoryID: MangaDirectoryID(rawValue: identities.resolve(id.rawValue, legacy: legacy)))
        }
    }

    static func normalizeTracking(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        var targets: [String: FavoriteUpdateTrackedTarget] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT target_json FROM favorite_update_tracked_targets ORDER BY target_id") {
            var target = try JSONDecoder().decode(FavoriteUpdateTrackedTarget.self, from: Data((row["target_json"] as String).utf8))
            target.target = normalize(target.target, identities: snapshot, legacy: legacy)
            if let existing = targets[target.id] {
                target.knownChapterTIDs = (target.knownChapterTIDs ?? []).union(existing.knownChapterTIDs ?? [])
                target.categoryIDs.formUnion(existing.categoryIDs)
            }
            targets[target.id] = target
        }
        try db.execute(sql: "DELETE FROM favorite_update_tracked_targets")
        for target in targets.values {
            try db.execute(sql: "INSERT INTO favorite_update_tracked_targets(target_id, target_json) VALUES (?, ?)", arguments: [target.id, String(decoding: try JSONEncoder().encode(target), as: UTF8.self)])
        }
        var activeTargets: Set<String> = []
        for row in try Row.fetchAll(db, sql: "SELECT id, event_json FROM favorite_update_events ORDER BY detected_at DESC, id DESC") {
            var event = try JSONDecoder().decode(FavoriteUpdateEvent.self, from: Data((row["event_json"] as String).utf8))
            event.target = normalize(event.target, identities: snapshot, legacy: legacy)
            let data = try JSONEncoder().encode(event)
            if event.dismissedAt == nil, !activeTargets.insert(event.target.id).inserted {
                try db.execute(sql: "DELETE FROM favorite_update_events WHERE id = ?", arguments: [event.id])
            } else {
                try db.execute(sql: "UPDATE favorite_update_events SET target_id = ?, event_json = ? WHERE id = ?", arguments: [event.target.id, String(decoding: data, as: UTF8.self), event.id])
            }
        }
    }

    static func normalizeDocuments(snapshot: MangaDirectoryIdentitySnapshot, legacy: Bool, in db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT id, document_json FROM favorite_library_document") {
            let document = try JSONDecoder().decode(FavoriteLibraryDocument.self, from: Data((row["document_json"] as String).utf8))
            let data = try JSONEncoder().encode(normalize(document, identities: snapshot, legacy: legacy))
            try db.execute(sql: "UPDATE favorite_library_document SET document_json = ? WHERE id = ?",
                arguments: [String(decoding: data, as: UTF8.self).databaseValue, row["id"] as DatabaseValue])
        }
    }
}
