public struct MangaReadingPosition: Hashable, Sendable {
    public var tid: String
    public var localIndex: Int

    public init(tid: String, localIndex: Int) {
        self.tid = tid
        self.localIndex = max(0, localIndex)
    }
}
