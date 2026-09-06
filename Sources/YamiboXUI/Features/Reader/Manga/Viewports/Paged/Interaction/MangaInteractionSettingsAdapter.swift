import YamiboXCore

extension MangaNavigationConfiguration {
    init(settings: MangaReaderSettings, chromeVisible: Bool, zoomEnabled: Bool, usesTwoPages: Bool) {
        self.init(direction: settings.pageTurnDirection == .leftToRight ? .leftToRight : .rightToLeft,
            surface: MangaInteractionConfiguration(chromeVisible: chromeVisible,
                zoomEnabled: zoomEnabled, allowsUnzoomedPan: !usesTwoPages))
    }
}

extension NavigationStep {
    var readerTapZone: ReaderPagedTapZone { self == .forward ? .next : .previous }
}
