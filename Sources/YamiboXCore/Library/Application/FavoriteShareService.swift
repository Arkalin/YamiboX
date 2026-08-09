import Foundation

public struct FavoriteSharePackage: Codable, Equatable, Sendable {
    public static let schemaName = "yamibo.favorite-share"
    public static let currentSchemaVersion = 2

    public var schema: String
    public var schemaVersion: Int
    public var exportedAt: Int64
    public var folders: [Folder]

    public init(
        schema: String = Self.schemaName,
        schemaVersion: Int = Self.currentSchemaVersion,
        exportedAt: Int64,
        folders: [Folder]
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.folders = folders
    }

    public struct Folder: Codable, Equatable, Sendable {
        public var name: String
        public var items: [Item]

        public init(name: String, items: [Item]) {
            self.name = name
            self.items = items
        }
    }

    public struct Item: Codable, Equatable, Sendable {
        public var targetType: String
        public var targetId: Int64
        public var authorId: Int64?
        public var title: String
        public var coverUrl: String?
        public var lastUpdatedTime: Int64?
        public var forumId: Int64?
        public var forumName: String?
        public var rssQuery: String?
        public var rssForumId: Int64?
        public var rssForumName: String?

        public init(
            targetType: String,
            targetId: Int64,
            authorId: Int64? = nil,
            title: String,
            coverUrl: String? = nil,
            lastUpdatedTime: Int64? = nil,
            forumId: Int64? = nil,
            forumName: String? = nil,
            rssQuery: String? = nil,
            rssForumId: Int64? = nil,
            rssForumName: String? = nil
        ) {
            self.targetType = targetType
            self.targetId = targetId
            self.authorId = authorId
            self.title = title
            self.coverUrl = coverUrl
            self.lastUpdatedTime = lastUpdatedTime
            self.forumId = forumId
            self.forumName = forumName
            self.rssQuery = rssQuery
            self.rssForumId = rssForumId
            self.rssForumName = rssForumName
        }
    }
}

public struct FavoriteShareExport: Equatable, Sendable {
    public var data: Data
    public var fileName: String
    public var folderCount: Int
    public var itemCount: Int

    public init(data: Data, fileName: String, folderCount: Int, itemCount: Int) {
        self.data = data
        self.fileName = fileName
        self.folderCount = folderCount
        self.itemCount = itemCount
    }
}

public struct FavoriteShareFolderPreview: Equatable, Sendable {
    public var name: String
    public var itemCount: Int
    public var duplicateCount: Int
    public var unsupportedCount: Int
    public var invalidCount: Int

    public init(
        name: String,
        itemCount: Int,
        duplicateCount: Int,
        unsupportedCount: Int,
        invalidCount: Int
    ) {
        self.name = name
        self.itemCount = itemCount
        self.duplicateCount = duplicateCount
        self.unsupportedCount = unsupportedCount
        self.invalidCount = invalidCount
    }
}

public struct FavoriteShareImportPreview: Equatable, Sendable {
    public var folderCount: Int
    public var itemCount: Int
    public var duplicateCount: Int
    public var unsupportedCount: Int
    public var invalidCount: Int
    public var folders: [FavoriteShareFolderPreview]

    public init(
        folderCount: Int,
        itemCount: Int,
        duplicateCount: Int,
        unsupportedCount: Int,
        invalidCount: Int,
        folders: [FavoriteShareFolderPreview]
    ) {
        self.folderCount = folderCount
        self.itemCount = itemCount
        self.duplicateCount = duplicateCount
        self.unsupportedCount = unsupportedCount
        self.invalidCount = invalidCount
        self.folders = folders
    }

    public var importableCount: Int {
        itemCount - duplicateCount - unsupportedCount - invalidCount
    }
}

public enum FavoriteShareImportTarget: Equatable, Sendable {
    case createFolders
    case addToExistingFolders(categoryIDs: Set<String>)
}

public struct FavoriteShareImportResult: Equatable, Sendable {
    public var createdFolderCount: Int
    public var createdItemCount: Int
    public var reusedItemCount: Int
    public var skippedDuplicateCount: Int
    public var unsupportedCount: Int
    public var invalidCount: Int

