import XCTest
@testable import MEditor

/// Markdown 结构层：标题树、定位、整节替换。
///
/// 这层是 `read_section` / `rewrite_section` 的地基，判据只有一条：
/// **定位错了就是改错用户的文档**。所以用例全都围绕「会不会认错节」写：
/// 围栏代码块里的 `#`、重名标题、层级跳跃、无标题文档。
final class MarkdownStructureTests: XCTestCase {

    // MARK: - 标题识别

    func test_atxHeading_requiresSpaceAfterHashes() {
        XCTAssertEqual(MarkdownStructure.parseATX("## 设计")?.title, "设计")
        XCTAssertNil(MarkdownStructure.parseATX("##设计"), "与 CommonMark / marked 一致：`#` 后必须有空格，否则预览也不认")
        XCTAssertNil(MarkdownStructure.parseATX("    # 缩进四格"), "四个空格是缩进代码块")
        XCTAssertEqual(MarkdownStructure.parseATX("   ### 三格缩进")?.level, 3)
    }

    func test_atxHeading_trailingHashesStrippedOnlyAfterSpace() {
        XCTAssertEqual(MarkdownStructure.parseATX("## 标题 ##")?.title, "标题")
        XCTAssertEqual(MarkdownStructure.parseATX("## C#")?.title, "C#", "结尾的 `#` 前没有空格，属于标题文本")
        XCTAssertEqual(MarkdownStructure.parseATX("## 标题#")?.title, "标题#")
    }

    func test_fencedCodeBlock_headingsInsideAreIgnored() {
        let text = """
        # 真标题

        ```bash
        # 这是注释，不是标题
        ## 也不是
        ```
        """
        let headings = MarkdownStructure.headings(in: text)
        XCTAssertEqual(headings.map(\.title), ["真标题"])
    }

    func test_tildeFence_andLongerClosingFence() {
        let text = """
        # A

        ~~~
        # not a heading
        ~~~~
        # B
        """
        XCTAssertEqual(MarkdownStructure.headings(in: text).map(\.title), ["A", "B"])
    }

    func test_setextHeading_supported() {
        let text = "大标题\n=====\n\n内容\n\n小标题\n---\n\n内容"
        let headings = MarkdownStructure.headings(in: text)
        XCTAssertEqual(headings.map(\.level), [1, 2])
        XCTAssertEqual(headings.map(\.title), ["大标题", "小标题"])
    }

    func test_setextUnderlineLine_isNotItselfATitle() {
        // 缺陷形态：`=====` 被当成下一节的标题，于是大纲里多出一个叫「=====」的节
        let text = "A\n===\nB\n---\n正文"
        XCTAssertEqual(MarkdownStructure.headings(in: text).map(\.title), ["A", "B"])
    }

    func test_thematicBreak_aloneIsNotAHeading() {
        let text = "# A\n\n正文\n\n---\n\n更多正文"
        XCTAssertEqual(MarkdownStructure.headings(in: text).count, 1)
    }

    // MARK: - 节树

    func test_sections_nestingPathAndLineRanges() {
        let text = """
        # 一

        开头

        ## 1.1

        甲

        ## 1.2

        乙

        # 二

        结尾
        """
        let sections = MarkdownStructure.sections(in: text)
        XCTAssertEqual(sections.map(\.ordinal), [1, 2, 3, 4])
        XCTAssertEqual(sections.map(\.title), ["一", "1.1", "1.2", "二"])
        XCTAssertEqual(sections[0].path, ["一"])
        XCTAssertEqual(sections[1].path, ["一", "1.1"], "嵌套节要带完整路径，用于重名消歧")
        XCTAssertEqual(sections[0].endLine, 12, "父节覆盖到下一个同级标题之前（含子节正文）")
        XCTAssertEqual(sections[3].startLine, 13)
        XCTAssertEqual(sections[3].endLine, 15)
    }

    func test_sections_bodyCharCount() {
        let text = "# A\n\n0123456789\n\n# B\n\nx"
        let sections = MarkdownStructure.sections(in: text)
        XCTAssertEqual(sections[0].charCount, 10)
        XCTAssertEqual(sections[1].charCount, 1)
    }

    func test_noHeadings_fallsBackToParagraphBlocks() {
        let text = "第一段\n第二行\n\n第二段\n\n第三段"
        let sections = MarkdownStructure.sections(in: text)
        XCTAssertEqual(sections.count, 3)
        XCTAssertTrue(sections.allSatisfy { $0.isParagraphBlock })
        XCTAssertEqual(sections[0].startLine, 1)
        XCTAssertEqual(sections[0].endLine, 2)
        XCTAssertEqual(sections[1].startLine, 4)
    }

