import XCTest
import WebKit
@testable import MEditor

/// WebKit 的 delegate 方法**先要被 @objc 导出成 selector，才会被调用**。
///
/// ## 这个测试守的是什么
///
/// `func webView(_:decidePolicyFor:decisionHandler:)` 的闭包参数只要少了
/// `@MainActor @Sendable`，Swift 就判定为
/// `nearly matches optional requirement`——**只是一条警告**：
/// 编译通过、纯函数测试全绿，但这个方法**不算协议实现**，不会导出成
/// `webView:decidePolicyForNavigationAction:decisionHandler:`。
/// WebKit 问 `respondsToSelector` 得到 false，直接按默认策略 `.allow` 放行，
/// 于是点链接不会交给系统浏览器，而是在预览里原地导航——目标若是内网地址，
/// 表现就是「点了毫无反应，浏览器没动」。
///
/// 0.13.8 及之前一直如此（`PreviewLinkNavigator` 的纯值测试全绿，掩盖了这一点）。
/// 纯函数测试无法发现它，只能靠运行时 selector 检查。
@MainActor
final class PreviewLinkDelegateWiringTests: XCTestCase {

    private let decidePolicySelector = NSSelectorFromString(
        "webView:decidePolicyForNavigationAction:decisionHandler:"
    )
    private let createWebViewSelector = NSSelectorFromString(
        "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:"
    )

    func test_markdownPreviewExportsDecidePolicy() {
        XCTAssertTrue(
            MarkdownWebView.Coordinator.instancesRespond(to: decidePolicySelector),
            "Markdown 预览的 Coordinator 没有导出 decidePolicyFor：签名与 WebKit 的 "
            + "requirement 不一致（闭包要 @escaping @MainActor @Sendable），"
            + "点链接会被 WebKit 按默认策略放行、在预览内导航"
        )
    }

    func test_htmlPreviewExportsDecidePolicy() {
        XCTAssertTrue(
            WebPreviewView.Coordinator.instancesRespond(to: decidePolicySelector),
            "HTML 预览的 Coordinator 没有导出 decidePolicyFor"
        )
    }

    /// `target="_blank"` 走的是 UIDelegate 的另一个方法，同样会因为签名不符而失效。
    func test_htmlPreviewExportsCreateWebView() {
        XCTAssertTrue(
            WebPreviewView.Coordinator.instancesRespond(to: createWebViewSelector),
            "HTML 预览的 Coordinator 没有导出 createWebViewWith：target=_blank 的链接会打不开"
        )
    }

    func test_markdownPreviewExportsCreateWebView() {
        XCTAssertTrue(
            MarkdownWebView.Coordinator.instancesRespond(to: createWebViewSelector),
            "Markdown 预览的 Coordinator 没有导出 createWebViewWith"
        )
    }
}