    public init(
        createdFolderCount: Int,
        createdItemCount: Int,
        reusedItemCount: Int,
        skippedDuplicateCount: Int,
        unsupportedCount: Int,
        invalidCount: Int
    ) {
        self.createdFolderCount = createdFolderCount
        self.createdItemCount = createdItemCount
        self.reusedItemCount = reusedItemCount
        self.skippedDuplicateCount = skippedDuplicateCount
        self.unsupportedCount = unsupportedCount
        self.invalidCount = invalidCount
    }
}

public enum FavoriteShareError: LocalizedError, Equatable, Sendable {
    case invalidFormat(String)
    case unsupportedSchema(String)
    case unsupportedVersion(Int)
    case emptyFolders
    case blankFolderName(Int)
    case emptyExportSelection
    case missingExportCategories
    case invalidLocalItem(String)
    case emptyImportSelection
    case missingImportCategories

    public var errorDescription: String? {
        switch self {
        case let .invalidFormat(message):
            L10n.string("favorites.share.error.invalid_format", message)
        case let .unsupportedSchema(schema):
            L10n.string("favorites.share.error.unsupported_schema", schema)
        case let .unsupportedVersion(version):
            L10n.string("favorites.share.error.unsupported_version", version)
        case .emptyFolders:
            L10n.string("favorites.share.error.empty_folders")
        case let .blankFolderName(index):
            L10n.string("favorites.share.error.blank_folder_name", index)
        case .emptyExportSelection:
            L10n.string("favorites.share.error.empty_export_selection")
        case .missingExportCategories:
            L10n.string("favorites.share.error.missing_export_categories")
        case let .invalidLocalItem(title):
            L10n.string("favorites.share.error.invalid_local_item", title)
        case .emptyImportSelection:
            L10n.string("favorites.share.error.empty_import_selection")
        case .missingImportCategories:
            L10n.string("favorites.share.error.missing_import_categories")
        }
    }
}

public enum FavoriteShareCodec {
    public static func encode(_ package: FavoriteSharePackage) throws -> Data {
        try validate(package)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(package)
    }

    public static func decode(_ data: Data) throws -> FavoriteSharePackage {
        let payload = stripUTF8BOM(from: data)
        let package: FavoriteSharePackage
        do {
            package = try JSONDecoder().decode(FavoriteSharePackage.self, from: payload)
        } catch {
            throw FavoriteShareError.invalidFormat(error.localizedDescription)
        }
        try validate(package)
        return package
    }

    private static func validate(_ package: FavoriteSharePackage) throws {
        guard package.schema == FavoriteSharePackage.schemaName else {
            throw FavoriteShareError.unsupportedSchema(package.schema)
        }
        guard package.schemaVersion == FavoriteSharePackage.currentSchemaVersion else {
            throw FavoriteShareError.unsupportedVersion(package.schemaVersion)
        }
        guard !package.folders.isEmpty else {
            throw FavoriteShareError.emptyFolders
        }
        for (index, folder) in package.folders.enumerated()
            where folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FavoriteShareError.blankFolderName(index + 1)
        }
    }

    private static func stripUTF8BOM(from data: Data) -> Data {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        guard data.count >= bom.count, Array(data.prefix(bom.count)) == bom else {
            return data
        }
        return Data(data.dropFirst(bom.count))
    }
}

public struct FavoriteShareService: Sendable {
    private let libraryStore: FavoriteLibraryStore
    private let contentCoverStore: ContentCoverStore
    private let settingsStore: SettingsStore

    public init(
        libraryStore: FavoriteLibraryStore,
        contentCoverStore: ContentCoverStore,
        settingsStore: SettingsStore
    ) {
        self.libraryStore = libraryStore
        self.contentCoverStore = contentCoverStore
        self.settingsStore = settingsStore
    }

