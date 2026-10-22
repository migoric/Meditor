import XCTest
@testable import MEditor

/// MermaidBlocks 提取与行号映射：纯逻辑，不碰 WebKit。
/// 判定口径锚定 render.js 的 `extractMermaid`（预览会渲染成图的才校验），
/// 围栏配对规则 = CommonMark：0–3 空格缩进、关栏长度 ≥ 开栏、关栏行只有空白。
final class MermaidBlocksTests: XCTestCase {

    func testExtractsSingleBlockWithStartLineAndCode() {
        let content = "# Title\n\n```mermaid\ngraph TD\n  A --> B\n```\n"
        let blocks = MermaidBlocks.extract(from: content)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].startLine, 2, "startLine 应是开栏行的 0-based 行号")
        XCTAssertEqual(blocks[0].code, "graph TD\n  A --> B", "code 不含开栏/关栏行")
    }

    func testExtractsMultipleBlocksInOrder() {
        let content = """
        intro

        ```mermaid
        graph TD
        ```

        between

        ```mermaid
        sequenceDiagram
        ```
        """
        let blocks = MermaidBlocks.extract(from: content)
        XCTAssertEqual(blocks.map(\.startLine), [2, 8])
        XCTAssertEqual(blocks.map(\.code), ["graph TD", "sequenceDiagram"])
    }

    func testNonMermaidFencesIgnored() {
        let content = """
        ```swift
        let x = 1
        ```

        ```
        plain code
        ```

        ```mermaidx
        not mermaid
        ```
        """
        XCTAssertTrue(MermaidBlocks.extract(from: content).isEmpty,
                      "swift / 无 info / mermaidx 围栏都不应被当作 mermaid 块")
    }

    func testTildeMermaidFenceIgnored() {
        // render.js 只匹配 ```mermaid，~~~mermaid 预览不会渲染成图，校验只会误报
        let content = "~~~mermaid\ngraph TD\n~~~\n"
        XCTAssertTrue(MermaidBlocks.extract(from: content).isEmpty)
    }

    func testInfoStringIsCaseSensitive() {
        // 与 render.js 一致：```Mermaid 不会走 mermaid 渲染路径
        XCTAssertTrue(MermaidBlocks.extract(from: "```Mermaid\ngraph TD\n```\n").isEmpty)
    }

    func testInfoStringWithTrailingArgumentsStillMatches() {
        // ```mermaid 附带参数（部分高亮器的写法）仍是 mermaid 块
        let blocks = MermaidBlocks.extract(from: "```mermaid theme=dark\ngraph TD\n```\n")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].code, "graph TD")
    }

    func testIndentedFenceMatches() {
        let blocks = MermaidBlocks.extract(from: "text\n  ```mermaid\n  graph TD\n  ```\n")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].startLine, 1)
    }

    func testUnclosedMermaidBlockStillExtracted() {
        // 未闭合由 unclosedCodeBlock 另报；块内代码仍值得校验（错误往往在内容里）
        let blocks = MermaidBlocks.extract(from: "```mermaid\ngraph TD\n  A -->\n")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].startLine, 0)
        // 末尾换行拆出的空尾行也在围栏内（未闭合没有关栏行可排除），交给 mermaid.parse 容忍
        XCTAssertEqual(blocks[0].code, "graph TD\n  A -->\n")
    }

    func testMermaidBlockInsideOtherFenceNotExtracted() {
        // 外层 swift 围栏内的 ``` 行不是开栏（同字符关栏语义与 DocumentDiagnostics 一致）
        let content = "```\n```mermaid\ngraph TD\n```\n```\n"
        XCTAssertTrue(MermaidBlocks.extract(from: content).isEmpty)
    }

    // MARK: CommonMark 围栏配对（#85）

    func testFourSpaceIndentedFenceIsIndentedCodeBlock() {
        // 4 空格是缩进代码块，marked 不会把它当围栏 ⇒ 预览不出图，也不该校验
        let content = "    ```mermaid\n    graph TD\n    ```\n"
        XCTAssertTrue(MermaidBlocks.extract(from: content).isEmpty)
    }

    func testMermaidInsideLongerFenceNotExtracted() {
        // 外层 4 个反引号围栏里的 ```mermaid 只是文本
        let content = "````\n```mermaid\ngraph TD\n```\n````\n"
        XCTAssertTrue(MermaidBlocks.extract(from: content).isEmpty)
    }

    func testLongerFenceMayCloseShorterFence() {
        // 开栏 3 个、关栏 4 个 ⇒ 合法关闭（CommonMark 只要求 ≥）
        let blocks = MermaidBlocks.extract(from: "```mermaid\ngraph TD\n````\n")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].code, "graph TD")
    }

    func testShorterFenceCannotCloseLongerFence() {
        // 开栏 4 个、中间 3 个 ⇒ 中间那行是内容，不算关栏
        let blocks = MermaidBlocks.extract(from: "````mermaid\ngraph TD\n```\n````\n")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].code, "graph TD\n```")
    }

    func testInlineTripleBackticksInProseDoNotOpenFence() {
        // 行中间的 ``` 不是围栏（行首锚定）
        let content = """
        正文里说「行首的 ```mermaid 才是围栏」。

        ```swift
        let x = 1
        ```

        再说一句 ```mermaid。
        """
        XCTAssertTrue(MermaidBlocks.extract(from: content).isEmpty)
    }

    func testFenceAfterOtherFenceStillFound() {
        // 状态机：非 mermaid 围栏关掉之后，后面的 mermaid 围栏仍要认出来，
        // 且行号是**原文**行号（不是相对上一块的行号）
        let content = "```swift\nlet x = 1\n```\n\n```mermaid\ngraph TD\n```\n"
        let blocks = MermaidBlocks.extract(from: content)
        XCTAssertEqual(blocks.map(\.startLine), [4])
        XCTAssertEqual(blocks.map(\.code), ["graph TD"])
    }

    func testCRLFFenceExtracted() {
        // CRLF 文本不该因为行尾 \r 让 info string 变成 "mermaid\r"
        let blocks = MermaidBlocks.extract(from: "```mermaid\r\ngraph TD\r\n```\r\n")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].code, "graph TD")
    }
}
