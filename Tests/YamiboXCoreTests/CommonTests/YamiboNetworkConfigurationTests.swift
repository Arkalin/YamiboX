import Foundation
import Testing
@testable import YamiboXCore

@Test func yamiboNetworkConfigurationUsesFifteenSecondTimeouts() {
    #expect(YamiboNetworkConfiguration.requestTimeout == 15)
    #expect(YamiboNetworkConfiguration.resourceTimeout == 15)

    let configuration = YamiboNetworkConfiguration.makeSessionConfiguration()
    #expect(configuration.timeoutIntervalForRequest == 15)
    #expect(configuration.timeoutIntervalForResource == 15)
}

@Test func yamiboNetworkConfigurationCreatesTimedRequests() throws {
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php"))
    let request = YamiboNetworkConfiguration.makeRequest(
        url: url,
        cachePolicy: .reloadIgnoringLocalCacheData
    )

    #expect(request.url == url)
    #expect(request.timeoutInterval == 15)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
}

@Test func defaultAppContextSessionUsesNetworkTimeouts() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("app-context-network-config-\(UUID().uuidString)", isDirectory: true)
    let appContext = YamiboAppContext(grdbRootDirectory: root, cachesRootDirectory: root)
    let configuration = appContext.session.configuration

    #expect(configuration.timeoutIntervalForRequest == 15)
    #expect(configuration.timeoutIntervalForResource == 15)
}

@Test func defaultAuxiliaryNetworkClientsUseNetworkTimeouts() {
    let updateChecker = AppUpdateChecker()
    let webDAVClient = WebDAVClient()

    #expect(updateChecker.session?.configuration.timeoutIntervalForRequest == 15)
    #expect(updateChecker.session?.configuration.timeoutIntervalForResource == 15)
    #expect(webDAVClient.session.configuration.timeoutIntervalForRequest == 15)
    #expect(webDAVClient.session.configuration.timeoutIntervalForResource == 15)
}
