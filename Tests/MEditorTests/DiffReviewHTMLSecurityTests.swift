import XCTest
@testable import MEditor

// MARK: - DiffReviewHTMLSecurityTests
//
// 审阅面 HTML 的安全属性守卫。
//
// 背景：同一份 markdown 走主预览会过 DOMPurify，并且 `template.html` 带 CSP 兜底；
// 而审阅面（`DiffReviewOverlay` 里的 `DiffWebView`）此前是裸的
// `mc.innerHTML = marked.parse(...)`、页面无 CSP、WebView 无 navigationDelegate
// —— 用户「看 AI 产物」的那一栏反而是全链路里最不安全的一段。
//
// 这几个用例把四条属性钉死（不是纸面断言，改坏任何一条都会红）：
//   1. 页面必须带 CSP，且 script-src 只认一次性 nonce（不含 'unsafe-inline'）
//   2. marked 的产物必须过 DOMPurify.sanitize
//   3. HTML 模式的「原样内容」同样要带 CSP，但**不给** nonce
//   4. nonce 每次生成，不能复用

@MainActor
final class DiffReviewHTMLSecurityTests: XCTestCase {

    private func makeView(
        isRight: Bool = true,
        isHTMLMode: Bool = false,
        rawHTML: String = ""
    ) -> DiffWebView {
        DiffWebView(
            paragraphs: [
                .init(text: "# 标题\n\n<b>粗体</b><img src=x onerror=alert(1)>", diffId: "d1", status: "pending"),
                .init(text: "第二段", diffId: "d2", status: "accepted"),
            ],
            isRight: isRight,
            isHTMLMode: isHTMLMode,
            rawHTML: rawHTML
        )
    }

    // MARK: - CSP

    func testMarkdownHTML_hasCSP() {
        let html = makeView().buildHTML()
        XCTAssertTrue(html.contains("Content-Security-Policy"), "审阅面必须有 CSP（主预览有，这里不能漏）")
        XCTAssertTrue(html.contains("connect-src 'none'"), "必须禁 fetch/XHR/beacon，堵住外带通道")
        XCTAssertTrue(html.contains("object-src 'none'"), "禁插件对象")
        XCTAssertTrue(html.contains("default-src 'none'"), "默认拒绝，再逐项放行")
    }

    func testMarkdownHTML_scriptSrcUsesNonceNotUnsafeInline() {
        let html = makeView().buildHTML()
        XCTAssertTrue(html.contains("script-src 'nonce-"), "内联脚本应走一次性 nonce")
        XCTAssertFalse(
            html.contains("script-src 'unsafe-inline'") || html.contains("script-src 'self' 'unsafe-inline'"),
            "script-src 一旦允许 unsafe-inline，文档里注入的 on* 处理器就会执行"
        )
    }

    func testMarkdownHTML_scriptTagsShareTheDeclaredNonce() {
        let html = makeView().buildHTML()
        let onTags   = matches(in: html, pattern: #"nonce="([0-9A-Fa-f]+)""#)
        let declared = matches(in: html, pattern: #"script-src 'nonce-([0-9A-Fa-f]+)'"#)

        XCTAssertFalse(onTags.isEmpty, "内联脚本必须带 nonce，否则 CSP 下脚本根本不执行")
        XCTAssertEqual(Set(onTags).count, 1, "同一页所有脚本必须共用一个 nonce")
        XCTAssertEqual(Set(declared), Set(onTags), "CSP 声明的 nonce 必须等于脚本上挂的那个")
    }

    func testNonceIsFreshPerBuild() {
        let a = matches(in: makeView().buildHTML(), pattern: #"script-src 'nonce-([0-9A-Fa-f]+)'"#)
        let b = matches(in: makeView().buildHTML(), pattern: #"script-src 'nonce-([0-9A-Fa-f]+)'"#)
        XCTAssertNotEqual(a, b, "nonce 复用等于没有 nonce")
    }

    // MARK: - 消毒

    func testMarkdownHTML_sanitizesMarkedOutput() {
        let html = makeView().buildHTML()
        XCTAssertTrue(html.contains("DOMPurify.sanitize"), "marked 产物必须过 DOMPurify，与主预览同一条规矩")
        XCTAssertTrue(
            html.contains("marked.parse(p.text)"),
            "仍应走 marked；断言这一点是为了防止「干脆不渲染」式的虚假修复"
        )
    }

    // MARK: - HTML 模式（原样内容）

    func testHTMLMode_injectsCSPIntoExistingHead() {
        let raw = "<!DOCTYPE html><html><head><title>t</title></head>"
            + "<body><script>alert(1)</script></body></html>"
        let html = makeView(isHTMLMode: true, rawHTML: raw).buildHTML()

        XCTAssertTrue(html.contains("Content-Security-Policy"), "HTML 模式同样要带 CSP")
        XCTAssertTrue(html.contains("<script>alert(1)</script>"), "原样内容不应被重写——审阅要看真实产物")
        XCTAssertFalse(html.contains("nonce="), "原样内容里的 script 不能被授予 nonce，否则等于放行")
        // CSP 必须排在那个 script 之前才生效
        let cspIndex = html.range(of: "Content-Security-Policy")?.lowerBound
        let scriptIndex = html.range(of: "<script>alert(1)</script>")?.lowerBound
        XCTAssertNotNil(cspIndex)
        XCTAssertNotNil(scriptIndex)
        if let c = cspIndex, let s = scriptIndex {
            XCTAssertTrue(c < s, "CSP meta 必须出现在内容之前")
        }
    }

    func testHTMLMode_withoutHeadGetsWrapped() {
        let html = makeView(isHTMLMode: true, rawHTML: "<p>hi</p>").buildHTML()
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"), "没有 head 时应补一个完整文档壳")
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("<p>hi</p>"))
    }

    func testHTMLMode_headerTagIsNotMistakenForHead() {
        // 反向验证（AGENTS.md §6）：`<head` 前缀匹配会把 `<header>` 误当 head，
        // CSP meta 被插进 body——而 body 里的 CSP meta 会被浏览器整体忽略，
        // 文档内 <script> 恢复可执行。改回前缀匹配本条立即变红。
        let raw = "<!DOCTYPE html><html><body><header>页眉</header>"
            + "<script>alert(1)</script></body></html>"
        let html = makeView(isHTMLMode: true, rawHTML: raw).buildHTML()

        let cspIndex = html.range(of: "Content-Security-Policy")?.lowerBound
        let headerIndex = html.range(of: "<header>")?.lowerBound
        XCTAssertNotNil(cspIndex, "无真正 <head> 时应走补壳分支，CSP 不能丢")
        XCTAssertNotNil(headerIndex)
        if let c = cspIndex, let h = headerIndex {
            XCTAssertTrue(c < h, "CSP meta 必须在 <header>（body 内容）之前，插进 body 等于没有")
        }
        XCTAssertTrue(html.contains("<script>alert(1)</script>"), "原样内容不应被重写")
    }

    // MARK: - Helper

    private func matches(in text: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : nil
        }
    }
}
