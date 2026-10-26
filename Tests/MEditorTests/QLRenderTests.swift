import XCTest
import JavaScriptCore
@testable import MEditor

/// Quick Look 的 Markdown 渲染（ql-render.js）smoke 测试：
/// 直接用 JavaScriptCore 加载仓内真实资源（marked / pele / ql-render），
/// 不走 WebView、不需要 QL 测试 target。
///
/// 覆盖三条：① pele 出图；② pele 缺失时降级为代码块；③ 顶层 ~~~mermaid
/// 与其他围栏内部的字面 `~~~mermaid` 的区分（改名不得污染代码内容）。
final class QLRenderTests: XCTestCase {

    enum ResourceError: Error { case missing(String) }

    private func makeContext(withPele: Bool) throws -> JSContext {
        guard let context = JSContext() else { throw XCTSkip("无法创建 JSContext") }
        context.evaluateScript("var window = this; var self = this;")
        var scripts = ["Sources/MEditor/Resources/Preview/marked.min.js"]
        if withPele { scripts.append("Sources/MEditorQuickLook/Resources/pele.global.js") }
        scripts.append("Sources/MEditorQuickLook/Resources/ql-render.js")
        for path in scripts {
            context.evaluateScript(try loadResource(path))
            if let message = context.exception?.toString() {
                XCTFail("脚本加载失败 \(path): \(message)")
            }
        }
        return context
    }

    private func render(_ markdown: String, withPele: Bool = false) throws -> String {
        let context = try makeContext(withPele: withPele)
        let literal = try jsLiteral(markdown)
        guard let result = context.evaluateScript("MEditorQL.render(\(literal))")?.toString() else {
            XCTFail("MEditorQL.render 返回空")
            return ""
        }
        return result
    }

    private func loadResource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MEditorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let url = root.appendingPathComponent(relative)
        // 这里是 XCTFail 不是 XCTSkip：这些资源就在仓里，缺了就是真失败。
        // 用 skip 的话，资源被误删/改名时整条用例会静默变绿。
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("资源缺失：\(url.path)")
            throw ResourceError.missing(relative)
        }
        return text
    }

    private func jsLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode([value])
        guard let array = String(data: data, encoding: .utf8) else { throw XCTSkip("编码失败") }
        return String(array.dropFirst().dropLast())
    }

    /// 教程场景：其他围栏内部的 `~~~mermaid` 是代码内容，不得被改名污染。
    func testTildeMermaidInsideOtherFenceIsNotRewritten() throws {
        let doc = "教程：\n\n```text\n~~~mermaid\ngraph TD\n~~~\n```\n\n普通段落。"
        let html = try render(doc)
        XCTAssertTrue(html.contains("~~~mermaid\n"), "字面内容必须原样保留：\(html)")
        XCTAssertFalse(html.contains("__ql_tilde_mermaid__"), "哨兵串不得出现在代码内容里")
        XCTAssertFalse(html.contains("-suppressed"), "旧改名方案的痕迹不得出现")
    }

    /// 顶层 ~~~mermaid 降级为代码块（与主 app 同口径），语言类名还原、源码不动。
    func testTopLevelTildeMermaidDegradesToCodeBlock() throws {
        let html = try render("~~~mermaid\ngraph TD\n~~~\n")
        XCTAssertFalse(html.contains("mermaid-container"), "波浪号围栏不出图")
        XCTAssertTrue(html.contains("language-mermaid"), "语言类名应还原为 mermaid：\(html)")
        XCTAssertTrue(html.contains("graph TD"))
        XCTAssertFalse(html.contains("__ql_tilde_mermaid__"))
    }

    /// pele 缺失时反引号 mermaid 也降级为代码块，不留空白。
    func testBacktickMermaidWithoutPeleFallsBackToCodeBlock() throws {
        let html = try render("```mermaid\ngraph TD\n```\n")
        XCTAssertFalse(html.contains("mermaid-container"))
        XCTAssertTrue(html.contains("graph TD"), "pele 缺失时至少要看到源码")
    }

    /// pele 在场时反引号 mermaid 出 SVG；同页多图 idPrefix 不互相覆盖。
    func testBacktickMermaidWithPeleRendersSVG() throws {
        // 桑基图的 linearGradient 只有给了 idPrefix 才生成，前缀断言用桑基；
        // flowchart 不含渐变 id，断不到前缀上。
        let sankey = "```mermaid\nsankey-beta\nA,B,5\nA,C,3\nB,D,4\n```"
        let flowchart = "```mermaid\ngraph TD\nA --> B\n```"
        let html = try render(sankey + "\n\n中间段。\n\n" + sankey + "\n\n" + flowchart + "\n", withPele: true)
        XCTAssertTrue(html.contains("mermaid-container"), "pele 在场应出图：\(html.prefix(200))")
        XCTAssertTrue(html.contains("ql-mmd-1") && html.contains("ql-mmd-2"),
                      "每张图必须有独立 idPrefix（渐变/marker/aria 都吃 id）")
        XCTAssertFalse(html.contains("error-block"), "正常图表不应落到错误块")
    }
}
