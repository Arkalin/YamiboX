/// Receives queue lifecycle events without coupling download workflows to a
/// system background-task implementation. The app injects its platform adapter.
public protocol DownloadQueueRunObserving: Sendable {
    func submitUserInitiatedRun() async
    func queueRunDidUpdateProgress(completedImageCount: Int, targetImageCount: Int) async
    func queueRunDidFinish(success: Bool) async
    func queueRunDidCancel() async
}
