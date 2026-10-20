import UIKit
import WebKit

/// 共享 Mermaid 渲染引擎：单个离线 WKWebView 常驻，mermaid.min.js（约 3MB）只加载解析一次。
/// 渲染请求串行排队（mermaid.render 非线程安全，且共用同一个 JS 上下文），
/// 结果（PNG 位图 + SVG 矢量，同一次渲染产出）按「外观 + 缩放 + 代码串」做内存缓存——滚动复用、重开文档均即时出图。
///
/// 健壮性设计：
/// - 每次 JS 调用带 30s 超时 + 取消竞争，continuation 由 OnceContinuation 保证恰好 resume 一次；
/// - 超时 / WebContent 进程终止判定引擎病态，销毁后下次 render/preload 自动重建；
/// - 加载失败不粘性：上限 3 次内自动重建，超出后保持 engineUnavailable 防抖动。
@MainActor
final class MermaidRenderer: NSObject {
    static let shared = MermaidRenderer()

    struct Rendered {
        let image: UIImage
        /// 自包含 SVG（主题色已注入，width/height 已写成逻辑尺寸），供矢量消费点（分享等）。
        /// 与 PNG 同一次 mermaid.render 产出、同一条缓存——iOS 没有原生 SVG 栅格器，
        /// 块内展示仍只能用位图，但矢量串本身顺带返回是零成本的。
        let svg: String
        /// SVG viewBox 的逻辑尺寸（pt），供布局参考。
        let size: CGSize
    }

    enum RenderError: LocalizedError {
        case engineUnavailable
        case jsFailed(String)
        case badImage
        case timedOut

        var errorDescription: String? {
            switch self {
            case .engineUnavailable: return "图表引擎加载失败"
            case .jsFailed(let message): return message
            case .badImage: return "图表解码失败"
            case .timedOut: return "图表渲染超时"
            }
        }
    }

    // MARK: - 缓存

    private final class RenderedBox {
        let value: Rendered
        init(_ value: Rendered) { self.value = value }
    }

    private let cache = NSCache<NSString, RenderedBox>()

    // MARK: - 引擎状态

    private var webView: WKWebView?
    private var ready: Result<Void, Error>?
    private var readyWaiters: [CheckedContinuation<Result<Void, Error>, Never>] = []
    /// 连续加载失败次数（didFinish 归零）；达到上限后不再重建，防加载失败死循环。
    private var loadFailures = 0
    private static let maxLoadFailures = 3

