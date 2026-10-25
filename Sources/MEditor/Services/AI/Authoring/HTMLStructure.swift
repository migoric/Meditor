import Foundation

// MARK: - HTMLElement

/// 扫描得到的一个元素。偏移量都是 `[Character]` 下标（与源文逐字符对齐）。
struct HTMLElement: Equatable, Sendable {
    /// 小写标签名。
    let name: String
    /// 属性名小写 → 原值（未解实体）。
    let attributes: [String: String]
    /// 属性值在源文中的区间（`set_node_class` 直接在这里做定点替换，不用正则重建标签）。
    let attributeValueRanges: [String: Range<Int>]
    /// `<` 的位置。
    let startOffset: Int
    /// 开标签 `>` 之后的位置（内容起点）。
    let contentStart: Int
    /// 闭标签 `<` 的位置；未闭合的元素在扫描结束时收敛到文末。
    var contentEnd: Int
    /// 闭标签 `>` 之后的位置。
    var endOffset: Int
    let parentIndex: Int?

    var id: String? { attributes["id"] }
    var classes: [String] {
        guard let raw = attributes["class"] else { return [] }
        return raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    /// 选择器风格的短标签：`section#summary.note`
    var label: String {
        var s = name
        if let id, !id.isEmpty { s += "#\(id)" }
        for cls in classes.prefix(2) { s += ".\(cls)" }
        return s
    }
}

// MARK: - HTMLDocument

/// 一个导航锚点：`<section id>`（或补过 id 的标题）。
///
/// 独立成 struct 而非三元组：SwiftLint `large_tuple` 默认上限是 2 元，
/// 而这里三个字段都要往下传（`navigationHTML` 用 level 做缩进）。
struct HTMLSectionAnchor: Equatable, Sendable {
    let id: String
    let title: String
    let level: Int
}

/// 一次扫描的结果。不建 DOM，只留「够用于定位与折叠」的信息。
struct HTMLDocument: Sendable {
    let source: [Character]
    let elements: [HTMLElement]
    /// 每个 `<style>` 元素的内容区间。
    let styleRanges: [Range<Int>]
    /// 直接子元素计数：元素下标 → (子标签名 → 个数)。大纲里的 `ul(3)` / `table(4 行)` 靠它。
    private let childCounts: [Int: [String: Int]]

    init(source: [Character], elements: [HTMLElement], styleRanges: [Range<Int>]) {
        self.source = source
        self.elements = elements
        self.styleRanges = styleRanges
        var counts: [Int: [String: Int]] = [:]
        for element in elements {
            guard let parent = element.parentIndex else { continue }
            counts[parent, default: [:]][element.name, default: 0] += 1
        }
        self.childCounts = counts
    }

    func slice(_ range: Range<Int>) -> String {
        let lower = max(0, min(range.lowerBound, source.count))
        let upper = max(lower, min(range.upperBound, source.count))
        return String(source[lower..<upper])
    }

    var isEmpty: Bool { elements.isEmpty }

    // MARK: 样式

    var styleText: String {
        styleRanges.map { slice($0) }.joined(separator: "\n")
    }

    var styleTokenEstimate: Int {
        styleRanges.isEmpty ? 0 : AIConversation.estimateTokens(styleText)
    }

    /// 折叠提示：CSS 一个字都不进上下文，只告诉模型「有多少、值多少 token、怎么取」。
    var foldedStyleNotice: String {
        guard !styleRanges.isEmpty else { return "无独立 <style> 块（样式在外部链接或内联属性里）" }
        return "\(styleRanges.count) 个 <style> 块，约 \(styleTokenEstimate) token —— 已折叠"
    }

    // MARK: 选择器

    /// 极简选择器：`#id` / `.class` / `tag` / `tag#id` / `tag.class` / 任意组合 + `:nth(n)`。
    ///
    /// 刻意不实现完整 CSS 选择器：这里是「给模型一个可寻址的名字」，不是样式引擎；
    /// 实现全套子选择器/伪类会引入一整套需要自己维护的匹配语义，而模型完全能
    /// 用 `#id` 与 `tag.class` 表达它需要定位的节点。
    func matchIndices(selector: String) -> [Int] {
        guard let query = HTMLSelector(selector) else { return [] }
        var hits = elements.indices.filter { query.matches(elements[$0]) }
        if let nth = query.nth {
            hits = hits.count >= nth ? [hits[nth - 1]] : []
        }
        return hits
    }

