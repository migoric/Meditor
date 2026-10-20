import Foundation
import Observation

/// iOS 端的「AI 写文件」确认闸门。
///
/// 为什么需要它：`ShellContext.confirmFileWrite` 的协议默认实现此前返回 `true`，
/// 而 `MobileAgentContext` 从未覆写它——结果 iOS 上 AI 的任何写入
/// （`write_file` / `patch_file` / `write_document` / `patch_document`）
/// 都不弹确认、直接落盘，与 macOS 上「写前必审阅」的核心承诺正好相反。
///
/// 现在协议默认值改为 fail-closed（拒绝），本类负责把「拒绝」换成「问用户」。
/// 与桌面端的分工差异：macOS 有全屏段落级 diff 审阅面（`DiffReviewOverlay`），
/// iOS 屏幕放不下，确认退化为「路径 + 一句话摘要 + 允许/拒绝」。
@MainActor
@Observable
final class WriteConfirmationGate {

    /// 一条挂起中的写入请求。`id` 让视图层能在请求切换时重置动画状态。
    struct Pending: Identifiable, Equatable {
        let id: UUID
        let path: String
        let summary: String
    }

    private(set) var pending: Pending?
    /// 本次 run 的「全部允许」。run 结束由 `ChatModel` 调 `resetRun()` 复位，
    /// 与桌面端 `isFileWriteAllowedForRun` 的 run 级作用域对齐。
    private(set) var allowAllForRun = false

    private var continuation: CheckedContinuation<Bool, Never>?

    /// 挂起等待用户决定。
    ///
    /// 已有挂起时**直接拒绝**新请求，不排队：排队会让「点错一次允许」连带批准
    /// 后面所有写入，而用户只看到一条确认条。
    func request(path: String, summary: String) async -> Bool {
        guard continuation == nil else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.continuation = cont
            self.pending = Pending(id: UUID(), path: path, summary: summary)
        }
    }

    /// 用户点了「允许」/「拒绝」。
    func resolve(_ approved: Bool) {
        finish(approved, allowAll: false)
    }

    /// 用户点了「本次全部允许」：本 run 后续写入直接放行，不再弹条。
    func resolveAllowingRun() {
        finish(true, allowAll: true)
    }

    /// 拒绝并恢复挂起的 continuation。
    ///
    /// Runner 超时 / 用户取消 / 会话切换时**必须**调用，与桌面端
    /// `cancelPendingWriteConfirmation` 语义一致：否则 continuation 永不恢复，
    /// 那条 run 会一直卡在写工具里。
    func cancelPending() {
        finish(false, allowAll: false)
    }

    /// 新 run 开始时复位（run 级作用域）。
    func resetRun() {
        cancelPending()
        allowAllForRun = false
    }

    private func finish(_ approved: Bool, allowAll: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        pending = nil
        if allowAll { allowAllForRun = true }
        cont.resume(returning: approved)
    }
}