    // MARK: - 串行队列（baton-pass 信号量）

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private override init() {
        super.init()
        cache.countLimit = 60
        // 60 张 3x PNG 峰值可观，按 PNG 字节数再压一道总量上限。
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    /// 预热 WebContent 进程：仅创建 WKWebView，不加载任何 JS。
    /// 首帧后调用，把进程创建开销（~150ms）移到启动之后，用户无感知。
    func prewarm() {
        guard webView == nil else { return }
        guard loadFailures < Self.maxLoadFailures else { return }
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        webView?.isOpaque = false
        // 不设置 navigationDelegate，不加载 HTML——引擎空闲但进程已驻留
    }

    /// 缓存 key：外观 | 缩放 | 代码——切换浅色 / 墨夜后不能命中旧图。
    private static func cacheKey(code: String, scale: CGFloat, dark: Bool) -> NSString {
        "\(dark ? "dark" : "light")|\(scale)|\(code)" as NSString
    }

    /// 预渲染一批图表：引擎预热后按文档顺序在后台填满缓存。
    /// 视图出现前的预热调用；块真正展示时 render() 命中缓存即时返回，
    /// 屏外的图表也不再等滚动到才开始渲染。失败忽略（视图会自行展示错误）。
    func preload(codes: [String], scale: CGFloat, dark: Bool) {
        let pending = codes.filter { cache.object(forKey: Self.cacheKey(code: $0, scale: scale, dark: dark)) == nil }
        guard !pending.isEmpty else { return }
        prewarm()
        Task {
            for code in pending {
                _ = try? await render(code: code, scale: scale, dark: dark)
            }
        }
    }

    func render(code: String, scale: CGFloat, dark: Bool) async throws -> Rendered {
        let key = Self.cacheKey(code: code, scale: scale, dark: dark)
        if let hit = cache.object(forKey: key) { return hit.value }

        await acquire()
        defer { release() }

        // 排队期间可能有相同代码先渲染完，再查一次。
        if let hit = cache.object(forKey: key) { return hit.value }

        // 排队期间任务可能已被取消：拿到令牌后先检查，不白跑。
        try Task.checkCancellation()

        let webView = try await ensureReady()

        // 等引擎加载期间也可能被取消，发 JS 前再查一次。
        try Task.checkCancellation()

        let raw = try await callRenderJS(webView: webView, code: code, scale: scale, dark: dark)

        guard let dict = raw as? [String: Any] else { throw RenderError.badImage }
        if let error = dict["error"] as? String { throw RenderError.jsFailed(error) }
        guard let dataURL = dict["png"] as? String,
              let svg = dict["svg"] as? String, !svg.isEmpty,
              let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let image = UIImage(data: data, scale: scale),
              let width = (dict["width"] as? NSNumber)?.doubleValue,
              let height = (dict["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { throw RenderError.badImage }

        let rendered = Rendered(image: image, svg: svg, size: CGSize(width: width, height: height))
        cache.setObject(RenderedBox(rendered), forKey: key, cost: data.count + svg.utf8.count)
        return rendered
    }

    // MARK: - JS 调用（超时 / 取消竞争）

    /// JS 调用：正常回调、30s 超时、任务取消三路竞争。
    /// OnceContinuation 保证底层 continuation 恰好 resume 一次（先到先赢，后到丢弃）——
    /// 超时触发后姗姗来迟的 JS 回调不会双重 resume 崩溃。
    /// 主题按调用时的外观注入（引擎常驻，浅 / 墨夜共用，不重建）。
    private func callRenderJS(webView: WKWebView, code: String, scale: CGFloat, dark: Bool) async throws -> Any? {
        let once = OnceContinuation()
        let hex = PaperTheme.Hex.values(dark: dark)
        let themeVariables: [String: String] = [
            "background": hex.card,
            "primaryColor": hex.paper,
            "primaryTextColor": hex.ink,
            "primaryBorderColor": hex.accent,
            "lineColor": hex.inkSecondary,
            "secondaryColor": hex.codeBackground,
            "tertiaryColor": hex.codeBackground,
            "fontFamily": "-apple-system, sans-serif",
        ]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
                once.set(cont)
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    // 竞争失败说明 JS 回调/取消已处理，无需动引擎。
                    guard once.resume(with: .failure(RenderError.timedOut)) else { return }
                    // 超时 = JS 已病态（死循环/灾难性回溯），completion 大概率永远不会来。
                    // 销毁引擎，下次 render/preload 经 ensureReady 重建，
                    // 防止病态输入反复毒化同一引擎。
                    self?.destroyEngine()
                }
                webView.callAsyncJavaScript(
                    "return await renderMermaid(code, scale, themeVariables, canvasFill);",
                    arguments: [
                        "code": code,
                        "scale": scale,
                        "themeVariables": themeVariables,
                        "canvasFill": hex.card,
                    ],
                    in: nil, in: .page
                ) { result in
                    timeout.cancel()
                    once.resume(with: result.map { $0 as Any? })
                }
            }
        } onCancel: {
            // 调用方走了（视图消失等）：立即放行队列令牌，不阻塞后续渲染。
            // 引擎不背锅——JS 调用大概率健康，其回调晚些到达会被 OnceContinuation 丢弃，
            // 引擎留给下次复用；若 JS 真的病态，下次调用的 30s 超时会走销毁重建路径。
            once.resume(with: .failure(CancellationError()))
        }
    }

    /// 恰好一次的 continuation 投递盒：JS 回调、超时 Task、取消处理器可能并发到达，
    /// NSLock 序列化后先到先赢；set 与 resume 时序任意交叉也安全
    ///（先 resume 则暂存结果，set 时立即补投，不会因竞态漏投）。
    private final class OnceContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Any?, Error>?
        private var pending: Result<Any?, Error>?
        private var fired = false