    /// 结构树：只列结构性节点与标题，正文段落/行内标签一律折叠成计数。
    ///
    /// 目标是「可寻址」而不是「完整」——把每个 `<p>`、`<span>` 都列出来，成本会
    /// 追平直接读全文，那就失去折叠的意义了。
    func outline(maxLines: Int = 200) -> String {
        var lines: [String] = []
        var truncated = 0

        for (index, element) in elements.enumerated() {
            let isHeading = HTMLDocument.headingTags.contains(element.name)
            let isStructural = HTMLDocument.isStructural(element)
            guard isHeading || isStructural else { continue }
            guard lines.count < maxLines else { truncated += 1; continue }

            let depth = structuralDepth(of: index)
            let indent = String(repeating: "  ", count: depth)
            if isHeading {
                let text = Self.collapse(slice(element.contentStart..<element.contentEnd))
                let excerpt = text.count > 60 ? String(text.prefix(60)) + "…" : text
                lines.append("\(indent)\(element.name) 「\(excerpt)」")
            } else {
                var label = element.label
                if let count = childCounts[index]?["li"], element.name == "ul" || element.name == "ol" {
                    label += "(\(count))"
                } else if let count = childCounts[index]?["tr"], element.name == "table" {
                    label += "(\(count) 行)"
                }
                lines.append("\(indent)\(label)")
            }
        }
        if truncated > 0 {
            lines.append("…（结构树已截断：还有 \(truncated) 个节点；用 read_node 直接取指定节点）")
        }
        return lines.isEmpty ? "（没有可识别的结构：文档可能是纯文本）" : lines.joined(separator: "\n")
    }

    /// `<section id>` → 侧边栏导航条目（`write_html_with_template` 用它重建导航）。
    func sectionAnchors() -> [HTMLSectionAnchor] {
        var anchors: [HTMLSectionAnchor] = []
        for (index, element) in elements.enumerated() where element.name == "section" {
            guard let id = element.id, !id.isEmpty else { continue }
            // 取该 section 内第一个标题的文本作为导航文案
            var title = ""
            var level = 2
            for child in elements[(index + 1)...] {
                if child.startOffset >= element.contentEnd { break }
                if HTMLDocument.headingTags.contains(child.name) {
                    title = Self.collapse(slice(child.contentStart..<child.contentEnd))
                    level = Int(child.name.dropFirst()) ?? 2
                    break
                }
            }
            if title.isEmpty { title = id }
            anchors.append(HTMLSectionAnchor(id: id, title: title, level: level))
        }
        return anchors
    }

    private func structuralDepth(of index: Int) -> Int {
        var depth = 0
        var cursor = elements[index].parentIndex
        while let parent = cursor {
            let element = elements[parent]
            if HTMLDocument.headingTags.contains(element.name) || HTMLDocument.isStructural(element) {
                depth += 1
            }
            cursor = element.parentIndex
        }
        return depth
    }

    static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    /// 结构性容器（大纲里出现的节点）。`div` 只在带 id/class 时算——否则几乎每份
    /// 文档都有几十个裸 `div`，列出来只是噪音。
    static func isStructural(_ element: HTMLElement) -> Bool {
        switch element.name {
        case "body", "main", "article", "section", "header", "footer", "nav", "aside",
             "figure", "figcaption", "table", "ul", "ol", "dl", "pre", "blockquote",
             "details", "form", "picture", "template":
            return true
        case "div":
            return element.id != nil || !element.classes.isEmpty
        default:
            return false
        }
    }

