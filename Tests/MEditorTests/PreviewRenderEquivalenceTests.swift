import XCTest
import WebKit
@testable import MEditor

/// 分块解析（`renderMarkdownCached`）与整篇解析（`renderMarkdown`）的**出口等价性**。
///
/// 这是块级缓存唯一该守的不变量：分块只是为了省时间，产物必须与整篇解析一致。
/// 旧测试（`PreviewBlockCacheTests`）只数了「解析了几块」，因此错过了两类真回归：
///
/// - 松散列表 `1. 甲\n\n2. 乙` 被切成两个 `<ol start="2">`、`<li><p>` 丢失；
/// - `[bar]:https://x`（冒号后无空格）没被认成引用定义 ⇒ 定义块渲染成空串、
///   正文留 `[bar]`，**链接静默丢失**。
///
/// 比较用的是「折叠空白后逐字相等」：两边的差异允许落在块之间的换行数量上
/// （`</p>\n<h1>` vs `</p>\n\n<h1>` 渲染完全一致），但标签与文本必须一致。
@MainActor
final class PreviewRenderEquivalenceTests: XCTestCase {

    // MARK: - 语料

    /// 每条都是「按空行切就会切错」的形状，且都补足 >2 块以真正走分块路径。
    private static let adversarial: [(String, String)] = [
        ("松散有序列表", "1. 甲\n\n2. 乙\n\n3. 丙\n\n前情一。\n\n前情二。\n\n前情三。"),
        ("松散无序列表", "- 甲\n\n- 乙\n\n- 丙\n\n前情一。\n\n前情二。\n\n前情三。"),
        ("松散列表 + 围栏", "1. 甲\n\n2. 乙\n\n```sh\necho hi\n```\n\n前情一。\n\n前情二。"),
        ("嵌套松散列表", "- 甲\n  - 甲一\n\n  - 甲二\n\n- 乙\n\n正文一。\n\n正文二。"),
        ("列表项第二段", "1. 步骤一\n\n   续段说明。\n\n2. 步骤二\n\n正文一。\n\n正文二。"),
        ("列表后接正文", "- 甲\n\n正文段落。\n\n再一段。\n\n第三段。"),
        ("引用定义无空格", "[bar]:https://example.com\n\n见 [bar] 链接。\n\n另起一段。\n\n再一段。\n\n前情。"),
        ("引用定义有空格", "[bar]: https://example.com\n\n见 [bar] 链接。\n\n另起一段。\n\n再一段。\n\n前情。"),
        ("html 注释跨空行", "<!--\n\n注释里\n\n-->\n\n正文一。\n\n正文二。"),
        ("script 块跨空行", "<script>\n\nvar a = 1;\n\n</script>\n\n正文一。\n\n正文二。"),
        ("div 块内空行", "<div class=\"x\">\n\n<span>内</span>\n\n</div>\n\n正文一。\n\n正文二。"),
        ("setext 标题", "标题甲\n===\n\n正文一。\n\n正文二。\n\n正文三。"),
        ("front matter", "---\ntitle: 你好\ntags: [a, b]\n---\n\n正文一。\n\n正文二。\n\n正文三。"),
        ("星号分隔线", "正文甲。\n\n* * *\n\n正文乙。\n\n正文丙。"),
        ("表格紧跟段落", "段落甲。\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n正文丙。"),
        ("列表项内缩进围栏", "1. 步骤一\n\n   ```sh\n   echo hi\n   ```\n\n正文二。\n\n正文三。"),
        ("引用块含空行", "> 引用一\n>\n> 引用二\n\n正文一。\n\n正文二。"),
        ("围栏内含空行", "正文一。\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n正文二。\n\n正文三。"),
        ("未闭合围栏", "正文一。\n\n```swift\nlet x = 1"),
        ("未闭合围栏超两块", "正文一。\n\n正文二。\n\n```swift\nlet x = 1\n\nlet y = 2"),
        ("行内代码含反引号", "这是 ``a ` b`` 行内代码。\n\n正文一。\n\n正文二。\n\n正文三。"),
        // 反引号围栏的 info 含反引号 ⇒ CommonMark 规定该行不是围栏；
        // 切块器若认它当开栏，会与 marked 的奇偶错开，块边界切进真代码块。
        ("伪围栏info含反引号", "教程一。\n\n教程二。\n\n``` 或者 ```javascript\n说明文字。\n\n```swift\nlet a = 1\n```\n\n正文三。"),
        // 引用定义可以出现在容器里（blockquote / 列表项缩进），文档级生效；
        // 判据只认行首 ≤3 空格时这类定义漏检，走分块后链接静默丢失。
        ("引用定义在引用块里", "> [bar]: /url\n\n见 [bar] 链接。\n\n另起一段。\n\n再一段。"),
        ("引用定义在列表项里", "- item\n\n    [x]: /url\n\n见 [x] 这里。\n\n另起一段。\n\n再一段。"),
        // 预处理（标题/分隔线后补空行）不识别围栏时，会把空行插进代码内容。
        ("围栏内注释紧跟代码", "```python\n# 注释\nx = 1\n```\n\n正文一。\n\n正文二。\n\n正文三。"),
        ("围栏内含更短反引号", "````md\n```js\nx\n```\n````\n\n正文一。\n\n正文二。"),
        ("任务列表", "- [ ] 未完成\n\n- [x] 已完成\n\n正文一。\n\n正文二。"),
        ("深层嵌套列表", "1. 一\n   - 一甲\n\n   - 一乙\n\n2. 二\n\n正文一。"),
        ("标题紧跟正文", "## 标题\n正文紧跟。\n\n正文一。\n\n正文二。"),
    ]

