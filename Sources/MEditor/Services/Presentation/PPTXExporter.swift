import Foundation

/// 演示模式 .pptx 导出（v1：**纯文本幻灯片**，16:9）。
///
/// 输入是 `SlideSplitter` 分页后的 Markdown 片段——与 HTML 演示导出共用同一份
/// 拆分结果，本仓不存在第二份分页逻辑。本类型负责的是「一页 Markdown →
/// 标题 + 段落」的轻量归约，以及最小合法 OOXML 包的拼装（ZIP 见 `ZipWriter`）。
///
/// v1 取舍（后续方向：图片、mermaid 渲染图、代码高亮样式、主题跟随）：
/// - 图片行仅保留 alt 文本，不嵌入图片数据；
/// - 代码块按等宽纯文本保留内容，无语法高亮；
/// - 有序列表统一渲染为 • 项目符号（保留缩进层级，最深 4 级）；
/// - 版式固定：白底 + 内置最小 theme，不跟随预览主题。
enum PPTXExporter {

    /// 一页幻灯片的文本模型（归约后的 Markdown）。
    struct SlideContent: Equatable {
        struct Paragraph: Equatable {
            /// 0 = 普通正文；>=1 为项目符号层级（1 为顶级）。
            var bulletLevel: Int
            var isCode: Bool
            var text: String
        }
        var title: String?
        var paragraphs: [Paragraph]
    }

    /// 生成完整 .pptx 数据。`date` 可注入以保证测试可复现。
    /// 空输入兜底为一页空幻灯片（SlideSplitter 本来就保证至少一页）。
    static func makePPTX(slides: [String], title: String, date: Date = Date()) -> Data {
        let contents = slides.isEmpty ? [SlideContent(title: nil, paragraphs: [])]
                                      : slides.map(parseSlide)
        var entries: [ZipWriter.Entry] = []

        func add(_ name: String, _ xml: String) {
            entries.append(ZipWriter.Entry(name: name, data: Data(xml.utf8)))
        }

        add("[Content_Types].xml", contentTypesXML(slideCount: contents.count))
        add("_rels/.rels", rootRelsXML)
        add("docProps/core.xml", corePropsXML(title: title, date: date))
        add("docProps/app.xml", appPropsXML(slideCount: contents.count))
        add("ppt/presentation.xml", presentationXML(slideCount: contents.count))
        add("ppt/_rels/presentation.xml.rels", presentationRelsXML(slideCount: contents.count))
        add("ppt/theme/theme1.xml", themeXML)
        add("ppt/slideMasters/slideMaster1.xml", slideParentXML)
        add("ppt/slideMasters/_rels/slideMaster1.xml.rels", slideParentRelsXML)
        add("ppt/slideLayouts/slideLayout1.xml", slideLayoutXML)
        add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", slideLayoutRelsXML)
        for (index, content) in contents.enumerated() {
            let n = index + 1
            add("ppt/slides/slide\(n).xml", slideXML(content))
            add("ppt/slides/_rels/slide\(n).xml.rels", slideRelsXML)
        }

        return ZipWriter.write(entries)
    }

    // MARK: - Markdown 归约

    /// 一页 Markdown → 标题 + 段落。首个 ATX 标题作标题，其余标题降级为正文段；
    /// 列表行按缩进转项目符号层级；代码 fence 内逐行保留为等宽段。
    static func parseSlide(_ markdown: String) -> SlideContent {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var title: String?
        var paragraphs: [SlideContent.Paragraph] = []
        var fenceMarker: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // fence 开关（与 SlideSplitter 同款规则：``` / ~~~，可缩进）
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fenceMarker == nil {
                    fenceMarker = marker
                } else if fenceMarker == marker {
                    fenceMarker = nil
                }
                continue
            }
            if fenceMarker != nil {
                // 代码内容逐行保留（含前导缩进），等宽渲染
                paragraphs.append(.init(bulletLevel: 0, isCode: true,
                                        text: line.trimmingCharacters(in: .newlines)))
                continue
            }

            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("<!--") { continue }              // 注释行
            if trimmed == "---" { continue }                       // 页内残留分隔线

            if let heading = parseATXHeading(trimmed) {
                let text = stripInline(heading)
                if title == nil {
                    title = text
                } else if !text.isEmpty {
                    paragraphs.append(.init(bulletLevel: 0, isCode: false, text: text))
                }
                continue
            }

            if let item = parseListItem(line) {
                let text = stripInline(item.text)
                if !text.isEmpty {
                    paragraphs.append(.init(bulletLevel: min(item.level, 4), isCode: false, text: text))
                }
                continue
            }

