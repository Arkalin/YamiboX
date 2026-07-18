import Foundation

/// `waitForCondition` / `waitForMainActorCondition` 超时抛出的错误。
/// 描述里带上可选的业务说明,方便测试失败时定位是哪个条件没等到。
public struct TestWaitTimeoutError: Error, CustomStringConvertible {
    public var timeout: Duration
    public var message: String?

    public init(timeout: Duration, message: String? = nil) {
        self.timeout = timeout
        self.message = message
    }

    public var description: String {
        if let message {
            return "Timed out after \(timeout) waiting for condition: \(message)"
        }
        return "Timed out after \(timeout) waiting for condition"
    }
}

/// 共享的轮询等待原语:反复求值 `condition`,为真立即返回;超过 `timeout` 抛
/// `TestWaitTimeoutError`。用来替代各测试文件手写的 waitFor 轮询副本,以及
/// “固定 `Task.sleep` 之后紧跟断言”的 flaky 写法。
///
/// - Parameters:
///   - timeout: 最长等待时长(默认 5 秒;条件满足时立即返回,不会等满)。
///   - pollInterval: 轮询间隔(默认 10 毫秒)。
///   - message: 可选的超时描述,会拼进 `TestWaitTimeoutError` 的错误信息。
///   - condition: 待轮询的条件;进入函数后先求值一次再开始计时等待。
public func waitForCondition(
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(10),
    message: String? = nil,
    _ condition: @escaping () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        if await condition() {
            return
        }
        if clock.now >= deadline {
            throw TestWaitTimeoutError(timeout: timeout, message: message)
        }
        try await Task.sleep(for: pollInterval)
    }
}

/// `waitForCondition` 的主线程同步条件变体:整个轮询驻留在 MainActor 上执行,
/// 供 `@MainActor` 测试直接传同步条件闭包(例如读取 `@MainActor` 视图模型的
/// 已发布状态),不需要任何跨隔离域的闭包传递。语义与 `waitForCondition` 一致:
/// 条件为真立即返回,超时抛 `TestWaitTimeoutError`。
@MainActor
public func waitForMainActorCondition(
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(10),
    message: String? = nil,
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        if condition() {
            return
        }
        if clock.now >= deadline {
            throw TestWaitTimeoutError(timeout: timeout, message: message)
        }
        try await Task.sleep(for: pollInterval)
    }
}