    // MARK: - 用例

    func testAdversarialCorpusHasNoOutputDifference() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        var failures: [String] = []

        for (name, text) in Self.adversarial {
            let same = try await compare(text, in: webView)
            if !same { failures.append(name) }
        }
        XCTAssertEqual(failures, [], "分块解析与整篇解析输出不一致：\(failures)")
    }

    func testRealDocumentsHaveNoOutputDifference() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let docs = try PreviewTestPage.repoMarkdownFiles()
        XCTAssertFalse(docs.isEmpty, "没找到仓库内的 .md 语料")

        var failures: [String] = []
        for url in docs {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let same = try await compare(text, in: webView)
            if !same { failures.append(url.lastPathComponent) }
        }
        XCTAssertEqual(failures, [], "真实文档上分块/整篇输出不一致：\(failures)")
    }

    /// 松散列表必须仍是一个 `<ol>`，且列表项保留 `<p>`（loose list 的产物）。
    func testLooseListStaysSingleList() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let text = "1. 甲\n\n2. 乙\n\n3. 丙\n\n前情一。\n\n前情二。"
        _ = try await PreviewTestPage.render(text, in: webView)

        let olCount = try await PreviewTestPage.eval("document.querySelectorAll('#content ol').length", webView)
        XCTAssertEqual(olCount, "1", "松散列表被切成了多个 <ol>")
        let pCount = try await PreviewTestPage.eval(
            "document.querySelectorAll('#content ol > li > p').length", webView)
        XCTAssertEqual(pCount, "3", "松散列表的 <li><p> 丢了")
    }

    func testLargeLooseListChunksWithoutChangingStructure() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let source = (1...120).map { "\($0). 项目 \($0)" }.joined(separator: "\n\n")
        _ = try await PreviewTestPage.render(source, in: webView)
        try await PreviewTestPage.resetStats(webView)
        _ = try await PreviewTestPage.eval("""
        (function () {
          var originalParse = marked.parse;
          window.__maxBlockParseLength = 0;
          marked.parse = function (source, options) {
            window.__maxBlockParseLength = Math.max(window.__maxBlockParseLength, source.length);
            return originalParse(source, options);
          };
        })()
        """, webView)
        let edited = source.replacingOccurrences(of: "60. 项目 60", with: "60. 已修改")
        let literal = try PreviewTestPage.jsStringLiteral(edited)
        let cachedStructure = try await PreviewTestPage.eval("""
        (function () {
          var d = document.createElement('div');
          d.innerHTML = MEditorRender.renderMarkdownCached(\(literal));
          return d.querySelectorAll('ol').length + '/' + d.querySelectorAll('ol > li').length;
        })()
        """, webView)
        XCTAssertEqual(cachedStructure, "1/120", "拼接后的 HTML 结构已不一致")
        _ = try await PreviewTestPage.render(edited, in: webView)
        let stats = try await PreviewTestPage.stats(webView)

        XCTAssertLessThanOrEqual(stats.blockParse, 2, "大列表编辑不得整段重算：\(stats)")
        let maxParseLength = try await PreviewTestPage.eval("String(window.__maxBlockParseLength)", webView)
        XCTAssertLessThan(Int(maxParseLength ?? "") ?? .max, edited.count, "不得退化为整列表重算")
        let listCount = try await PreviewTestPage.eval("document.querySelectorAll('#content ol').length", webView)
        XCTAssertEqual(listCount, "1", "分块后不得生成多个有序列表")
        let itemCount = try await PreviewTestPage.eval("document.querySelectorAll('#content ol > li').length", webView)
        XCTAssertEqual(itemCount, "120", "分块后列表项数量或编号丢失")
        let modified = try await PreviewTestPage.eval(
            "String(document.getElementById('content').textContent.includes('已修改'))", webView)
        XCTAssertEqual(modified, "true")
    }

    func testLargeMixedListKeepsConservativeGrouping() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let source = (1...120).map { $0.isMultiple(of: 2) ? "\($0). 项目 \($0)" : "- 项目 \($0)" }
            .joined(separator: "\n\n")
        let same = try await compare(source, in: webView)
        XCTAssertTrue(same)
    }

    /// 冒号后无空格的引用定义也要认出来（判据不能要求 `\s`）。
    func testReferenceDefinitionWithoutSpaceKeepsLink() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let text = "[bar]:https://example.com\n\n见 [bar] 链接。\n\n另起一段。\n\n再一段。"
        _ = try await PreviewTestPage.render(text, in: webView)

        let href = try await PreviewTestPage.eval(
            "document.querySelector('#content a[href=\"https://example.com\"]') ? 'ok' : 'missing'", webView)
        XCTAssertEqual(href, "ok", "引用定义被吞掉，链接静默丢失")
        let literal = try await PreviewTestPage.eval(
            "document.getElementById('content').textContent.indexOf('[bar]')", webView)
        XCTAssertEqual(literal, "-1", "正文里留下了未解析的 [bar]")
    }

    /// 容器内的引用定义同样文档级生效（blockquote / 列表项缩进），
    /// 分块判据漏检 ⇒ 定义块被吞、链接静默丢失。
    func testContainerReferenceDefinitionKeepsLink() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        for text in [
            "> [bar]: /url-a\n\n见 [bar] 链接。\n\n另起一段。\n\n再一段。",
            "- item\n\n    [bar]: /url-b\n\n见 [bar] 这里。\n\n另起一段。\n\n再一段。",
        ] {
            _ = try await PreviewTestPage.render(text, in: webView)
            let found = try await PreviewTestPage.eval(
                "document.querySelector('#content a[href^=\"/url-\"]') ? 'ok' : 'missing'", webView)
            XCTAssertEqual(found, "ok", "容器内引用定义漏检，链接丢失：\(text.prefix(20))…")
        }
    }

    /// 结构行补空行必须围栏感知：整篇路径也不准往代码内容里插空行。
    func testFullParseDoesNotPadInsideFence() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let literal = try PreviewTestPage.jsStringLiteral("```python\n# 注释\nx = 1\n```\n")
        let code = try await PreviewTestPage.eval("""
        (function () {
          var html = MEditorRender.renderMarkdown(\(literal));
          var m = html.match(/<code[^>]*>([\\s\\S]*?)<\\/code>/);
          return m ? m[1] : 'NO-CODE';
        })()
        """, webView)
        XCTAssertTrue(
            code?.contains("# 注释\nx = 1") == true,
            "代码内容被预处理改写（围栏内插了空行）：\(code ?? "nil")"
        )
    }

    // MARK: - 夹具

    private func compare(_ markdown: String, in webView: WKWebView) async throws -> Bool {
        let literal = try PreviewTestPage.jsStringLiteral(markdown)
        let raw = try await PreviewTestPage.eval("""
        (function () {
          function norm(s) { return s.replace(/\\s+/g, ' ').trim(); }
          var full = MEditorRender.renderMarkdown(\(literal));
          var cached = MEditorRender.renderMarkdownCached(\(literal));
          return norm(full) === norm(cached) ? 'same' : ('diff\\n--- full ---\\n' + full + '\\n--- cached ---\\n' + cached);
        })()
        """, webView)
        if raw == "same" { return true }
        XCTFail("输出不一致：\(raw?.prefix(1200) ?? "nil")")
        return false
    }
}
