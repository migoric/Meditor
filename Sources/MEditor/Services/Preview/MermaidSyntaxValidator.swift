import Foundation
#if os(macOS)
import WebKit
#endif

/// Mermaid 语法校验端口：AgentWriteSelfCheck 写后自检通过它校验 ```mermaid 代码块。
/// 生产实现是 MermaidWebKitValidator（隐藏 WKWebView 跑真 mermaid.parse）；
/// 测试注入 mock，不起真 webview。
@MainActor
protocol MermaidSyntaxChecking: AnyObject {
    /// 语法合法返回 nil；否则返回 mermaid.parse 抛出的错误消息。
    func validate(code: String) async -> String?
}

#if os(macOS)
/// macOS 端真校验器：懒初始化一个常驻隐藏 WKWebView，加载 mermaid.min.js 后
/// 对每个代码块跑 mermaid.parse（v11 起返回 Promise）。
///
/// 最小集设计（参照 iOS MermaidRenderer，去掉缓存/预热）：
/// - 懒初始化：首个校验请求才建 webview——95%+ 的文档没有图，不付 WebContent 进程成本；
/// - 串行：baton-pass 令牌，多个块共用同一 JS 上下文，并发 evaluate 会互相踩；
/// - 超时（15s）：JS 病态（死循环/灾难性回溯）时销毁引擎，下次调用经 ensureReady 重建；
/// - mermaid.min.js 复用 PreviewAssetMirror 的按需拷贝（与预览同一缓存目录，只拷一次）。
@MainActor
final class MermaidWebKitValidator: NSObject, MermaidSyntaxChecking {

    enum ValidationError: LocalizedError {
        case engineUnavailable
        case timedOut

        var errorDescription: String? {
            switch self {
            case .engineUnavailable: return "Mermaid 校验引擎不可用"
            case .timedOut: return "Mermaid 语法校验超时"
            }
        }
    }

    /// 与预览同一缓存目录：mermaid.min.js 由 PreviewAssetMirror 拷一次，
    /// 预览与校验器共用；校验器自己的 shell html 也写在这里。
    private let cacheDir: URL = {
        let cachesDir = FileManager.default.firstURL(for: .cachesDirectory)
        return cachesDir.appendingPathComponent("com.meditor.preview", isDirectory: true)
    }()

    private var webView: WKWebView?
    private var ready: Result<Void, Error>?
    private var readyWaiters: [CheckedContinuation<Result<Void, Error>, Never>] = []
    /// 连续加载失败次数（didFinish 归零）；达到上限后不再重建，防加载失败死循环。
    private var loadFailures = 0
    private static let maxLoadFailures = 3

    // MARK: - 串行队列（baton-pass 令牌）

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func validate(code: String) async -> String? {
        await acquire()
        defer { release() }

        do {
            let webView = try await ensureReady()
            return try await callValidateJS(webView: webView, code: code)
        } catch {
            // 引擎不可用 / 超时：跳过本次校验，不当作语法错误上报
            //（误报比漏报糟——报告条会把用户引去修一个其实没问题的图）
            return nil
        }
    }

    // MARK: - JS 调用（超时 / 迟到回调防护）

