import XCTest
@testable import MEditor

/// HTML 扫描层：`<style>` 定位、结构树、选择器、容错。
///
/// 这一层唯一不可退让的性质是「偏移量对得上源文」——`patch_style` / `set_node_class`
/// 都是在这个偏移上做定点替换，错一个字符就是把标签改坏。
final class HTMLStructureTests: XCTestCase {

    private let doc = """
    <!DOCTYPE html>
    <html lang="zh">
    <head>
    <title>报告</title>
    <style>
    .a > .b { color: red; }
    h2::after { content: "</style>fake"; }
    </style>
    </head>
    <body>
    <main class="main">
      <section id="summary" class="lead">
        <h2>本周结论</h2>
        <ul><li>一</li><li>二</li><li>三</li></ul>
      </section>
      <section id="data">
        <h2>数据</h2>
        <table><tr><td>1</td></tr><tr><td>2</td></tr></table>
      </section>
    </main>
    <script>if (a < b) { console.log("</b>") }</script>
    </body>
    </html>
    """

    func test_styleRange_stopsAtRealClosingTag() {
        let document = HTMLScanner.scan(doc)
        XCTAssertEqual(document.styleRanges.count, 1, "CSS 里出现的 `</style>` 字符串不能提前截断样式块")
        XCTAssertTrue(document.styleText.contains(".a > .b"), "CSS 里的 `>` 不能被当成标签：\(document.styleText)")
    }

    func test_scriptContent_isNotParsedAsTags() {
        let document = HTMLScanner.scan(doc)
        // `<script>` 里有个裸 `<`：若被解析成标签，会凭空多出元素
        XCTAssertFalse(document.elements.contains { $0.name == "b" }, "script 内部不是标签流")
        XCTAssertEqual(document.elements.filter { $0.name == "section" }.count, 2)
    }

    func test_outline_listsSectionsHeadingsAndCounts() {
        let outline = HTMLScanner.scan(doc).outline()
        XCTAssertTrue(outline.contains("section#summary.lead"), outline)
        XCTAssertTrue(outline.contains("h2 「本周结论」"), outline)
        XCTAssertTrue(outline.contains("ul(3)"), "列表要带直接子项数：\(outline)")
        XCTAssertTrue(outline.contains("table(2 行)"), outline)
        XCTAssertFalse(outline.contains("color: red"), "大纲里不该出现 CSS")
    }

    func test_selector_matching() {
        let document = HTMLScanner.scan(doc)
        XCTAssertEqual(document.matchIndices(selector: "#data").count, 1)
        XCTAssertEqual(document.matchIndices(selector: "section").count, 2)
        XCTAssertEqual(document.matchIndices(selector: ".lead").count, 1)
        XCTAssertEqual(document.matchIndices(selector: "h2").count, 2)
        XCTAssertEqual(document.matchIndices(selector: "li").count, 3)
        XCTAssertEqual(document.matchIndices(selector: "li:nth(2)").count, 1)
        XCTAssertEqual(document.matchIndices(selector: "main.main").count, 1)
        XCTAssertTrue(document.matchIndices(selector: "#nope").isEmpty)
    }

    func test_selector_parsingRejectsUnsupportedCombinations() {
        XCTAssertNil(HTMLSelector("#a.b"), "组合形态不在支持范围内：与其静默只匹配一半，不如报错")
        XCTAssertNil(HTMLSelector(""))
        XCTAssertNotNil(HTMLSelector("#a"))
        XCTAssertNotNil(HTMLSelector("table:nth(2)"))
    }

    func test_elementOffsets_allowExactSlicing() throws {
        let html = "<div id=\"x\">甲</div>"
        let document = HTMLScanner.scan(html)
        let element = try XCTUnwrap(document.elements.first { $0.name == "div" })
        XCTAssertEqual(document.slice(element.startOffset..<element.endOffset), html)
        XCTAssertEqual(document.slice(element.contentStart..<element.contentEnd), "甲")
        XCTAssertEqual(element.attributeValueRanges["id"].map { document.slice($0) }, "x")
    }

    func test_unclosedTags_areTolerated() {
        let html = "<div class=\"card\"><p>正文<span>x</div>"
        let document = HTMLScanner.scan(html)
        XCTAssertEqual(document.elements.filter { $0.name == "div" }.count, 1)
        XCTAssertEqual(document.elements.first { $0.name == "div" }?.classes, ["card"])
    }

    func test_collapse_stripsTagsAndDecodesEntities() {
        XCTAssertEqual(
            HTMLDocument.collapse("<h2>Hello <code>world</code> &amp; 更多</h2>"),
            "Hello world & 更多")
    }

    func test_foldedStyleNotice_reportsCountAndTokens() {
        let notice = HTMLScanner.scan(doc).foldedStyleNotice
        XCTAssertTrue(notice.contains("1 个 <style> 块"), notice)
        XCTAssertTrue(notice.contains("已折叠"), notice)
        XCTAssertTrue(HTMLScanner.scan("<p>无样式</p>").foldedStyleNotice.contains("无独立"))
    }

    func test_sectionAnchors_useIdAndFirstHeading() {
        let anchors = HTMLScanner.scan(doc).sectionAnchors()
        XCTAssertEqual(anchors.map(\.id), ["summary", "data"])
        XCTAssertEqual(anchors.map(\.title), ["本周结论", "数据"])
    }

    func test_emptyDocument() {
        XCTAssertTrue(HTMLScanner.scan("").isEmpty)
        XCTAssertTrue(HTMLScanner.scan("纯文本，没有标签").isEmpty)
    }
}