    /// 去掉标签、解常见实体、折叠空白。标题文案只需要这些。
    static func collapse(_ html: String) -> String {
        var output = ""
        var inTag = false
        for ch in html {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { output.append(ch) }
        }
        let decoded = output
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        return decoded
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" || $0 == "\u{3000}" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - HTMLSelector

/// 选择器解析结果。解析失败返回 nil（工具层报「选择器语法不支持」）。
struct HTMLSelector: Equatable, Sendable {
    let tag: String?
    let id: String?
    let className: String?
    let nth: Int?

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var nth: Int? = nil
        if let range = text.range(of: ":nth(", options: .backwards), text.hasSuffix(")") {
            let inside = text[range.upperBound..<text.index(before: text.endIndex)]
            guard let value = Int(inside), value > 0 else { return nil }
            nth = value
            text = String(text[text.startIndex..<range.lowerBound])
        }

        var tag: String? = nil
        var id: String? = nil
        var className: String? = nil

        var rest = Substring(text)
        if let first = rest.first, first == "#" || first == "." {
            if first == "#" { id = String(rest.dropFirst()) } else { className = String(rest.dropFirst()) }
        } else {
            let name = rest.prefix { $0.isLetter || $0.isNumber }
            guard !name.isEmpty else { return nil }
            tag = name.lowercased()
            rest = rest.dropFirst(name.count)
            if rest.first == "#" {
                id = String(rest.dropFirst())
            } else if rest.first == "." {
                className = String(rest.dropFirst())
            } else if !rest.isEmpty {
                return nil
            }
        }
        // 组合形态（`#id.class`）不在支持范围内：与其静默只匹配一半，不如报错
        if let id, id.contains(".") || id.contains("#") { return nil }
        if let className, className.contains(".") || className.contains("#") { return nil }
        guard tag != nil || id != nil || className != nil else { return nil }
        self.tag = tag
        self.id = id
        self.className = className
        self.nth = nth
    }

    func matches(_ element: HTMLElement) -> Bool {
        if let tag, element.name != tag { return false }
        if let id, element.id != id { return false }
        if let className, !element.classes.contains(className) { return false }
        return true
    }
}

// MARK: - HTMLScanner

/// 线性扫描器：一遍过得到元素表、`<style>` 内容区间与父子关系。
///
/// 为什么不用 `XMLParser` / `NSAttributedString(html:)`：真实文档基本不是良构 XML
/// （未闭合 `<br>`、`&nbsp;`、裸 `<`），而带 UI 的 HTML 解析只能在主线程跑。
/// 这里只要「标签的位置」与「谁是谁的父亲」，容错比严格更重要。
enum HTMLScanner {

    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]
    static let rawTextElements: Set<String> = ["script", "style", "textarea", "title"]

