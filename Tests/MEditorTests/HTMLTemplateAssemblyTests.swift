import XCTest
@testable import MEditor

/// 模板引用式写入：`模板 + 语义 body → 完整文档`。
///
/// 判据来自设计稿 §7.3/§7.5：模板的 `<style>` 一个字都不该出现第二次，
/// 侧边栏导航不能留着模板里的占位条目。
final class HTMLTemplateAssemblyTests: XCTestCase {

    private let template = """
    <!DOCTYPE html>
    <html lang="zh">
    <head>
    <title>占位标题</title>
    <style>
    body { color: #333; }
    .sidebar { width: 220px; }
    </style>
    </head>
    <body>
    <aside class="sidebar">
      <div class="sidebar-brand">文档标题</div>
      <nav>
        <a href="#s1" class="active">概述</a>
        <a href="#s2">章节二</a>
      </nav>
    </aside>
    <main class="main">
      <section id="s1"><h1>旧内容</h1></section>
    </main>
    </body>
    </html>
    """

    private let body = """
    <section id="intro"><h2>引言</h2><p>正文</p></section>
    <section id="data"><h2>数据</h2><table><tr><td>1</td></tr></table></section>
    """

    func test_assemble_fillsMainAndKeepsTemplateStyle() throws {
        let html = try HTMLTemplateAssembly.assemble(template: template, title: "三季度复盘", body: body)
        XCTAssertTrue(html.contains("<section id=\"intro\">"), "body 要落进 <main>")
        XCTAssertFalse(html.contains("旧内容"), "模板里的示例内容必须被替换掉")
        XCTAssertTrue(html.contains("body { color: #333; }"), "模板样式原样保留")
        XCTAssertTrue(html.contains("<title>三季度复盘</title>"))
        XCTAssertFalse(html.contains("占位标题"))
    }

    func test_assemble_regeneratesSidebarNavigation() throws {
        let html = try HTMLTemplateAssembly.assemble(template: template, title: nil, body: body)
        XCTAssertTrue(html.contains("<a href=\"#intro\" class=\"active\">引言</a>"), html)
        XCTAssertTrue(html.contains("<a href=\"#data\">数据</a>"), html)
        XCTAssertFalse(html.contains("章节二"), "模板里的占位导航不能留：那是比没导航更糟的观感")
    }

    func test_assemble_injectsIDsWhenBodyHasOnlyHeadings() throws {
        let plainBody = "<h2>第一章</h2><p>甲</p><h2>第二章</h2><p>乙</p>"
        let html = try HTMLTemplateAssembly.assemble(template: template, title: nil, body: plainBody)
        XCTAssertTrue(html.contains("<h2 id=\"第一章\">第一章</h2>"), "没有 section#id 时由宿主补 id：\(html)")
        XCTAssertTrue(html.contains("<a href=\"#第一章\""), html)
        XCTAssertTrue(html.contains("<a href=\"#第二章\""), html)
    }

    func test_assemble_deduplicatesHeadingIDs() throws {
        let plainBody = "<h2>小结</h2><p>甲</p><h2>小结</h2><p>乙</p>"
        let html = try HTMLTemplateAssembly.assemble(template: template, title: nil, body: plainBody)
        XCTAssertTrue(html.contains("<h2 id=\"小结\">"), html)
        XCTAssertTrue(html.contains("<h2 id=\"小结-2\">"), "同名标题要拿到不同的 id，否则导航两条都跳第一处")
    }

    func test_assemble_rejectsStyleInBody() {
        let bad = "<section id=\"a\"><style>p{color:red}</style></section>"
        XCTAssertThrowsError(try HTMLTemplateAssembly.assemble(template: template, title: nil, body: bad)) { error in
            XCTAssertEqual(error as? HTMLTemplateAssembly.Failure, .bodyContainsStyle)
            XCTAssertTrue((error as? HTMLTemplateAssembly.Failure)?.modelFacingMessage.contains("patch_style") == true)
        }
    }

    func test_assemble_rejectsExternalStylesheet() {
        let bad = "<section id=\"a\"><link rel=\"stylesheet\" href=\"x.css\"></section>"
        XCTAssertThrowsError(try HTMLTemplateAssembly.assemble(template: template, title: nil, body: bad)) { error in
            XCTAssertEqual(error as? HTMLTemplateAssembly.Failure, .bodyContainsExternalCSS)
        }
    }

    func test_assemble_fallsBackToBodyWhenTemplateHasNoMain() throws {
        let simple = "<html><head><title>t</title></head><body><p>旧</p></body></html>"
        let html = try HTMLTemplateAssembly.assemble(template: simple, title: nil, body: "<p>新</p>")
        XCTAssertTrue(html.contains("<p>新</p>"))
        XCTAssertFalse(html.contains("<p>旧</p>"))
    }

    func test_assemble_throwsWhenNoContentRegion() {
        XCTAssertThrowsError(try HTMLTemplateAssembly.assemble(
            template: "<div>片段</div>", title: nil, body: "<p>x</p>")
        ) { error in
            XCTAssertEqual(error as? HTMLTemplateAssembly.Failure, .missingContentRegion)
        }
    }

    func test_assemble_templateWithoutNav_isUntouched() throws {
        let noNav = "<html><body><main><p>旧</p></main></body></html>"
        let html = try HTMLTemplateAssembly.assemble(template: noNav, title: nil, body: body)
        XCTAssertTrue(html.contains("<section id=\"intro\">"))
        XCTAssertFalse(html.contains("<a href"), "没有侧边栏的模板不该被凭空塞进导航")
    }

    func test_slug_handlesSpacesAndPunctuation() {
        XCTAssertEqual(HTMLTemplateAssembly.slug(for: "Hello World!"), "hello-world")
        XCTAssertEqual(HTMLTemplateAssembly.slug(for: "  a  b  "), "a-b")
        XCTAssertEqual(HTMLTemplateAssembly.slug(for: "!!!"), "section", "全标点的标题要有兜底 id")
    }
}
