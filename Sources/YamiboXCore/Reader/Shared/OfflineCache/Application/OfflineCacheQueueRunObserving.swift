/// Receives queue lifecycle events without coupling cache workflows to a
/// system background-task implementation. The app injects its platform adapter.
public protocol OfflineCacheQueueRunObserving: Sendable {
    func submitUserInitiatedRun() async
    func queueRunDidUpdateProgress(completedImageCount: Int, targetImageCount: Int) async
    func queueRunDidFinish(success: Bool) async
    func queueRunDidCancel() async
}
