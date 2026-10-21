import SwiftUI
import WebKit

/// HTML 文件预览：WKWebView 加载 HTML 字符串，首帧渲染完成前盖一层纸色遮罩。
///
/// 遮罩存在的原因：进程内首次创建 WKWebView 会拉起独立的 WebContent 进程（实测 2–4s），
/// 这段时间 webView 自身是纯白，闪白屏很刺眼。遮罩用宣纸底 + 轻量指示器，首帧导航结束
/// （`didFinish` / `didFail`）后淡出；失败也淡出，不会永久挡住内容。
struct HTMLPreviewView: View {
    let html: String
    /// HTML 中相对资源（本地图片、同级 CSS）的解析基准：传文档所在目录。
    /// 未落盘的新建文档传 nil —— 此时相对路径不可解析，与改动前行为一致。
    let baseURL: URL?

    @State private var isRendered = false

    var body: some View {
        ZStack {
            HTMLPreviewWebView(html: html, baseURL: baseURL) {
                withAnimation(PaperTheme.Motion.quick) { isRendered = true }
            }
            if !isRendered {
                ZStack {
                    PaperTheme.paper
                    ProgressView()
                        .tint(PaperTheme.inkSecondary)
                }
                .transition(.opacity)
                .accessibilityLabel("正在渲染 HTML")
            }
        }
    }
}

/// WKWebView 封装。updateUIView 会被任意无关状态刷新触发——coordinator 记录已加载的
/// 内容与基准路径，两者都没变就不重载，避免整页重载丢失滚动位置。
private struct HTMLPreviewWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    /// 首帧导航结束（成功或失败）回调，只触发一次。
    let onFirstRender: () -> Void

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        var lastBaseURL: URL?
        var onFirstRender: (() -> Void)?
        private var hasReported = false

        /// 首次导航有结论就收工：后续 load 不再回调，避免已淡出的遮罩重新盖上。
        func reportFirstRender() {
            guard !hasReported else { return }
            hasReported = true
            onFirstRender?()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            reportFirstRender()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportFirstRender()
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            reportFirstRender()
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onFirstRender = onFirstRender
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        applyBottomInset(to: webView)
        load(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 每次都校正：WebKit 在导航结束后会按自己的规则调 `adjustedContentInset`，
        // makeUIView 那一次设的值可能被覆盖掉。
        applyBottomInset(to: webView)
        load(in: webView, coordinator: context.coordinator)
    }

    /// 底部动作栏是 `.overlay`，不参与布局，WKWebView 并不知道自己会被盖住 ⇒
    /// 必须显式给它的滚动视图补底部 inset。漏了这步时滚到底，最后一块内容
    /// 会被两条胶囊压住（实测：80 段 HTML 的红底尾块只剩上半截可见）。
    ///
    /// 用 `contentInset` 而不是缩 frame：阅读场景下不该改变 HTML 的视口大小，
    /// `position: fixed` 的页脚也不该被推上去。
    private func applyBottomInset(to webView: WKWebView) {
        let inset = PaperTheme.Spacing.bottomBarInset
        guard webView.scrollView.contentInset.bottom != inset else { return }
        webView.scrollView.contentInset.bottom = inset
        webView.scrollView.verticalScrollIndicatorInsets.bottom = inset
    }

    private func load(in webView: WKWebView, coordinator: Coordinator) {
        guard coordinator.lastHTML != html || coordinator.lastBaseURL != baseURL else { return }
        coordinator.lastHTML = html
        coordinator.lastBaseURL = baseURL
        webView.loadHTMLString(html, baseURL: baseURL)
    }
}