        func set(_ cont: CheckedContinuation<Any?, Error>) {
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
        func resume(with result: Result<Any?, Error>) -> Bool {
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

    /// 确保 WKWebView 存在（如果 prewarm 没创建过，现在创建）。
    /// 首次加载 JS 引擎：设置 delegate 并加载含 mermaid.min.js 的 HTML。
    /// 如果 webView 已存在但未初始化引擎（prewarm 创建的），现在补上。
    private func ensureEngine() {
        if webView == nil {
            guard loadFailures < Self.maxLoadFailures else { return }
            webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024))
            webView?.isOpaque = false
        }
        guard let wv = webView, wv.navigationDelegate == nil else { return }
        wv.navigationDelegate = self
        wv.loadHTMLString(Self.shell, baseURL: Bundle.main.resourceURL)
    }

    /// 引擎就绪后返回可用的 webView；加载失败在重建上限内会自动重试。
    private func ensureReady() async throws -> WKWebView {
        if let ready {
            try ready.get()
            if let webView { return webView }
            // 防御分支：ready 成功但引擎已被销毁，清掉旧状态走重建。
            self.ready = nil
        }
        ensureEngine()
        guard webView != nil else { throw RenderError.engineUnavailable }
        // 如果 webView 已存在但 shell 尚未加载（prewarm 创建的），ensureEngine 已触发加载
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<Void, Error>, Never>) in
            readyWaiters.append(cont)
        }
        try result.get()
        guard let webView else { throw RenderError.engineUnavailable }
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
    /// 下次 render/preload 在重建上限内自动重建，不再永久重抛同一个旧错误。
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
        pending.forEach { $0.resume(returning: .failure(RenderError.engineUnavailable)) }
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

    // MARK: - HTML 壳（与桌面端共用同一份 mermaid.min.js，渲染结果两端一致）

    private static let shell = """
    <!DOCTYPE html>
    <html><head>
    <meta charset="utf-8">
    <script src="mermaid.min.js"></script>
    <script>
    var renderSeq = 0;
    async function renderMermaid(code, scale, themeVariables, canvasFill) {
      try {
        // 主题随每次渲染注入：引擎常驻，浅色 / 墨夜共用同一 JS 上下文。
        mermaid.initialize({
          startOnLoad: false,
          securityLevel: 'loose',
          theme: 'base',
          themeVariables: themeVariables
        });
        const { svg } = await mermaid.render('mmd-' + (renderSeq++), code);
        const host = document.getElementById('host');
        host.innerHTML = svg;
        const el = host.querySelector('svg');
        let w = 0, h = 0;
        const vb = el.getAttribute('viewBox');
        if (vb) {
          const p = vb.split(/[ ,]+/).map(Number);
          if (p.length === 4 && p[2] > 0 && p[3] > 0) { w = p[2]; h = p[3]; }
        }
        if (!w || !h) {
          w = parseFloat(el.getAttribute('width')) || 0;
          h = parseFloat(el.getAttribute('height')) || 0;
        }
        if (!w || !h) {
          const r = el.getBoundingClientRect();
          w = r.width; h = r.height;
        }
        if (!w || !h) return { error: '无法测量图表尺寸' };
        el.setAttribute('width', String(w));
        el.setAttribute('height', String(h));
        const xml = new XMLSerializer().serializeToString(el);
        const img = new Image();
        await new Promise(function (resolve, reject) {
          img.onload = resolve;
          img.onerror = function () { reject(new Error('SVG 栅格化失败')); };
          img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(xml);
        });
        const canvas = document.createElement('canvas');
        canvas.width = Math.round(w * scale);
        canvas.height = Math.round(h * scale);
        const ctx = canvas.getContext('2d');
        ctx.fillStyle = canvasFill;
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
        return { png: canvas.toDataURL('image/png'), svg: xml, width: w, height: h };
      } catch (e) {
        return { error: String(e && e.message ? e.message : e) };
      }
    }
    </script>
    </head><body style="margin:0"><div id="host"></div></body></html>
    """
}

// MARK: - WKNavigationDelegate

extension MermaidRenderer: WKNavigationDelegate {
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
    /// 销毁引擎按需重建；挂起的 render 由各自的 30s 超时收尾（与超时同一道防线），
    /// ready 等待者在 destroyEngine 里立即失败。
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            destroyEngine()
        }
    }
}
