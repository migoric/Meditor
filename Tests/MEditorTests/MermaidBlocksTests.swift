import XCTest
@testable import MEditor

/// MermaidBlocks 提取与行号映射：纯逻辑，不碰 WebKit。
/// 判定口径锚定 render.js 的 /```mermaid/ 检测（预览会渲染成图的才校验）。
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
}
