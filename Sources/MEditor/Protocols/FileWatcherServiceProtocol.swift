import Foundation

protocol FileWatcherServiceProtocol {
    /// onChange 以 @Sendable 标注：FSEvents 回调在后台队列触发，需把变化路径送到主队列执行。
    func startWatching(urls: [URL], onChange: @escaping @Sendable ([URL]) -> Void)
    func stopWatching()
}