    public func export(categoryIDs: Set<String>, exportedAt: Date = .now) async throws -> FavoriteShareExport {
        guard !categoryIDs.isEmpty else {
            throw FavoriteShareError.emptyExportSelection
        }
        let document = try await libraryStore.load()
        let categories = document.categories.filter { categoryIDs.contains($0.id) }
        guard Set(categories.map(\.id)) == categoryIDs else {
            throw FavoriteShareError.missingExportCategories
        }

        let selectedItems = document.items.filter { item in
            item.locations.contains { categoryIDs.contains($0.categoryID) }
        }
        let coverKeys = selectedItems.compactMap { ContentCoverKey(target: $0.target) }
        let covers = await contentCoverStore.covers(for: coverKeys)

        let folders = try categories.map { category in
            let items = document.items.filter { item in
                item.locations.contains { $0.categoryID == category.id }
            }
            return FavoriteSharePackage.Folder(
                name: category.displayName,
                items: try items.map { try shareItem(for: $0, covers: covers) }
            )
        }
        let package = FavoriteSharePackage(
            exportedAt: Self.milliseconds(since1970: exportedAt),
            folders: folders
        )
        let data = try FavoriteShareCodec.encode(package)
        return FavoriteShareExport(
            data: data,
            fileName: "yamibo-favorites-\(package.exportedAt).json",
            folderCount: folders.count,
            itemCount: folders.reduce(0) { $0 + $1.items.count }
        )
    }

    public func previewImport(data: Data) async throws -> FavoriteShareImportPreview {
        let package = try FavoriteShareCodec.decode(data)
        let document = try await libraryStore.load()
        let boardReaderSettings = await settingsStore.load().boardReader
        let folders = package.folders.map { folder in
            let analyses = folder.items.map {
                analyze($0, document: document, boardReaderSettings: boardReaderSettings)
            }
            return FavoriteShareFolderPreview(
                name: folder.name,
                itemCount: folder.items.count,
                duplicateCount: analyses.count { analysis in
                    if case let .valid(_, existingItem) = analysis { return existingItem != nil }
                    return false
                },
                unsupportedCount: analyses.count { if case .unsupported = $0 { return true }; return false },
                invalidCount: analyses.count { if case .invalid = $0 { return true }; return false }
            )
        }
        return FavoriteShareImportPreview(
            folderCount: folders.count,
            itemCount: folders.reduce(0) { $0 + $1.itemCount },
            duplicateCount: folders.reduce(0) { $0 + $1.duplicateCount },
            unsupportedCount: folders.reduce(0) { $0 + $1.unsupportedCount },
            invalidCount: folders.reduce(0) { $0 + $1.invalidCount },
            folders: folders
        )
    }

    public func importFavorites(
        data: Data,
        target: FavoriteShareImportTarget,
        date: Date = .now
    ) async throws -> FavoriteShareImportResult {
        let package = try FavoriteShareCodec.decode(data)
        let boardReaderSettings = await settingsStore.load().boardReader
        let mutation = try await libraryStore.update { document in
            switch target {
            case .createFolders:
                Self.importAsNewFolders(
                    package,
                    document: &document,
                    boardReaderSettings: boardReaderSettings,
                    date: date
                )
            case let .addToExistingFolders(categoryIDs):
                try Self.importIntoExistingFolders(
                    package,
                    categoryIDs: categoryIDs,
                    document: &document,
                    boardReaderSettings: boardReaderSettings,
                    date: date
                )
            }
        }
        await persistImportedCovers(mutation.covers)
        return mutation.result
    }

    public func `import`(
        data: Data,
        target: FavoriteShareImportTarget,
        date: Date = .now
    ) async throws -> FavoriteShareImportResult {
        try await importFavorites(data: data, target: target, date: date)
    }