            let text = stripInline(trimmed)
            if !text.isEmpty {
                paragraphs.append(.init(bulletLevel: 0, isCode: false, text: text))
            }
        }

        return SlideContent(title: title, paragraphs: paragraphs)
    }

    /// `# `–`###### ` 标题，去掉行尾多余的 `#`。
    private static func parseATXHeading(_ line: String) -> String? {
        var hashes = 0
        for ch in line {
            if ch == "#" { hashes += 1 } else { break }
        }
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " || rest.isEmpty else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// 列表项：`-` / `*` / `+` / `1.` / `1)`，两级缩进一档（tab 按 2 空格计）。
    private static func parseListItem(_ line: String) -> (level: Int, text: String)? {
        var indent = 0
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == " " { indent += 1 } else if line[index] == "\t" { indent += 2 } else { break }
            index = line.index(after: index)
        }
        let rest = line[index...]
        guard let first = rest.first else { return nil }

        var markerLength = 0
        if "-*+".contains(first) {
            markerLength = 1
        } else if first.isNumber {
            var digits = 0
            var i = rest.startIndex
            while i < rest.endIndex, rest[i].isNumber { digits += 1; i = rest.index(after: i) }
            guard digits > 0, i < rest.endIndex, rest[i] == "." || rest[i] == ")" else { return nil }
            markerLength = digits + 1
        } else {
            return nil
        }

        let afterMarker = rest.index(rest.startIndex, offsetBy: markerLength)
        guard afterMarker < rest.endIndex, rest[afterMarker] == " " || rest[afterMarker] == "\t" else {
            return nil
        }
        let text = rest[afterMarker...].trimmingCharacters(in: .whitespaces)
        return (level: 1 + indent / 2, text: text)
    }

    /// 去掉行内 Markdown 标记：图片保留 alt、链接保留文字、粗斜体/删除线/行内代码去符号。
    private static func stripInline(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "~~", "`"] {
            s = s.replacingOccurrences(of: marker, with: "")
        }
        // 单星/下划线斜体标记（已成对处理的 **/__ 在上面先去掉了）
        s = s.replacingOccurrences(of: #"(?<=\s|^)[*_]([^*_]+)[*_](?=\s|$|[.,;:!?])"#,
                                   with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - XML 拼装

    private static let nsA = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private static let nsP = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let nsR = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let nsRel = "http://schemas.openxmlformats.org/package/2006/relationships"

    private static var xmlHeader: String {
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func contentTypesXML(slideCount: Int) -> String {
        var overrides = ""
        for n in 1...slideCount {
            overrides += """
            <Override PartName="/ppt/slides/slide\(n).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>

            """
        }
        return xmlHeader + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        \(overrides)<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """
    }

    private static var rootRelsXML: String {
        xmlHeader + """
        <Relationships xmlns="\(nsRel)">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
    }

    private static func corePropsXML(title: String, date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: date)
        return xmlHeader + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(xmlEscape(title))</dc:title>
        <dc:creator>MEditor</dc:creator>
        <cp:lastModifiedBy>MEditor</cp:lastModifiedBy>
        <dcterms:created xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:created>
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:modified>
        </cp:coreProperties>
        """
    }

    private static func appPropsXML(slideCount: Int) -> String {
        xmlHeader + """
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
        <Application>MEditor</Application>
        <Slides>\(slideCount)</Slides>
        </Properties>
        """
    }

    /// 16:9：12192000 × 6858000 EMU。
    private static func presentationXML(slideCount: Int) -> String {
        var ids = ""
        for n in 1...slideCount {
            // rId1 留给 slideMaster，slide 从 rId2 起
            ids += #"<p:sldId id="\#(255 + n)" r:id="rId\#(n + 1)"/>"# + "\n"
        }
        return xmlHeader + """
        <p:presentation xmlns:a="\(nsA)" xmlns:p="\(nsP)" xmlns:r="\(nsR)">
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
        <p:sldIdLst>
        \(ids)</p:sldIdLst>
        <p:sldSz cx="12192000" cy="6858000" type="wide"/>
        <p:notesSz cx="6858000" cy="9144000"/>
        </p:presentation>
        """
    }

    private static func presentationRelsXML(slideCount: Int) -> String {
        var rels = """
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>

        """
        for n in 1...slideCount {
            rels += """
            <Relationship Id="rId\(n + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide\(n).xml"/>

            """
        }
        return xmlHeader + """
        <Relationships xmlns="\(nsRel)">
        \(rels)</Relationships>
        """
    }

    /// 最小母版：空 spTree + 完整 clrMap + 引用唯一版式。空的 txStyles 让
    /// PowerPoint 用内置默认文字样式，免去三大段样板。
    private static var slideParentXML: String {
        xmlHeader + """
        <p:sldMaster xmlns:a="\(nsA)" xmlns:p="\(nsP)" xmlns:r="\(nsR)">
        <p:cSld><p:bg><p:bgPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>
        <p:spTree>
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        </p:spTree>
        </p:cSld>
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
        <p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles>
        </p:sldMaster>
        """
    }

    private static var slideParentRelsXML: String {
        xmlHeader + """
        <Relationships xmlns="\(nsRel)">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
        </Relationships>
        """
    }

    /// 空白版式：幻灯片上的文本框用绝对坐标，不依赖版式占位符。
    private static var slideLayoutXML: String {
        xmlHeader + """
        <p:sldLayout xmlns:a="\(nsA)" xmlns:p="\(nsP)" xmlns:r="\(nsR)" type="blank" preserve="1">
        <p:cSld name="Blank">
        <p:spTree>
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        </p:spTree>
        </p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sldLayout>
        """
    }

    private static var slideLayoutRelsXML: String {
        xmlHeader + """
        <Relationships xmlns="\(nsRel)">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
        </Relationships>
        """
    }

    private static var slideRelsXML: String {
        xmlHeader + """
        <Relationships xmlns="\(nsRel)">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        </Relationships>
        """
    }

    /// 最小 Office theme：clrScheme + fontScheme + fmtScheme 都是 schema 必填。
    private static var themeXML: String {
        xmlHeader + """
        <a:theme xmlns:a="\(nsA)" name="MEditor">
        <a:themeElements>
        <a:clrScheme name="MEditor">
        <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
        <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
        <a:dk2><a:srgbClr val="44546A"/></a:dk2>
        <a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>
        <a:accent1><a:srgbClr val="4472C4"/></a:accent1>
        <a:accent2><a:srgbClr val="ED7D31"/></a:accent2>
        <a:accent3><a:srgbClr val="A5A5A5"/></a:accent3>
        <a:accent4><a:srgbClr val="FFC000"/></a:accent4>
        <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5>
        <a:accent6><a:srgbClr val="70AD47"/></a:accent6>
        <a:hlink><a:srgbClr val="0563C1"/></a:hlink>
        <a:folHlink><a:srgbClr val="954F72"/></a:folHlink>
        </a:clrScheme>
        <a:fontScheme name="MEditor">
        <a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>
        <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>
        </a:fontScheme>
        <a:fmtScheme name="MEditor">
        <a:fillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        </a:fillStyleLst>
        <a:lnStyleLst>
        <a:ln w="9525" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        <a:ln w="25400" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        <a:ln w="38100" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        </a:lnStyleLst>
        <a:effectStyleLst>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        </a:effectStyleLst>
        <a:bgFillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        </a:bgFillStyleLst>
        </a:fmtScheme>
        </a:themeElements>
        </a:theme>
        """
    }

    /// 单页幻灯片：标题文本框（32pt 粗体）+ 正文文本框（项目符号/正文/等宽代码）。
    /// 坐标为绝对 EMU，不依赖版式占位符，保证在 Keynote/PowerPoint/WPS 一致。
    private static func slideXML(_ content: SlideContent) -> String {
        var shapes = ""
        var shapeID = 2

        if let title = content.title, !title.isEmpty {
            shapes += """
            <p:sp>
            <p:nvSpPr><p:cNvPr id="\(shapeID)" name="Title \(shapeID - 1)"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="685800" y="457200"/><a:ext cx="10820400" cy="1219200"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
            <p:txBody><a:bodyPr wrap="square"><a:normAutofit/></a:bodyPr><a:lstStyle/>
            <a:p><a:pPr><a:buNone/></a:pPr><a:r><a:rPr lang="zh-CN" sz="3200" b="1" dirty="0"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:rPr><a:t>\(xmlEscape(title))</a:t></a:r></a:p>
            </p:txBody>
            </p:sp>

            """
            shapeID += 1
        }

        if !content.paragraphs.isEmpty {
            var body = ""
            for paragraph in content.paragraphs {
                body += paragraphXML(paragraph)
            }
            shapes += """
            <p:sp>
            <p:nvSpPr><p:cNvPr id="\(shapeID)" name="Body \(shapeID - 1)"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="685800" y="1828800"/><a:ext cx="10820400" cy="4572000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
            <p:txBody><a:bodyPr wrap="square"><a:normAutofit/></a:bodyPr><a:lstStyle/>
            \(body)</p:txBody>
            </p:sp>
            """
        }

        return xmlHeader + """
        <p:sld xmlns:a="\(nsA)" xmlns:p="\(nsP)" xmlns:r="\(nsR)">
        <p:cSld><p:spTree>
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        \(shapes)</p:spTree></p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sld>
        """
    }

    private static func paragraphXML(_ paragraph: SlideContent.Paragraph) -> String {
        let size: Int
        var font = ""
        if paragraph.isCode {
            size = 1400
            font = #"<a:latin typeface="Courier New"/>"#
        } else if paragraph.bulletLevel > 0 {
            size = paragraph.bulletLevel == 1 ? 2000 : 1800
        } else {
            size = 2000
        }

        let pPr: String
        if paragraph.bulletLevel > 0 {
            let level = paragraph.bulletLevel - 1   // OOXML lvl 从 0 起
            let marL = 285750 * paragraph.bulletLevel
            pPr = #"<a:pPr marL="\#(marL)" indent="-285750" lvl="\#(level)"><a:buChar char="•"/></a:pPr>"#
        } else {
            pPr = #"<a:pPr><a:buNone/></a:pPr>"#
        }

        return """
        <a:p>\(pPr)<a:r><a:rPr lang="zh-CN" sz="\(size)" dirty="0"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>\(font)</a:rPr><a:t>\(xmlEscape(paragraph.text))</a:t></a:r></a:p>

        """
    }
}
