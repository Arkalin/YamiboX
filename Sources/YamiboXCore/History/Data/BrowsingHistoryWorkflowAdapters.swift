extension BrowsingHistoryStore: BrowsingHistoryReconciling {}

extension SettingsStore: BrowsingHistorySettingsReading {
    public func loadBoardReaderSettings() async -> BoardReaderSettings {
        await load().boardReader
    }
}

extension ReadingProgressStore: BrowsingHistoryProgressReading {}