    func test_outline_hasOrdinalsAndIndentation() {
        let text = "# 一\n\n正文\n\n## 1.1\n\n正文"
        let outline = MarkdownStructure.outline(text)
        let lines = outline.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("#1 · L1–L7"), "父节不应缩进，且带序号与行区间：\(lines[0])")
        XCTAssertTrue(lines[1].hasPrefix("  #2 ·"), "子节缩进两格：\(lines[1])")
    }

    func test_outline_truncatesWhenTooManySections() {
        let text = (1...5).map { "# 节\($0)\n\n正文" }.joined(separator: "\n\n")
        let outline = MarkdownStructure.outline(text, maxSections: 3)
        XCTAssertTrue(outline.contains("已省略 2 节"), outline)
    }

    // MARK: - 定位

    func test_locate_byOrdinal_title_andPath() throws {
        let text = "# 一\n\nA\n\n## 小结\n\n甲\n\n# 二\n\n## 小结\n\n乙"
        XCTAssertEqual(try MarkdownStructure.locate("#2", in: text).title, "小结")
        XCTAssertEqual(try MarkdownStructure.locate("2", in: text).ordinal, 2)
        XCTAssertEqual(try MarkdownStructure.locate("## 二", in: text).title, "二", "查询里带 # 前缀也能匹配标题")
        XCTAssertEqual(try MarkdownStructure.locate("二 > 小结", in: text).ordinal, 4)
    }

    func test_locate_duplicateTitle_isAmbiguousNotGuessed() {
        let text = "# 一\n\n## 小结\n\n甲\n\n# 二\n\n## 小结\n\n乙"
        XCTAssertThrowsError(try MarkdownStructure.locate("小结", in: text)) { error in
            guard case MarkdownStructureError.ambiguous(let query, let matches) = error else {
                return XCTFail("重名标题必须报歧义，不能猜一个改掉：\(error)")
            }
            XCTAssertEqual(query, "小结")
            XCTAssertEqual(matches.count, 2)
            XCTAssertTrue(matches.allSatisfy { $0.pathText.hasSuffix("小结") })
        }
    }

    func test_locate_missing_listsAvailableSections() {
        XCTAssertThrowsError(try MarkdownStructure.locate("不存在", in: "# 一\n\n# 二")) { error in
            guard case MarkdownStructureError.notFound(_, let available) = error else {
                return XCTFail("未命中应给出候选清单：\(error)")
            }
            XCTAssertEqual(available, ["一", "二"])
            let message = (error as? MarkdownStructureError)?.modelFacingMessage ?? ""
            XCTAssertTrue(message.contains("没有找到"), message)
        }
    }

    // MARK: - 整节替换

    func test_replacing_keepsHeadingByDefault() {
        let text = "# 一\n\n旧正文\n\n# 二\n\n乙"
        let section = try! MarkdownStructure.locate("#1", in: text)
        let updated = MarkdownStructure.replacing(section, in: text, with: "新正文")
        XCTAssertEqual(updated, "# 一\n\n新正文\n\n# 二\n\n乙", "只换正文，标题与别的节一字不动")
    }

    func test_replacing_contentStartingWithHeading_replacesHeadingToo() {
        let text = "# 一\n\n旧正文\n\n# 二\n\n乙"
        let section = try! MarkdownStructure.locate("#1", in: text)
        let updated = MarkdownStructure.replacing(section, in: text, with: "## 改名了\n\n新正文")
        XCTAssertEqual(updated, "## 改名了\n\n新正文\n\n# 二\n\n乙")
    }

    func test_replacing_lastSection_noTrailingNewline() {
        let text = "# 一\n\n甲\n\n# 二\n\n乙"
        let section = try! MarkdownStructure.locate("#2", in: text)
        let updated = MarkdownStructure.replacing(section, in: text, with: "新乙")
        XCTAssertEqual(updated, "# 一\n\n甲\n\n# 二\n\n新乙")
    }

    func test_replacing_paragraphBlockFallback() {
        let text = "第一段\n\n第二段"
        let section = try! MarkdownStructure.locate("#2", in: text)
        let updated = MarkdownStructure.replacing(section, in: text, with: "改过的第二段")
        XCTAssertEqual(updated, "第一段\n\n改过的第二段")
    }

    func test_replacing_emptyBody_inserts() {
        let text = "# 一\n\n# 二"
        let section = try! MarkdownStructure.locate("#1", in: text)
        let updated = MarkdownStructure.replacing(section, in: text, with: "补上的正文")
        XCTAssertEqual(updated, "# 一\n\n补上的正文\n\n# 二", "空节替换不能把下一个标题吞掉")
    }

    // MARK: - 选区定位

    func test_sectionContainingSelection_returnsInnermost() {
        let text = "# 一\n\n甲\n\n## 1.1\n\n乙的段落"
        let section = MarkdownStructure.section(containing: "乙的段落", in: text)
        XCTAssertEqual(section?.title, "1.1")
    }
}
