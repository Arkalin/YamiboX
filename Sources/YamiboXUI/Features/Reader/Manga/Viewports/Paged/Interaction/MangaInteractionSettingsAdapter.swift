import YamiboXCore

extension MangaNavigationConfiguration {
    init(settings: MangaReaderSettings, chromeVisible: Bool, zoomEnabled: Bool, usesTwoPages: Bool) {
        self.init(direction: settings.pageTurnDirection == .leftToRight ? .leftToRight : .rightToLeft,
            surface: MangaInteractionConfiguration(chromeVisible: chromeVisible,
                doubleTapZoomEnabled: zoomEnabled, allowsUnzoomedPan: !usesTwoPages))
    }
}