    static func scan(_ html: String) -> HTMLDocument {
        let chars = Array(html)
        let count = chars.count
        var elements: [HTMLElement] = []
        var stack: [Int] = []
        var styleRanges: [Range<Int>] = []
        var i = 0

        func closeElement(at index: Int, contentEnd: Int, endOffset: Int) {
            elements[index].contentEnd = contentEnd
            elements[index].endOffset = endOffset
        }

        while i < count {
            guard chars[i] == "<" else { i += 1; continue }

            if matches(chars, at: i, "<!--") {
                i = find(chars, from: i + 4, token: "-->").map { $0 + 3 } ?? count
                continue
            }
            if matches(chars, at: i, "<!") || matches(chars, at: i, "<?") {
                i = find(chars, from: i + 2, token: ">").map { $0 + 1 } ?? count
                continue
            }
            if matches(chars, at: i, "</") {
                guard let tagEnd = find(chars, from: i + 2, token: ">") else { break }
                let name = String(chars[(i + 2)..<tagEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let after = tagEnd + 1
                if let stackIndex = stack.lastIndex(where: { elements[$0].name == name }) {
                    // 中间未闭合的元素按「在闭标签处隐式闭合」处理（浏览器也是这么做的）
                    while stack.count > stackIndex {
                        let index = stack.removeLast()
                        closeElement(at: index, contentEnd: i, endOffset: after)
                    }
                }
                i = after
                continue
            }

            guard let tag = parseTag(chars, from: i) else { i += 1; continue }

            if tag.isClosing { i = tag.tagEnd; continue }

            let isVoid = tag.selfClosing || voidElements.contains(tag.name)
            let element = HTMLElement(
                name: tag.name,
                attributes: tag.attributes,
                attributeValueRanges: tag.valueRanges,
                startOffset: i,
                contentStart: tag.tagEnd,
                contentEnd: isVoid ? tag.tagEnd : count,
                endOffset: isVoid ? tag.tagEnd : count,
                parentIndex: stack.last
            )
            elements.append(element)
            let elementIndex = elements.count - 1

            if isVoid {
                i = tag.tagEnd
                continue
            }
            if rawTextElements.contains(tag.name) {
                // 原始文本元素内部不解析标签：找到对应的闭标签即可（`<style>` 里的
                // `a > b` 选择器不是标签，逐字符解析会把它当标签吞掉）
                if let closeStart = findClosingTag(chars, from: tag.tagEnd, name: tag.name) {
                    let closeEnd = find(chars, from: closeStart, token: ">").map { $0 + 1 } ?? count
                    closeElement(at: elementIndex, contentEnd: closeStart, endOffset: closeEnd)
                    if tag.name == "style" { styleRanges.append(tag.tagEnd..<closeStart) }
                    i = closeEnd
                } else {
                    closeElement(at: elementIndex, contentEnd: count, endOffset: count)
                    if tag.name == "style" { styleRanges.append(tag.tagEnd..<count) }
                    i = count
                }
                continue
            }
            stack.append(elementIndex)
            i = tag.tagEnd
        }

        // 到文末仍未闭合的元素：收敛到文末（不是错误，真实文档里很常见）
        while let index = stack.popLast() {
            closeElement(at: index, contentEnd: count, endOffset: count)
        }
        return HTMLDocument(source: chars, elements: elements, styleRanges: styleRanges)
    }

    // MARK: 标签解析

    struct ParsedTag {
        let name: String
        let attributes: [String: String]
        let valueRanges: [String: Range<Int>]
        let selfClosing: Bool
        let isClosing: Bool
        let tagEnd: Int
    }

    static func parseTag(_ chars: [Character], from start: Int) -> ParsedTag? {
        var j = start + 1
        let count = chars.count
        var isClosing = false
        if j < count, chars[j] == "/" { isClosing = true; j += 1 }
        guard j < count, isTagNameStart(chars[j]) else { return nil }

        var name = ""
        while j < count, isTagNameChar(chars[j]) {
            name.append(chars[j])
            j += 1
        }
        guard !name.isEmpty else { return nil }

        var attributes: [String: String] = [:]
        var ranges: [String: Range<Int>] = [:]
        var selfClosing = false

        while j < count {
            while j < count, chars[j].isWhitespace { j += 1 }
            guard j < count else { return nil }
            if chars[j] == ">" {
                return ParsedTag(name: name.lowercased(), attributes: attributes, valueRanges: ranges,
                                 selfClosing: selfClosing, isClosing: isClosing, tagEnd: j + 1)
            }
            if chars[j] == "/" {
                selfClosing = true
                j += 1
                continue
            }
            var attrName = ""
            while j < count, !chars[j].isWhitespace, chars[j] != "=", chars[j] != ">", chars[j] != "/" {
                attrName.append(chars[j])
                j += 1
            }
            while j < count, chars[j].isWhitespace { j += 1 }
            if j < count, chars[j] == "=" {
                j += 1
                while j < count, chars[j].isWhitespace { j += 1 }
                guard j < count else { return nil }
                if chars[j] == "\"" || chars[j] == "'" {
                    let quote = chars[j]
                    j += 1
                    let valueStart = j
                    while j < count, chars[j] != quote { j += 1 }
                    let key = attrName.lowercased()
                    attributes[key] = String(chars[valueStart..<min(j, count)])
                    ranges[key] = valueStart..<min(j, count)
                    if j < count { j += 1 }
                } else {
                    let valueStart = j
                    while j < count, !chars[j].isWhitespace, chars[j] != ">" { j += 1 }
                    let key = attrName.lowercased()
                    attributes[key] = String(chars[valueStart..<j])
                    ranges[key] = valueStart..<j
                }
            } else if !attrName.isEmpty {
                attributes[attrName.lowercased()] = ""
            }
            if attrName.isEmpty && chars[j] != ">" { j += 1 }   // 容错：跳过无法解析的字符
        }
        return nil
    }

    // MARK: 字符工具

    private static func isTagNameStart(_ c: Character) -> Bool { c.isLetter }

    private static func isTagNameChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":"
    }

    static func matches(_ chars: [Character], at index: Int, _ token: String) -> Bool {
        let tokenChars = Array(token)
        guard index + tokenChars.count <= chars.count else { return false }
        for offset in 0..<tokenChars.count where chars[index + offset] != tokenChars[offset] {
            return false
        }
        return true
    }

    static func find(_ chars: [Character], from start: Int, token: String) -> Int? {
        let tokenChars = Array(token)
        guard !tokenChars.isEmpty, start >= 0 else { return nil }
        var i = start
        while i + tokenChars.count <= chars.count {
            if chars[i] == tokenChars[0] {
                var matched = true
                for offset in 1..<tokenChars.count where chars[i + offset] != tokenChars[offset] {
                    matched = false
                    break
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    /// 找 `</name`（大小写不敏感），返回 `<` 的位置。
    static func findClosingTag(_ chars: [Character], from start: Int, name: String) -> Int? {
        let needle = Array("</" + name.lowercased())
        var i = start
        while i + needle.count <= chars.count {
            if chars[i] == "<", chars[i + 1] == "/" {
                var matched = true
                for offset in 2..<needle.count {
                    if Character(chars[i + offset].lowercased()) != needle[offset] {
                        matched = false
                        break
                    }
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }
}
