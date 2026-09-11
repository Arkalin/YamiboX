import Foundation
@preconcurrency import GRDB

/// Account-scoped local drafts. Tombstones and database generations reject late
/// saves after deletion/reset, including saves from another instance of the store.
public actor ForumComposerDraftStore {
    private let database: DatabasePool
    private let resourceDirectory: URL
    private nonisolated let broadcaster = StoreChangeBroadcaster()
    public nonisolated func changes() -> AsyncStream<String> { broadcaster.changes() }

    public init(databasePool: DatabasePool? = nil, baseDirectory: URL? = nil) {
        database = databasePool ?? YamiboDatabasePoolResolver.openDefaultPool(storeName: "ForumComposerDraftStore")
        resourceDirectory = baseDirectory ?? YamiboDatabase.defaultRootDirectory().appendingPathComponent("composer-drafts", isDirectory: true)
    }

    public func generation() async throws -> UUID {
        try await database.read { db in
            guard let value = try String.fetchOne(db, sql: "SELECT generation FROM forum_composer_draft_generation WHERE id = 1"),
                  let id = UUID(uuidString: value) else { throw ForumComposerDraftError.invalidDraft }
            return id
        }
    }

    public func drafts(accountUID: String) async throws -> [ForumComposerDraft] {
        try await database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM forum_composer_drafts WHERE account_uid = ? AND deleted = 0 ORDER BY updated_at DESC, id", arguments: [accountUID]).map {
                let draft = try JSONDecoder().decode(ForumComposerDraft.self, from: $0)
                guard draft.accountUID == accountUID else { throw ForumComposerDraftError.accountMismatch }
                return draft
            }
        }
    }

    public func draft(id: UUID, accountUID: String) async throws -> ForumComposerDraft? {
        try await database.read { db in
            guard let payload = try Data.fetchOne(db, sql: "SELECT payload FROM forum_composer_drafts WHERE id = ? AND account_uid = ? AND deleted = 0", arguments: [id.uuidString, accountUID]) else { return nil }
            let draft = try JSONDecoder().decode(ForumComposerDraft.self, from: payload)
            guard draft.accountUID == accountUID else { throw ForumComposerDraftError.accountMismatch }
            return draft
        }
    }

    public func save(_ draft: ForumComposerDraft, expecting revision: Int64?, generation: UUID) async throws {
        guard (Int(draft.accountUID) ?? 0) > 0, draft.revision > 0, (revision ?? 0) < Int64.max, draft.revision == (revision ?? 0) + 1,
              draft.fields.keys.allSatisfy(ForumComposerDraftFields.isRestorable),
              draft.attachments.allSatisfy({ $0.uploadID == nil || ($0.uploadID.flatMap(Int.init) ?? 0) > 0 }) else { throw ForumComposerDraftError.invalidDraft }
        let data = try JSONEncoder().encode(draft)
        try await database.write { db in
            try Self.checkGeneration(generation, in: db)
            let current = try Row.fetchOne(db, sql: "SELECT account_uid, revision, deleted FROM forum_composer_drafts WHERE id = ?", arguments: [draft.id.uuidString])
            if let current {
                guard current["account_uid"] as String == draft.accountUID else { throw ForumComposerDraftError.accountMismatch }
                guard !(current["deleted"] as Bool) else { throw ForumComposerDraftError.deleted }
                guard let revision, current["revision"] as Int64 == revision else { throw ForumComposerDraftError.conflict }
            } else if revision != nil { throw ForumComposerDraftError.conflict }
            for resource in draft.attachments.compactMap(\.resourceID) {
                if let row = try Row.fetchOne(db, sql: "SELECT account_uid, draft_id FROM forum_composer_draft_resources WHERE id = ?", arguments: [resource.uuidString]) {
                    guard row["account_uid"] as String == draft.accountUID, row["draft_id"] as String == draft.id.uuidString else { throw ForumComposerDraftError.accountMismatch }
                }
            }
            try db.execute(sql: """
                INSERT INTO forum_composer_drafts (id, account_uid, revision, updated_at, deleted, payload) VALUES (?, ?, ?, ?, 0, ?)
                ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, updated_at = excluded.updated_at, payload = excluded.payload
                """, arguments: [draft.id.uuidString, draft.accountUID, draft.revision, draft.updatedAt.timeIntervalSince1970, data])
        }
        broadcaster.post()
    }

    @discardableResult
    public func delete(id: UUID, accountUID: String, expecting revision: Int64? = nil, generation: UUID) async throws -> Bool {
        let resources: [String]? = try await database.write { db in
            try Self.checkGeneration(generation, in: db)
            let row = try Row.fetchOne(db, sql: "SELECT account_uid, revision, deleted FROM forum_composer_drafts WHERE id = ?", arguments: [id.uuidString])
            if let row {
                guard row["account_uid"] as String == accountUID else { throw ForumComposerDraftError.accountMismatch }
                if let revision, row["revision"] as Int64 != revision { return nil }
            } else if revision != nil { return nil }
            let current: Int64 = row?["revision"] ?? 0
            let next = current == Int64.max ? current : current + 1
            try db.execute(sql: """
                INSERT INTO forum_composer_drafts (id, account_uid, revision, updated_at, deleted, payload) VALUES (?, ?, ?, ?, 1, NULL)
                ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, deleted = 1, payload = NULL
                """, arguments: [id.uuidString, accountUID, next, Date.now.timeIntervalSince1970])
            let ids = try String.fetchAll(db, sql: "SELECT id FROM forum_composer_draft_resources WHERE draft_id = ? AND account_uid = ?", arguments: [id.uuidString, accountUID])
            try db.execute(sql: "DELETE FROM forum_composer_draft_resources WHERE draft_id = ? AND account_uid = ?", arguments: [id.uuidString, accountUID])
            return ids
        }
        guard let resources else { return false }
        removeFiles(resources)
        broadcaster.post()
        return true
    }

    public func importResource(_ file: ForumAttachmentFile, draftID: UUID, accountUID: String, generation: UUID) async throws -> UUID {
        guard !file.data.isEmpty, file.data.count <= 50 * 1024 * 1024, (Int(accountUID) ?? 0) > 0 else { throw ForumComposerDraftError.invalidDraft }
        let id = UUID()
        let destination = resourceURL(id)
        try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
        try file.data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            try await database.write { db in
                try Self.checkGeneration(generation, in: db)
                if let row = try Row.fetchOne(db, sql: "SELECT account_uid, deleted FROM forum_composer_drafts WHERE id = ?", arguments: [draftID.uuidString]) {
                    guard row["account_uid"] as String == accountUID else { throw ForumComposerDraftError.accountMismatch }
                    guard !(row["deleted"] as Bool) else { throw ForumComposerDraftError.deleted }
                }
                try db.execute(sql: "INSERT INTO forum_composer_draft_resources (id, draft_id, account_uid, name) VALUES (?, ?, ?, ?)", arguments: [id.uuidString, draftID.uuidString, accountUID, file.name])
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return id
    }

    public func resource(id: UUID, accountUID: String) async throws -> ForumAttachmentFile {
        guard let name = try await database.read({ db in
            try String.fetchOne(db, sql: "SELECT name FROM forum_composer_draft_resources WHERE id = ? AND account_uid = ?", arguments: [id.uuidString, accountUID])
        }) else { throw ForumComposerDraftError.missingResource }
        do { return try ForumAttachmentFile(name: name, data: Data(contentsOf: resourceURL(id))) }
        catch { throw ForumComposerDraftError.missingResource }
    }

    public func removeUnreferencedResources(draftID: UUID, accountUID: String, generation: UUID) async throws {
        let resources: [String] = try await database.write { db in
            try Self.checkGeneration(generation, in: db)
            let payload = try Data.fetchOne(db, sql: "SELECT payload FROM forum_composer_drafts WHERE id = ? AND account_uid = ? AND deleted = 0", arguments: [draftID.uuidString, accountUID])
            let draft = try payload.map { try JSONDecoder().decode(ForumComposerDraft.self, from: $0) }
            let referenced = Set(draft?.attachments.compactMap(\.resourceID).map(\.uuidString) ?? [])
            let ids = try String.fetchAll(db, sql: "SELECT id FROM forum_composer_draft_resources WHERE draft_id = ? AND account_uid = ?", arguments: [draftID.uuidString, accountUID]).filter { !referenced.contains($0) }
            for id in ids { try db.execute(sql: "DELETE FROM forum_composer_draft_resources WHERE id = ?", arguments: [id]) }
            return ids
        }
        removeFiles(resources)
    }

    public func clearAll() async throws {
        let ownedFiles = (try? FileManager.default.contentsOfDirectory(atPath: resourceDirectory.path)) ?? []
        let resources = try await database.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM forum_composer_draft_resources")
            try ForumComposerDraftDatabaseSchema.erase(in: db)
            return ids
        }
        removeFiles(Array(Set(resources + ownedFiles)))
        broadcaster.post()
    }

    private static func checkGeneration(_ generation: UUID, in db: Database) throws {
        guard try String.fetchOne(db, sql: "SELECT generation FROM forum_composer_draft_generation WHERE id = 1") == generation.uuidString else { throw ForumComposerDraftError.reset }
    }

    private func resourceURL(_ id: UUID) -> URL { resourceDirectory.appendingPathComponent(id.uuidString) }

    private func removeFiles(_ ids: [String]) {
        for id in ids {
            guard let id = UUID(uuidString: id) else { continue }
            try? FileManager.default.removeItem(at: resourceURL(id))
        }
    }
}
