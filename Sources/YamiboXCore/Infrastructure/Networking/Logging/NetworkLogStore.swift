import Foundation

public actor NetworkLogStore {
    public nonisolated static let capacityBytes: Int64 = 5_000_000
    public static let shared = NetworkLogStore()
    nonisolated let generation = NetworkLogGeneration()

    private struct Record {
        let entry: NetworkLogEntry
        let data: Data
    }

    private struct ClearState: Codable {
        var clearedAt: Date?
        var retainedSince: Date?
    }

    private struct RecordKey: Hashable {
        var startedAt: Date
        var id: UUID
        init(_ record: Record) { startedAt = record.entry.startedAt; id = record.entry.id }
    }

    private struct Segment {
        let url: URL
        var records: [Record]
        var bytes: Int64

        init(url: URL, records: [Record]) {
            self.url = url
            self.records = records
            bytes = records.reduce(0) { $0 + Int64($1.data.count) }
        }

    }

    private let directoryURL: URL
    private let exportDirectoryURL: URL
    private let segmentCapacityBytes: Int64 = 128_000
    private var segments: [Segment] = []
    private var nextSegmentNumber: UInt64 = 1
    private var loaded = false
    private var startupExportCleanupPerformed = false
    private var stateBytes: Int64 = 0
    private var clearedAt: Date?
    private var retainedSince: Date?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let stateReservationBytes: Int64 = 256

    private var logCapacityBytes: Int64 { Self.capacityBytes - stateReservationBytes }
    private var stateURL: URL { directoryURL.appendingPathComponent(".clear-state") }

    public init(directoryURL: URL? = nil, exportDirectoryURL: URL? = nil) {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directoryURL = directoryURL ?? support.appendingPathComponent("NetworkLogs", isDirectory: true)
        self.exportDirectoryURL = exportDirectoryURL
            ?? fileManager.temporaryDirectory.appendingPathComponent("YamiboXNetworkLogExports", isDirectory: true)
    }

    public func entries() throws -> [NetworkLogEntry] {
        try loadIfNeeded()
        return orderedRecords().reversed().map(\.entry)
    }

    public func usageBytes() throws -> Int64 {
        try loadIfNeeded()
        return retainedBytes
    }

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    public func clear() throws {
        let clearedAt = generation.advance()
        defer { publishChange() }
        do {
            try loadIfNeeded()
            self.clearedAt = clearedAt
            retainedSince = nil
            try writeState()
            for segment in segments { try FileManager.default.removeItem(at: segment.url) }
            segments.removeAll()
        } catch {
            loaded = false
            throw error
        }
    }

    public func export() throws -> URL {
        try loadIfNeeded()
        guard !segments.isEmpty else { throw NetworkLogStoreError.empty }
        try FileManager.default.createDirectory(at: exportDirectoryURL, withIntermediateDirectories: true)
        let filename = "network-logs-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).jsonl"
        let url = exportDirectoryURL.appendingPathComponent(filename)
        let data = orderedRecords().reduce(into: Data()) { $0.append($1.data) }
        try data.write(to: url, options: .atomic)
        return url
    }

    public func removeExport(at url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == exportDirectoryURL.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ entry: NetworkLogEntry, generation requestGeneration: UUID) throws {
        do {
            try loadIfNeeded()
            guard generation.accepts(requestGeneration, startedAt: entry.startedAt) else { return }
            try appendEntry(entry)
        } catch {
            loaded = false
            throw error
        }
    }

    private func appendEntry(_ entry: NetworkLogEntry) throws {
        try loadIfNeeded()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var data = try encoder.encode(entry)
        data.append(10)
        guard Int64(data.count) <= logCapacityBytes else { return }
        guard retainedSince.map({ entry.startedAt >= $0 }) ?? true else { return }
        let record = Record(entry: entry, data: data)

        let requiredBytes = logBytes + Int64(data.count) - logCapacityBytes
        if requiredBytes > 0 {
            guard try evictOldestRecords(requiredBytes: requiredBytes, notNewerThan: entry.startedAt) else { return }
        }

        if let last = segments.last, last.bytes + Int64(data.count) <= segmentCapacityBytes {
            let handle = try FileHandle(forWritingTo: last.url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            segments[segments.count - 1].records.append(record)
            segments[segments.count - 1].bytes += Int64(data.count)
        } else {
            let filename = String(format: "%020llu.jsonl", nextSegmentNumber)
            nextSegmentNumber &+= 1
            let url = directoryURL.appendingPathComponent(filename)
            try data.write(to: url)
            segments.append(Segment(url: url, records: [record]))
        }
        publishChange()
    }

    private var logBytes: Int64 { segments.reduce(0) { $0 + $1.bytes } }
    private var retainedBytes: Int64 { logBytes + stateBytes }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var directory = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        if !startupExportCleanupPerformed {
            if fileManager.fileExists(atPath: exportDirectoryURL.path) {
                try? fileManager.removeItem(at: exportDirectoryURL)
            }
            startupExportCleanupPerformed = true
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        stateBytes = 0
        clearedAt = nil
        retainedSince = nil
        if fileManager.fileExists(atPath: stateURL.path) {
            let stateData = try Data(contentsOf: stateURL)
            if stateData.count <= stateReservationBytes / 2,
               let state = try? decoder.decode(ClearState.self, from: stateData) {
                if let date = state.clearedAt { generation.restoreClearDate(date) }
                clearedAt = state.clearedAt
                retainedSince = state.retainedSince
                stateBytes = Int64(stateData.count)
            } else {
                try fileManager.removeItem(at: stateURL)
            }
        }
        let files = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" && UInt64($0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        segments.removeAll()
        let currentGeneration = generation.snapshot()
        for url in files {
            let data = try Data(contentsOf: url)
            var records: [Record] = []
            var start = data.startIndex
            for index in data.indices where data[index] == 10 {
                let line = data[start...index]
                if let entry = try? decoder.decode(NetworkLogEntry.self, from: Data(line.dropLast())),
                   entry.formatVersion == 1,
                   generation.accepts(currentGeneration, startedAt: entry.startedAt),
                   retainedSince.map({ entry.startedAt >= $0 }) ?? true {
                    records.append(Record(entry: entry, data: Data(line)))
                }
                start = data.index(after: index)
            }
            if records.isEmpty {
                try fileManager.removeItem(at: url)
            } else {
                segments.append(Segment(url: url, records: records))
                if records.reduce(0, { $0 + $1.data.count }) != data.count {
                    try rewriteSegment(at: segments.count - 1)
                }
            }
            if let number = UInt64(url.deletingPathExtension().lastPathComponent) {
                nextSegmentNumber = max(nextSegmentNumber, number &+ 1)
            }
        }
        while logBytes > logCapacityBytes {
            guard try evictOldestRecords(requiredBytes: logBytes - logCapacityBytes, notNewerThan: nil) else { break }
        }
        loaded = true
    }

    private func orderedRecords() -> [Record] {
        segments.flatMap(\.records).sorted {
            if $0.entry.startedAt == $1.entry.startedAt { return $0.entry.id.uuidString < $1.entry.id.uuidString }
            return $0.entry.startedAt < $1.entry.startedAt
        }
    }

    private func evictOldestRecords(requiredBytes: Int64, notNewerThan date: Date?) throws -> Bool {
        let targetBytes = max(requiredBytes, segmentCapacityBytes)
        var retiring: [Record] = []
        var retiringBytes: Int64 = 0
        let ordered = orderedRecords()
        for record in ordered {
            if let date, record.entry.startedAt > date { break }
            retiring.append(record)
            retiringBytes += Int64(record.data.count)
            if retiringBytes >= targetBytes { break }
        }
        guard retiringBytes >= requiredBytes, let boundary = retiring.last?.entry.startedAt else { return false }
        let keys = Set(retiring.map(RecordKey.init))
        let earliestRemaining = ordered.first { !keys.contains(RecordKey($0)) }?.entry.startedAt
        let oldestRetained = [date, earliestRemaining].compactMap { $0 }.min() ?? boundary
        retainedSince = max(retainedSince ?? oldestRetained, oldestRetained)
        try writeState()
        for index in segments.indices.reversed() {
            let retained = segments[index].records.filter { !keys.contains(RecordKey($0)) }
            guard retained.count != segments[index].records.count else { continue }
            if retained.isEmpty {
                try FileManager.default.removeItem(at: segments[index].url)
                segments.remove(at: index)
            } else {
                segments[index] = Segment(url: segments[index].url, records: retained)
                try rewriteSegment(at: index)
            }
        }
        return true
    }

    private func writeState() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(ClearState(clearedAt: clearedAt, retainedSince: retainedSince))
        guard data.count <= stateReservationBytes / 2 else { throw NetworkLogStoreError.invalidState }
        try data.write(to: stateURL, options: .atomic)
        stateBytes = Int64(data.count)
    }

    private func rewriteSegment(at index: Int) throws {
        let segment = segments[index]
        let data = segment.records.reduce(into: Data()) { $0.append($1.data) }
        let handle = try FileHandle(forWritingTo: segment.url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func publishChange() {
        for continuation in observers.values { continuation.yield(()) }
    }
}

public enum NetworkLogStoreError: Error, Sendable {
    case empty
    case invalidState
}