    /// JS 回调与 15s 超时两路竞争；OnceContinuation 保证 continuation 恰好
    /// resume 一次（超时后姗姗来迟的 JS 回调不会双重 resume 崩溃）。
    /// 超时 = JS 已病态：销毁引擎，下次 validate 经 ensureReady 重建，
    /// 防止病态输入反复毒化同一引擎。
    /// 返回值在 JS 回调里就收窄成 Sendable 的 String?（Any? 跨域会触发
    /// Swift 6 的 sending 诊断——iOS 端那份是 Swift 5 模式才放得下）。
    private func callValidateJS(webView: WKWebView, code: String) async throws -> String? {
        let once = OnceContinuation()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            once.set(cont)
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard once.resume(with: .failure(ValidationError.timedOut)) else { return }
                self?.destroyEngine()
            }
            webView.callAsyncJavaScript(
                "return await validateMermaid(code);",
                arguments: ["code": code],
                in: nil, in: .page
            ) { result in
                timeout.cancel()
                let outcome: Result<String?, Error> = result.map { raw in
                    (raw as? [String: Any])?["error"] as? String
                }
                once.resume(with: outcome)
            }
        }
    }

    /// 恰好一次的 continuation 投递盒：JS 回调与超时 Task 可能并发到达，
    /// NSLock 序列化后先到先赢；set 与 resume 时序任意交叉也安全
    ///（先 resume 则暂存结果，set 时立即补投，不会因竞态漏投）。
    private final class OnceContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<String?, Error>?
        private var pending: Result<String?, Error>?
        private var fired = false

        func set(_ cont: CheckedContinuation<String?, Error>) {
            lock.lock()
            if let pending {
                lock.unlock()
                cont.resume(with: pending)
                return
            }
            self.cont = cont
            lock.unlock()
        }

        /// 返回本次是否生效（false = 已有先到者，结果被丢弃）。
        @discardableResult
        func resume(with result: Result<String?, Error>) -> Bool {
            lock.lock()
            guard !fired else {
                lock.unlock()
                return false
            }
            fired = true
            if let cont {
                self.cont = nil
                lock.unlock()
                cont.resume(with: result)
            } else {
                pending = result
                lock.unlock()
            }
            return true
        }
    }

    // MARK: - 引擎生命周期

    /// 首次校验才建引擎：把 mermaid.min.js 拷进缓存目录（已拷过则跳过），
    /// 写 shell html 后 loadFileURL。
    private func ensureEngine() {
        if webView == nil {
            guard loadFailures < Self.maxLoadFailures else { return }
            PreviewAssetMirror.ensureMermaidProvisioned(at: cacheDir)
            let shellURL = cacheDir.appendingPathComponent("mermaid-validate.html")
            try? Self.shell.write(to: shellURL, atomically: true, encoding: .utf8)
            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            wv.navigationDelegate = self
            wv.loadFileURL(shellURL, allowingReadAccessTo: cacheDir)
            webView = wv
        }
    }

    /// 引擎就绪后返回可用的 webView；加载失败在重建上限内会自动重试。
    private func ensureReady() async throws -> WKWebView {
        if let ready {
            try ready.get()
            if let webView { return webView }
            // 防御分支：ready 成功但引擎已被销毁，清掉旧状态走重建
            self.ready = nil
        }
        ensureEngine()
        guard webView != nil else { throw ValidationError.engineUnavailable }
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<Void, Error>, Never>) in
            readyWaiters.append(cont)
        }
        try result.get()
        guard let webView else { throw ValidationError.engineUnavailable }
        return webView
    }

    private func finishReady(_ result: Result<Void, Error>) {
        guard ready == nil else { return }
        ready = result
        let pending = readyWaiters
        readyWaiters.removeAll()
        pending.forEach { $0.resume(returning: result) }
    }

    /// 加载失败：计数并销毁引擎，ready 复位为 nil——
    /// 下次 validate 在重建上限内自动重建，不再永久重抛同一个旧错误。
    private func recordLoadFailure(_ error: Error) {
        loadFailures += 1
        webView = nil
        finishReady(.failure(error))
        ready = nil
    }

    /// 引擎病态（JS 超时 / WebContent 进程终止）：销毁，下次 ensureReady 重建。
    /// 挂起的 ready 等待者必须立即失败——它们的 finishReady 永远不会来了。
    private func destroyEngine() {
        webView = nil
        ready = nil
        let pending = readyWaiters
        readyWaiters.removeAll()
        pending.forEach { $0.resume(returning: .failure(ValidationError.engineUnavailable)) }
    }

    // MARK: - 串行队列原语

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()   // busy 保持 true，令牌直接移交
        } else {
            busy = false
        }
    }

    // MARK: - HTML 壳（与预览共用同一份 mermaid.min.js，校验口径与渲染口径一致）

    private static let shell = """
    <!DOCTYPE html>
    <html><head>
    <meta charset="utf-8">
    <script src="mermaid.min.js"></script>
    <script>
    async function validateMermaid(code) {
      try {
        mermaid.initialize({ startOnLoad: false, securityLevel: 'loose' });
        await mermaid.parse(code);
        return { ok: true };
      } catch (e) {
        return { ok: false, error: String(e && e.message ? e.message : e) };
      }
    }
    </script>
    </head><body></body></html>
    """
}

// MARK: - WKNavigationDelegate

extension MermaidWebKitValidator: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loadFailures = 0
            finishReady(.success(()))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            recordLoadFailure(error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            recordLoadFailure(error)
        }
    }

    /// WebContent 进程终止（OOM/崩溃）：JS completion 永远不会来——
    /// 销毁引擎按需重建；挂起的 validate 由各自的超时收尾（与超时同一道防线），
    /// ready 等待者在 destroyEngine 里立即失败。
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            destroyEngine()
        }
    }
}
#endif