    private func shareItem(
        for item: FavoriteItem,
        covers: [ContentCoverKey: ContentCover]
    ) throws -> FavoriteSharePackage.Item {
        guard let rawThreadID = item.target.threadID,
              let targetID = Int64(rawThreadID), targetID > 0 else {
            throw FavoriteShareError.invalidLocalItem(item.resolvedDisplayTitle)
        }
        let title = item.resolvedDisplayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw FavoriteShareError.invalidLocalItem(rawThreadID)
        }
        let targetType: String
        switch item.target.kind {
        case .normalThread, .mangaThread:
            targetType = WireTargetType.threadNormal.rawValue
        case .novelThread:
            targetType = WireTargetType.threadNovel.rawValue
        }
        let coverURL = ContentCoverKey(target: item.target).flatMap { key in
            covers[key]?.resolvedURL.flatMap {
                ContentCoverStore.normalizedCoverURL(from: $0.absoluteString)?.absoluteString
            }
        }
        return FavoriteSharePackage.Item(
            targetType: targetType,
            targetId: targetID,
            title: title,
            coverUrl: coverURL,
            lastUpdatedTime: item.contentUpdatedAt.map(Self.milliseconds(since1970:)),
            forumId: item.forumID.flatMap(Self.positiveInt64),
            forumName: item.forumName
        )
    }

    private func analyze(
        _ item: FavoriteSharePackage.Item,
        document: FavoriteLibraryDocument,
        boardReaderSettings: BoardReaderSettings
    ) -> ItemAnalysis {
        Self.analyze(item, document: document, boardReaderSettings: boardReaderSettings)
    }

    private static func analyze(
        _ item: FavoriteSharePackage.Item,
        document: FavoriteLibraryDocument,
        boardReaderSettings: BoardReaderSettings
    ) -> ItemAnalysis {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, item.targetId > 0 else { return .invalid }
        guard let wireType = WireTargetType(rawValue: item.targetType) else { return .unsupported }
        let target: FavoriteItemTarget
        switch wireType {
        case .threadNovel:
            target = .novelThread(threadID: String(item.targetId))
        case .threadNormal:
            let forumID = item.forumId.flatMap(positiveInt64).map(String.init)
            let kind: FavoriteItemTargetKind = boardReaderSettings.threadKind(forumID: forumID) == .manga
                ? .mangaThread
                : .normalThread
            target = FavoriteItemTarget(kind: kind, threadID: String(item.targetId))
        case .tagManga, .rssSearch:
            return .unsupported
        }
        let existing = document.items.first { $0.target.threadID == target.threadID }
        return .valid(AnalyzedItem(source: item, target: target, title: title), existingItem: existing)
    }

    private static func importAsNewFolders(
        _ package: FavoriteSharePackage,
        document: inout FavoriteLibraryDocument,
        boardReaderSettings: BoardReaderSettings,
        date: Date
    ) -> ImportMutation {
        var result = FavoriteShareImportResult(
            createdFolderCount: 0,
            createdItemCount: 0,
            reusedItemCount: 0,
            skippedDuplicateCount: 0,
            unsupportedCount: 0,
            invalidCount: 0
        )
        var covers: [ImportedCover] = []

        for folder in package.folders {
            let category = document.createCategory(name: uniqueCategoryName(folder.name, document: document))
            result.createdFolderCount += 1
            let location = FavoriteLocation.category(category.id)
            for sourceItem in folder.items {
                switch analyze(sourceItem, document: document, boardReaderSettings: boardReaderSettings) {
                case .invalid:
                    result.invalidCount += 1
                case .unsupported:
                    result.unsupportedCount += 1
                case let .valid(analyzed, existingItem):
                    if let existingItem {
                        document.addLocation(location, to: existingItem.target, date: date)
                        result.reusedItemCount += 1
                    } else if let item = makeFavoriteItem(analyzed, locations: [location], date: date) {
                        document.upsertItem(item)
                        result.createdItemCount += 1
                        if let cover = importedCover(from: analyzed.source, target: item.target) {
                            covers.append(cover)
                        }
                    } else {
                        result.invalidCount += 1
                    }
                }
            }
        }
        return ImportMutation(result: result, covers: covers)
    }

    private static func importIntoExistingFolders(
        _ package: FavoriteSharePackage,
        categoryIDs: Set<String>,
        document: inout FavoriteLibraryDocument,
        boardReaderSettings: BoardReaderSettings,
        date: Date
    ) throws -> ImportMutation {
        guard !categoryIDs.isEmpty else { throw FavoriteShareError.emptyImportSelection }
        let existingCategoryIDs = Set(document.categories.map(\.id))
        guard categoryIDs.isSubset(of: existingCategoryIDs) else {
            throw FavoriteShareError.missingImportCategories
        }
        let locations = document.categories
            .filter { categoryIDs.contains($0.id) }
            .map { FavoriteLocation.category($0.id) }
        guard !locations.isEmpty else { throw FavoriteShareError.missingImportCategories }

        var result = FavoriteShareImportResult(
            createdFolderCount: 0,
            createdItemCount: 0,
            reusedItemCount: 0,
            skippedDuplicateCount: 0,
            unsupportedCount: 0,
            invalidCount: 0
        )
        var covers: [ImportedCover] = []
        var seenKeys: Set<SharedItemKey> = []
        let items = package.folders.flatMap(\.items).filter { source in
            seenKeys.insert(SharedItemKey(source)).inserted
        }

        for sourceItem in items {
            switch analyze(sourceItem, document: document, boardReaderSettings: boardReaderSettings) {
            case .invalid:
                result.invalidCount += 1
            case .unsupported:
                result.unsupportedCount += 1
            case let .valid(analyzed, existingItem):
                guard existingItem == nil else {
                    result.skippedDuplicateCount += 1
                    continue
                }
                guard let item = makeFavoriteItem(analyzed, locations: locations, date: date) else {
                    result.invalidCount += 1
                    continue
                }
                document.upsertItem(item)
                result.createdItemCount += 1
                if let cover = importedCover(from: analyzed.source, target: item.target) {
                    covers.append(cover)
                }
            }
        }
        return ImportMutation(result: result, covers: covers)
    }

    private static func makeFavoriteItem(
        _ analyzed: AnalyzedItem,
        locations: [FavoriteLocation],
        date: Date
    ) -> FavoriteItem? {
        try? FavoriteItem(
            target: analyzed.target,
            title: analyzed.title,
            forumID: analyzed.source.forumId.flatMap(positiveInt64).map(String.init),
            forumName: analyzed.source.forumName,
            contentUpdatedAt: analyzed.source.lastUpdatedTime.map {
                Date(timeIntervalSince1970: Double($0) / 1_000)
            },
            locations: locations,
            createdAt: date,
            updatedAt: date
        )
    }

    private static func importedCover(
        from item: FavoriteSharePackage.Item,
        target: FavoriteItemTarget
    ) -> ImportedCover? {
        guard let rawURL = item.coverUrl,
              let url = ContentCoverStore.normalizedCoverURL(from: rawURL),
              let key = ContentCoverKey(target: target) else {
            return nil
        }
        return ImportedCover(key: key, url: url)
    }

    private func persistImportedCovers(_ covers: [ImportedCover]) async {
        for cover in covers {
            do {
                _ = try await contentCoverStore.setAutomaticCover(cover.url, for: cover.key)
            } catch {
                YamiboLog.library.warning(
                    "Failed to persist imported favorite cover for \(cover.key.targetID, privacy: .public): \(error.localizedDescription)"
                )
            }
        }
    }

    private static func uniqueCategoryName(
        _ baseName: String,
        document: FavoriteLibraryDocument
    ) -> String {
        let normalized = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = normalized.isEmpty ? L10n.string("favorites.share.imported_folder") : normalized
        func exists(_ name: String) -> Bool {
            document.categories.contains { $0.displayName.compare(name, options: .caseInsensitive) == .orderedSame }
                || document.collections.contains { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
        }
        guard exists(base) else { return base }
        var suffix = 2
        while exists("\(base) (\(suffix))") {
            suffix += 1
        }
        return "\(base) (\(suffix))"
    }

    private static func milliseconds(since1970 date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    private static func positiveInt64(_ rawValue: String) -> Int64? {
        guard let value = Int64(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            return nil
        }
        return value
    }

    private static func positiveInt64(_ value: Int64) -> Int64? {
        value > 0 ? value : nil
    }
}

private extension FavoriteShareService {
    enum WireTargetType: String, Sendable {
        case threadNormal = "ThreadNormal"
        case threadNovel = "ThreadNovel"
        case tagManga = "TagManga"
        case rssSearch = "RssSearch"
    }

    struct AnalyzedItem: Sendable {
        var source: FavoriteSharePackage.Item
        var target: FavoriteItemTarget
        var title: String
    }

    enum ItemAnalysis: Sendable {
        case valid(AnalyzedItem, existingItem: FavoriteItem?)
        case unsupported
        case invalid
    }

    struct ImportedCover: Sendable {
        var key: ContentCoverKey
        var url: URL
    }

    struct ImportMutation: Sendable {
        var result: FavoriteShareImportResult
        var covers: [ImportedCover]
    }

    struct SharedItemKey: Hashable, Sendable {
        var targetType: String
        var targetID: Int64
        var authorID: Int64?

        init(_ item: FavoriteSharePackage.Item) {
            targetType = item.targetType
            targetID = item.targetId
            authorID = item.authorId
        }
    }
}
