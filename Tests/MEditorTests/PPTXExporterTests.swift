import XCTest
@testable import MEditor

/// .pptx 导出的结构性测试：ZIP 容器合法性（自行解析中央目录）、
/// 每个 XML 部件的 well-formedness（真跑 XMLParser）、内容类型表完整性、
/// 以及与 HTML 演示导出共用的 `SlideSplitter` 分页一致性。
final class PPTXExporterTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - 最小 ZIP 读取器（测试专用，解析中央目录）

    private struct ZipEntryInfo {
        var name: String
        var method: UInt16
        var crc: UInt32
        var uncompressedSize: UInt32
        var localHeaderOffset: UInt32
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    /// 从 EOCD 定位中央目录并逐条解析。EOCD 无注释，定长 22 字节、位于文件尾。
    private func centralDirectory(of zip: Data) -> [ZipEntryInfo] {
        let eocd = zip.count - 22
        XCTAssertGreaterThanOrEqual(eocd, 0)
        XCTAssertEqual(uint32(zip, at: eocd), 0x0605_4B50, "缺 EOCD 签名")
        let count = Int(uint16(zip, at: eocd + 10))
        var offset = Int(uint32(zip, at: eocd + 16))

        var entries: [ZipEntryInfo] = []
        for _ in 0..<count {
            XCTAssertEqual(uint32(zip, at: offset), 0x0201_4B50, "中央目录条目签名错误")
            let nameLength = Int(uint16(zip, at: offset + 28))
            let extraLength = Int(uint16(zip, at: offset + 30))
            let commentLength = Int(uint16(zip, at: offset + 32))
            let name = String(decoding: zip[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            entries.append(ZipEntryInfo(
                name: name,
                method: uint16(zip, at: offset + 10),
                crc: uint32(zip, at: offset + 16),
                uncompressedSize: uint32(zip, at: offset + 24),
                localHeaderOffset: uint32(zip, at: offset + 42)
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// 按本地文件头取出条目内容（stored：数据原样跟在头部后）。
    private func localContent(of zip: Data, entry: ZipEntryInfo) -> (name: String, data: Data) {
        let offset = Int(entry.localHeaderOffset)
        XCTAssertEqual(uint32(zip, at: offset), 0x0403_4B50, "本地文件头签名错误")
        let nameLength = Int(uint16(zip, at: offset + 26))
        let extraLength = Int(uint16(zip, at: offset + 28))
        let name = String(decoding: zip[(offset + 30)..<(offset + 30 + nameLength)], as: UTF8.self)
        let dataStart = offset + 30 + nameLength + extraLength
        let data = zip[dataStart..<(dataStart + Int(entry.uncompressedSize))]
        return (name, Data(data))
    }

    private func makeArchive(slides: [String]) -> (zip: Data, entries: [ZipEntryInfo]) {
        let zip = PPTXExporter.makePPTX(slides: slides, title: "Test Deck", date: fixedDate)
        return (zip, centralDirectory(of: zip))
    }

    private func partData(_ zip: Data, _ entries: [ZipEntryInfo], _ name: String) -> Data? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        return localContent(of: zip, entry: entry).data
    }

    // MARK: - ZIP 容器

    func test_zip_containsAllRequiredParts() {
        let (_, entries) = makeArchive(slides: ["# A", "# B", "# C"])
        let names = Set(entries.map(\.name))
        var expected: Set<String> = [
            "[Content_Types].xml",
            "_rels/.rels",
            "docProps/core.xml",
            "docProps/app.xml",
            "ppt/presentation.xml",
            "ppt/_rels/presentation.xml.rels",
            "ppt/theme/theme1.xml",
            "ppt/slideMasters/slideMaster1.xml",
            "ppt/slideMasters/_rels/slideMaster1.xml.rels",
            "ppt/slideLayouts/slideLayout1.xml",
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
        ]
        for n in 1...3 {
            expected.insert("ppt/slides/slide\(n).xml")
            expected.insert("ppt/slides/_rels/slide\(n).xml.rels")
        }
        XCTAssertEqual(names, expected)
    }

    func test_zip_entriesStoredWithMatchingCRC() {
        let (zip, entries) = makeArchive(slides: ["# A\n\nhello", "# B"])
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            XCTAssertEqual(entry.method, 0, "\(entry.name) 应为 stored")
            let local = localContent(of: zip, entry: entry)
            XCTAssertEqual(local.name, entry.name, "本地头与中央目录文件名不一致")
            XCTAssertEqual(UInt32(local.data.count), entry.uncompressedSize)
            XCTAssertEqual(ZipWriter.crc32(local.data), entry.crc, "\(entry.name) CRC 不匹配")
        }
    }

    func test_crc32_knownVector() {
        // 标准测试向量："123456789" → 0xCBF43926
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZipWriter.crc32(Data()), 0)
    }

    // MARK: - 内容类型表与交叉引用

    func test_contentTypes_coversEveryPart() {
        let (zip, entries) = makeArchive(slides: ["# A", "# B"])
        let contentTypes = String(decoding: partData(zip, entries, "[Content_Types].xml")!, as: UTF8.self)
        for entry in entries {
            let name = entry.name
            if name.hasSuffix(".rels") || name == "[Content_Types].xml" { continue }
            // Default 只覆盖扩展名；OOXML 部件约定必须各自有 Override
            XCTAssertTrue(
                contentTypes.contains("PartName=\"/\(name)\""),
                "[Content_Types].xml 缺 \(name) 的 Override"
            )
        }
    }

    func test_presentationRels_matchSlideIds() {
        let (zip, entries) = makeArchive(slides: ["# A", "# B"])
        let presentation = String(decoding: partData(zip, entries, "ppt/presentation.xml")!, as: UTF8.self)
        let rels = String(decoding: partData(zip, entries, "ppt/_rels/presentation.xml.rels")!, as: UTF8.self)
        // presentation.xml 引用的每个 rId 都必须在 rels 里有定义
        let idPattern = try! NSRegularExpression(pattern: #"r:id="(rId\d+)""#)
        let referenced = idPattern.matches(in: presentation, range: NSRange(presentation.startIndex..., in: presentation))
            .compactMap { Range($0.range(at: 1), in: presentation).map { String(presentation[$0]) } }
        XCTAssertEqual(referenced.count, 3)   // rId1 母版 + 2 页
        for rid in referenced {
            XCTAssertTrue(rels.contains("Id=\"\(rid)\""), "presentation.xml.rels 缺 \(rid)")
        }
    }

    // MARK: - XML 合法性

    func test_everyXMLPart_isWellFormed() {
        let slides = ["# 标题 <script> & \"引号\"\n\n- 含 <b>HTML</b> 的条目", "```\nif a < b && c > d {}\n```"]
        let (zip, entries) = makeArchive(slides: slides)
        for entry in entries where entry.name.hasSuffix(".xml") || entry.name.hasSuffix(".rels") {
            let data = partData(zip, entries, entry.name)!
            let parser = XMLParser(data: data)
            XCTAssertTrue(parser.parse(), "\(entry.name) XML 不合法: \(parser.parserError?.localizedDescription ?? "")")
        }
    }

    func test_xmlEscaping_inSlideContent() {
        let (zip, entries) = makeArchive(slides: ["# A <B> & \"C\" 'D'"])
        let slide = String(decoding: partData(zip, entries, "ppt/slides/slide1.xml")!, as: UTF8.self)
        XCTAssertTrue(slide.contains("A &lt;B&gt; &amp; &quot;C&quot; &apos;D&apos;"))
        XCTAssertFalse(slide.contains("<B>"))
    }

    // MARK: - 与 HTML 导出共用分页

    func test_slideCount_matchesSlideSplitter() {
        // 分页符 / front matter / fence 内 --- 三个规则一起验：页数必须与 SlideSplitter 一致
        let markdown = """
        ---
        title: Deck
        ---
        # 第一页

        ```text
        ---
        ```

        ---

        # 第二页

        - a
        - b
        """
        let slides = SlideSplitter.split(markdown)
        let (_, entries) = makeArchive(slides: slides)
        let slideParts = entries.filter { $0.name.hasPrefix("ppt/slides/slide") && $0.name.hasSuffix(".xml") }
        XCTAssertEqual(slideParts.count, slides.count)
        XCTAssertEqual(slides.count, 2)
    }

    // MARK: - Markdown 归约

    func test_parseSlide_titleBulletsAndCode() {
        let content = PPTXExporter.parseSlide("""
        # 标题

        正文 **加粗** 与 [链接](https://example.com)。

        - 一级
          - 二级
        1. 有序也按项目符号

        ```swift
        let x = 1
        ```
        """)
        XCTAssertEqual(content.title, "标题")
        XCTAssertTrue(content.paragraphs.contains(where: {
            $0.bulletLevel == 0 && !$0.isCode && $0.text == "正文 加粗 与 链接。"
        }))
        XCTAssertTrue(content.paragraphs.contains(where: { $0.bulletLevel == 1 && $0.text == "一级" }))
        XCTAssertTrue(content.paragraphs.contains(where: { $0.bulletLevel == 2 && $0.text == "二级" }))
        XCTAssertTrue(content.paragraphs.contains(where: { $0.bulletLevel == 1 && $0.text == "有序也按项目符号" }))
        XCTAssertTrue(content.paragraphs.contains(where: { $0.isCode && $0.text == "let x = 1" }))
    }

    func test_parseSlide_imageKeepsAltText() {
        let content = PPTXExporter.parseSlide("![架构图](images/a.png)")
        XCTAssertEqual(content.paragraphs.first?.text, "架构图")
    }

    func test_emptyInput_producesOneEmptySlide() {
        let (_, entries) = makeArchive(slides: [])
        XCTAssertTrue(entries.contains(where: { $0.name == "ppt/slides/slide1.xml" }))
    }
}
